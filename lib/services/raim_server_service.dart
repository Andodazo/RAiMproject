// lib/services/raim_server_service.dart
// =============================================================================
// RAiM 中継サーバーとの WebSocket 通信を担当する LLMService 実装
// =============================================================================
//
// 【このファイルの役割】
// 自宅PC（または AWS Lambda）で動いている RAiM 中継サーバーに WebSocket で接続し、
// メッセージのやり取りをする。
//
// 【設計上の重要なポイント】
//
// 1. WebSocket を「永続接続」として扱う
//    旧実装では sendMessage 毎に接続を張る方式だったが、
//    LLM 応答待ちの間にタイムアウトで切られる問題があった。
//    現在は起動時に1本だけ接続を張り、終了まで使い回す。
//
// 2. サーバーからは「複数のメッセージ」が順次来る場合がある
//    1リクエストに対して filler_audio → chat と2回来たり、
//    将来は tool_call → chat と来たりする。
//    sendMessage は Stream を返し、chat が来るまで受信を続ける。
//
// 3. 接続状態を enum で管理（将来の「寝てる演出」の土台）
//    connecting / connected / disconnected / offline の4状態。
//    offline = 自動再接続を諦めた状態 = ライムが寝てる
//    将来 UI 側で立ち絵切替などに使う。
//
// 4. 自動再接続（指数バックオフ）
//    切断したら 1秒 → 2秒 → 4秒 でリトライ、3回失敗で offline へ。
//
// 5. 「話しかけて起こす」フロー
//    offline 状態でユーザーが送信したら、内部で再接続を試みる。
//    成功すれば「寝ていたライムが起きた」演出になる。

import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/services/llm_service.dart';

/// 接続状態の列挙
///
/// 将来 UI 側で立ち絵切替や Zzz... 表示等に使うため、enum で公開する。
enum RaimConnectionState {
  /// 接続中（初回起動 or 再接続試行中）
  connecting,

  /// 接続済み（ライム起きてる、通常状態）
  connected,

  /// 切断検知、自動再接続中
  /// 1〜4秒のバックオフで連続リトライしてる状態
  disconnected,

  /// 自動再接続を諦めた状態 = ライムが寝てる
  /// ユーザー送信時に再接続試行する（「話しかけて起こす」フロー）
  offline,
}

class RaimServerService implements LLMService {
  // ─── 設定値（コンストラクタで受け取る） ───
  
  /// サーバーの URL
  /// 例: "ws://127.0.0.1:8080"（同一PC）
  /// 例: "ws://100.x.y.z:8080"（Tailscale経由）
  final String serverUrl;

  /// 自動再接続の最大試行回数
  /// これを超えると offline 状態に遷移する
  final int maxReconnectAttempts;

  /// 1リクエストの全体タイムアウト
  /// この時間内に chat が来なければエラー扱い
  /// LLM 応答に時間がかかる場合があるので、ある程度長めに（60秒）
  final Duration requestTimeout;

  RaimServerService({
    required this.serverUrl,
    this.maxReconnectAttempts = 3,
    this.requestTimeout = const Duration(seconds: 60),
  });

  // ─── 内部状態 ───

  /// WebSocket チャンネル
  WebSocketChannel? _channel;

  /// 受信ストリームの購読
  StreamSubscription? _subscription;

  /// サーバーから受信した全メッセージをブロードキャストする
  /// sendMessage はここを購読して chat を待つ
  /// 将来の proactive_message 受信もここから購読できる
  StreamController<LLMResponse>? _broadcaster;

  /// 再接続試行回数（指数バックオフの計算に使う）
  int _reconnectAttempts = 0;

  /// 再接続用タイマー（バックオフ待ち中）
  Timer? _reconnectTimer;

  /// 意図的な切断か（dispose 等）
  /// true なら自動再接続を抑止する
  bool _intentionalClose = false;

  /// 現在のセッションID
  /// サーバーから session_start で受信して保持する
  String? _sessionId;
  String? get sessionId => _sessionId;

  // ─── 接続状態（外部公開） ───

  /// 接続状態の変化を通知するための StreamController
  final _stateController = StreamController<RaimConnectionState>.broadcast();

  /// 現在の接続状態
  RaimConnectionState _state = RaimConnectionState.connecting;
  RaimConnectionState get state => _state;

  /// 接続状態の変化を購読するための Stream
  /// ChatProvider などが listen して UI に反映する
  Stream<RaimConnectionState> get stateStream => _stateController.stream;

  /// サーバーから来る全メッセージを購読するための Stream
  /// 将来の proactive_message（ライム発信）を受信するために公開
  Stream<LLMResponse> get incomingStream {
    _broadcaster ??= StreamController<LLMResponse>.broadcast();
    return _broadcaster!.stream;
  }

  /// 状態変更とログ出力をまとめて行う
  /// どういう動作かわかるようにするため
  void _setState(RaimConnectionState newState) {
    if (_state == newState) return;
    _state = newState;
    _stateController.add(newState);
    // ignore: avoid_print
    print('[RaimServerService] State: $newState');
  }

  // ─────────────────────────────────────────────
  // 接続ライフサイクル
  // ─────────────────────────────────────────────

  /// サーバーに接続する
  /// main.dart の起動時に呼ぶ
  /// 既に接続中なら何もしない
  /// 繋がってる時にやりたくない処理(つながってたらreturnで終わる)
  Future<void> connect() async {
    if (_state == RaimConnectionState.connected) return;
    _intentionalClose = false;
    _setState(RaimConnectionState.connecting);

    try {
      // WebSocket 接続を確立
      _channel = WebSocketChannel.connect(Uri.parse(serverUrl));

      // 接続完了を待つ（web_socket_channel v3 から ready が使える）
      await _channel!.ready;

      // ブロードキャスト用 StreamController を準備 messageを入れる部分の初期定義
      _broadcaster ??= StreamController<LLMResponse>.broadcast();

      // 受信開始
      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      // 接続成功 → リトライカウンタリセット、状態更新
      _reconnectAttempts = 0;
      _setState(RaimConnectionState.connected);
    } catch (e) {
      // ignore: avoid_print
      print('[RaimServerService] connect failed: $e');
      await _scheduleReconnect();
    }
  }

  /// サーバーから切断する
  /// アプリ終了時 or dispose 時に呼ぶ
  Future<void> disconnect() async {
    _intentionalClose = true;  // 自動再接続を抑止
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close(ws_status.normalClosure);
    _channel = null;
    _subscription = null;
    _sessionId = null;  // セッションIDもクリア
    await _broadcaster?.close();
    _broadcaster = null;
    await _stateController.close();
  }

  // ─────────────────────────────────────────────
  // 受信ハンドラ
  // ─────────────────────────────────────────────

  /// メッセージ受信時の処理
  ///
  /// 1. JSON パース(JSONをプログラムに使えるように変換)
  /// 2. session_start なら sessionID を保持（broadcaster には流さない）
  /// 3. それ以外は broadcaster に流す（sendMessage や incomingStream が拾う）
  void _onMessage(dynamic rawMessage) {
    try {
      final data = jsonDecode(rawMessage as String) as Map<String, dynamic>;
      final response = LLMResponse.fromJson(data);

      // session_start は内部処理だけして broadcaster には流さない
      // → sendMessage の chat 待ちループに混入させないため
      if (response.isSessionStart && response.sessionId != null) {
        _sessionId = response.sessionId;
        // ignore: avoid_print
        print('[RaimServerService] Session started: $_sessionId');
        return;
      }

      // それ以外のメッセージは broadcaster に流す
      // sendMessage の中のリスナーが chat を待ち構えてる
      _broadcaster?.add(response);
    } catch (e) {
      // ignore: avoid_print
      print('[RaimServerService] Parse error: $e (raw: $rawMessage)');
      // パース失敗してもアプリは落とさない
    }
  }

  /// エラー時のハンドラ
  void _onError(dynamic error) {
    // ignore: avoid_print
    print('[RaimServerService] Stream error: $error');
  }

  /// 切断時のハンドラ
  /// サーバー側からの切断 or ネットワーク断
  void _onDone() {
    // ignore: avoid_print
    print('[RaimServerService] Connection closed by server');
    _sessionId = null;  // セッションIDも消す（再接続時は新セッション）
    if (_intentionalClose) return;  // 意図的な切断ならリトライしない
    _scheduleReconnect();
  }

  // ─────────────────────────────────────────────
  // 自動再接続（指数バックオフ）
  // ─────────────────────────────────────────────

  /// 再接続をスケジュールする
  /// 1秒 → 2秒 → 4秒 のバックオフ
  /// 最大試行回数を超えたら offline 状態に遷移
  Future<void> _scheduleReconnect() async {
    _reconnectAttempts++;

    if (_reconnectAttempts > maxReconnectAttempts) {
      // ギブアップ → 寝る
      _setState(RaimConnectionState.offline);
      return;
    }

    _setState(RaimConnectionState.disconnected);

    // 指数バックオフ: 1秒 → 2秒 → 4秒
    final delaySeconds = 1 << (_reconnectAttempts - 1);
    // ignore: avoid_print
    print('[RaimServerService] Reconnect attempt $_reconnectAttempts in ${delaySeconds}s');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      // 古い接続オブジェクトをクリーンアップしてから再接続
      await _subscription?.cancel();
      _subscription = null;
      _channel = null;
      await connect();
    });
  }

  /// 「寝てるライムを起こす」処理
  /// offline 状態でユーザーがメッセージを送ろうとした時に呼ぶ
  /// リトライカウンタをリセットして再接続を試みる
  Future<void> _wakeUp() async {
    _reconnectAttempts = 0;
    await connect();
  }

  // ─────────────────────────────────────────────
  // LLMService 実装: sendMessage
  // ─────────────────────────────────────────────

  /// メッセージを送信し、応答を Stream で受け取る
  ///
  /// 1リクエストに対してサーバーから複数メッセージが返ってくる可能性がある
  /// （filler_audio → chat の順など）。
  /// chat メッセージを受信した時点で Stream を閉じる。
  @override
  Stream<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
    // 型を List<String>? から List<Map<String, dynamic>>? に変更
    List<Map<String, dynamic>>? images, //画像配列型に
  }) async* {
    // offline / disconnected なら起こす（再接続試行）
    if (_state == RaimConnectionState.offline ||
        _state == RaimConnectionState.disconnected) {
      // ignore: avoid_print
      print('[RaimServerService] Waking up RAiM...');
      await _wakeUp();
    }

    // 起こしても繋がらなければエラー
    if (_state != RaimConnectionState.connected) {
      throw Exception('ライムに繋がらないみたい……（state=$_state）');
    }

    // 送信ペイロードを組み立て
    // session_id を含めることで、サーバー側が過去の履歴を引ける
    final Map<String, dynamic> payload = {
      'text': userInput,
    };

    // 画像があれば payload に追加する（画像なしの時は images フィールド自体を省略）
    if (images != null && images.isNotEmpty) {
      payload['images'] = images;
    }
    
    //セッションIDがあれば含める
    if (_sessionId != null) {
      payload['session_id'] = _sessionId;
    }

    // デバッグログ
    if (images != null && images.isNotEmpty) {
      // ignore: avoid_print
      print('[RaimServerService] 画像(${images.length}件)・セッション付きで送信データを組み立てました');
    }
    _channel!.sink.add(jsonEncode(payload));

    // 受信ループの準備
    // - 来たメッセージは responses に蓄積
    // - chat を受信したら completer を complete して終了
    // - タイムアウトで強制終了する保険も入れる
    final completer = Completer<void>();
    final responses = <LLMResponse>[];
    StreamSubscription? sub;
    Timer? timeoutTimer;

    // 全体タイムアウト
    // この時間内に chat が来なければエラー扱い
    timeoutTimer = Timer(requestTimeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('ライムからの応答が遅すぎます', requestTimeout),
        );
      }
    });

    // broadcaster を購読して、chat が来るまで待つ
    sub = _broadcaster!.stream.listen((response) {
      responses.add(response);
      if (response.isChat) {
        if (!completer.isCompleted) completer.complete();
      }
    });

    // 待機
    try {
      await completer.future;
    } finally {
      // クリーンアップ（タイムアウト、購読解除）
      timeoutTimer.cancel();
      await sub.cancel();
    }

    // 受信したメッセージを順番に yield
    // 受信側（ChatProvider）が await for で受け取る
    for (final r in responses) {
      yield r;
    }
  }
}