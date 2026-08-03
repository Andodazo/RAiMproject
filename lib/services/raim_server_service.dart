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
//    現在は Cognito 認証済みになってから1本だけ接続を張り、終了まで使い回す。
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
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/models/conversation_thread.dart';
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
  /// final String serverUrl;
  //-------------開発検証用---------------------
  String _serverUrl;
  String get serverUrl => _serverUrl;
  //-------------------------------------------

  /// 自動再接続の最大試行回数
  /// これを超えると offline 状態に遷移する
  final int maxReconnectAttempts;

  /// 1リクエストの全体タイムアウト
  /// この時間内に chat が来なければエラー扱い
  /// LLM 応答に時間がかかる場合があるので、ある程度長めに（60秒）
  final Duration requestTimeout;

  /// スレッド一覧・履歴のタイムアウト
  ///
  /// 会話生成（requestTimeout）と違い、Edge Lambda が DynamoDB を
  /// 直接読むだけなので通常は数十msで返る。
  /// 60秒待たせるとボタンが固まったように見えるため短くする。
  static const Duration threadRequestTimeout = Duration(seconds: 10);
  /// アクセストークンを動的に取得するコールバック関数
  final Future<String?> Function()? accessTokenGetter;

  RaimServerService({
    //required this.serverUrl,
    required String serverUrl,
    this.accessTokenGetter,
    this.maxReconnectAttempts = 3,
    this.requestTimeout = const Duration(seconds: 60),
  }) : _serverUrl = serverUrl;

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

  /// サービス自体を破棄済みかどうか
  /// disconnect() はログアウトなどでも呼ぶため、StreamController は dispose() でだけ閉じる。
  bool _disposed = false;

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
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
    // ignore: avoid_print
    print('[RaimServerService] State: $newState');
  }

  // ─────────────────────────────────────────────
  // 接続ライフサイクル
  // ─────────────────────────────────────────────

  /// サーバーに接続する
  /// Cognito 認証済みになってから SplashScreen 側で呼ぶ
  /// 既に接続中なら何もしない
  /// 繋がってる時にやりたくない処理(つながってたらreturnで終わる)
  // ★ 連打防止用のフラグを追加-----------------------------------------------
  bool _isSwitching = false;

  /// 接続先サーバーの切り替え処理
  Future<void> switchServer(String targetUrl, {String? accessToken}) async {
    // 1. すでに切り替え処理中なら連打を無視して終了
    if (_isSwitching) {
      print('[RaimServerService] 切り替え処理中のため連打を無視しました');
      return;
    }

    _isSwitching = true; // 処理中フラグをON

    try {
      print('[RaimServerService] 接続先を切り替えます: $_serverUrl -> $targetUrl');
      
      // 既存の接続を切断
      await disconnect();

      // 新しい接続先に切り替えて再接続
      _serverUrl = targetUrl;
      await connect(accessToken: accessToken);

    } catch (e) {
      print('[RaimServerService] 切り替えエラー: $e');
    } finally {
      // 成功・失敗にかかわらず、終わったら必ずフラグをOFFに戻す
      _isSwitching = false;
    }
  }
  //------------------------------------------------------------------------------
  Future<void> connect({String? accessToken}) async {
    if (_disposed) return;
    if (_state == RaimConnectionState.connected) return;
    _intentionalClose = false;
    _setState(RaimConnectionState.connecting);

    try {
      //仕様書に基づいたヘッダーの構築
      final headers = <String, String>{
        'User-Agent': 'RAiM-Flutter/1.0',
      };
      // AWS（cloudfront.net）接続時のみアクセストークンを付与する
      final isAws = _serverUrl.contains('cloudfront.net');
      if (isAws) {
        // 引数で渡されたトークンか、無ければ accessTokenGetter から最新トークンを取得
        final token = accessToken ?? await accessTokenGetter?.call();
        if (token != null && token.isNotEmpty) {
          headers['Authorization'] = 'Bearer $token';
          // Tailscale の場合は isAws が false になるため、Authorization ヘッダーは付与されない
        }
      }
      // ヘッダーを付与してWebSocket 接続を確立
      //開発検証用
      //_channel = IOWebSocketChannel.connect(Uri.parse(serverUrl),headers: headers);
      _channel = IOWebSocketChannel.connect(Uri.parse(_serverUrl), headers: headers);

      // 接続完了を待つ（web_socket_channel v3 から ready が使える）
      await _channel!.ready;

      // ブロードキャスト用 StreamController を準備 messageを入れる部分の初期定義
      _broadcaster ??= StreamController<LLMResponse>.broadcast();

      // 受信開始F
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
  /// ログアウトやアプリ終了前に呼ぶ。
  /// 再ログインや終了処理で二重呼び出しされる可能性があるため、
  /// StreamController はここでは閉じず、dispose() でだけ閉じる。
  Future<void> disconnect() async {
    _intentionalClose = true;  // 自動再接続を抑止
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    try {
      await _subscription?.cancel();
      _channel = null;
    } catch (_) {}

    try {
      // 壊れた接続の閉鎖処理でフリーズしないよう 500ms のタイムアウトを設定
      await _channel?.sink.close(ws_status.normalClosure).timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {
          print('[RaimServerService] disconnect timeout (forced close)');
        },
      );
    } catch (_) {}

    _channel = null;
    _subscription = null;
    _sessionId = null;  // セッションIDもクリア

    try {
      await _broadcaster?.close();
    } catch (_) {}
    _broadcaster = null;
    _setState(RaimConnectionState.disconnected);
  }

  /// サービスを完全に破棄する。
  /// アプリ終了時だけ呼び、通常の logout では disconnect() に留める。
  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;

    if (!_stateController.isClosed) {
      await _stateController.close();
    }
  }

  // ─────────────────────────────────────────────
  // 受信ハンドラ
  // ─────────────────────────────────────────────

  /// メッセージ受信時の処理
  ///
  /// 1. JSON パース(JSONをプログラムに使えるように変換)
  /// 2. session_start なら sessionID を保持（broadcaster には流さない）
  /// 3.それ以外の metadata / text_chunk / audio_chunk / tool_call / chat_end は
  /// 4._broadcaster に流して ChatProvider 側で処理する。
  void _onMessage(dynamic rawMessage) {
    try {
      print('[RaimServerService] raw message: $rawMessage');
       // JSON文字列をDartのMapに変換する
      final data = jsonDecode(rawMessage as String) as Map<String, dynamic>;
      // MapからLLMResponseモデルを作る
      final response = LLMResponse.fromJson(data);
      print('[RaimServerService] response type: ${response.type}');
      // text_chunk の is_filler が正しく読めているか確認する
      if (response.isTextChunk) {
        print(
          '[RaimServerService] text_chunk text=${response.text}, '
          'isFiller=${response.isFiller}',
        );
      }
      // session_start は内部処理だけして broadcaster には流さない
      // → sendMessage の chat 待ちループに混入させないため
      if (response.isSessionStart && response.sessionId != null) {
        _sessionId = response.sessionId;
        // ignore: avoid_print
        print('[RaimServerService] Session started: $_sessionId');
        return;
      }
      //audioのログ出力サーバー側
      if (response.isAudioChunk) {
        print(
          '[RaimServerService] audio_chunk '
          'chunkId=${response.chunkId}, '
          'format=${response.format}, '
          'audioLength=${response.audioBase64?.length ?? 0}',
        );
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
  // ============================================================
  // 返答完了判定
  // ============================================================
  // v2.2では text_chunk / audio_chunk などが複数回届く。
  // chat_end が来たら1回分の返答完了。
  // 旧形式の chat と error も完了扱いにする。
  bool _isTerminalResponse(LLMResponse response) {
    return response.isChatEnd || response.isChat || response.isError;
  }
 @override
  Stream<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
    List<Map<String, dynamic>>? images,
    String? threadId,
  }) async* {
    // オフラインまたは切断中なら、送信前に再接続を試す
    if (_state == RaimConnectionState.offline ||
        _state == RaimConnectionState.disconnected) {
      print('[RaimServerService] Waking up RAiM...');
      await _wakeUp();
    }
    // 再接続しても接続できていなければ送信できない
    if (_state != RaimConnectionState.connected) {
      throw Exception('RAiMに接続できていません: state=$_state');
    }
    // 受信メッセージを流すStreamを用意する
    _broadcaster ??= StreamController<LLMResponse>.broadcast();
    // サーバーへ送る基本データ
    final payload = <String, dynamic>{
      'text': userInput,
    };
     // 画像がある場合は payload に追加する
    if (images != null && images.isNotEmpty) {
      payload['images'] = images;
    }
    // session_id がある場合は送信に含める
    if (_sessionId != null) {
      payload['session_id'] = _sessionId;
    }
    // 会話スレッドの指定
    //
    // 省略するとサーバー側が「現在アクティブなスレッド」に追記する。
    // 過去スレッドを再開する場合や、新しい会話を始める場合は
    // 呼び出し側が threadId を指定する。
    if (threadId != null && threadId.isNotEmpty) {
      payload['threadId'] = threadId;
    }
    // 送信後に返ってくる複数メッセージを順番に受け取るためのIterator
    final iterator = StreamIterator<LLMResponse>(_broadcaster!.stream);

    try {
      // 先に受信待ちを開始してから送信する
      // 送信直後に返答が来ても取り逃がさないため
      final firstResponse = iterator.moveNext();
      // WebSocketでサーバーへ送信する
      _channel!.sink.add(jsonEncode(payload));
      // 最初の応答を待つ
      var hasResponse = await firstResponse.timeout(
        requestTimeout,
        onTimeout: () {
          throw TimeoutException(
            'RAiMからの最初の応答が遅すぎます',
            requestTimeout,
          );
        },
      );
      // text_chunk / audio_chunk / tool_call などを順番に返す
      while (hasResponse) {
        final response = iterator.current;
        // ChatProvider 側へ1件ずつ渡す
        yield response;
        // chat_end / chat / error が来たら1回分の応答完了
        if (response.isChatEnd || response.isChat || response.isError) {
          break;
        }
        // 次の応答を待つ
        hasResponse = await iterator.moveNext().timeout(
          requestTimeout,
          onTimeout: () {
            throw TimeoutException(
              'RAiMからの次の応答が遅すぎます',
              requestTimeout,
            );
          },
        );
      }
    } finally {
      // このsendMessage専用の受信待ちを終了する
      await iterator.cancel();
    }
  }

  // ==========================================================================
  // スレッド操作
  // ==========================================================================
  //
  // 一覧と履歴は、チャット送信と経路が違う。
  //
  //   チャット … Edge Lambda -> SQS -> Core Lambda（生成に数秒かかるため非同期）
  //   一覧/履歴 … Edge Lambda が DynamoDB を直接読んで即応答
  //
  // どちらも同じ WebSocket を使うが、応答が速い（数十ms程度）。

  /// スレッド一覧を取得する
  ///
  /// 更新が新しい順に、最大50件返る。本文（messages）は含まれない。
  Future<List<ThreadSummary>> fetchThreadList() async {
    final response = await _requestOnce(
      payload: {'type': 'thread.list'},
      matches: (r) => r.isThreadList,
      label: 'thread.list',
    );

    final raw = response['threads'];
    if (raw is! List) return const [];

    return raw
        .whereType<Map>()
        .map((item) => ThreadSummary.fromJson(
              item.map((k, v) => MapEntry(k.toString(), v)),
            ))
        .toList();
  }

  /// スレッドの過去メッセージを取得する
  ///
  /// 直近50件が古い順（時系列）で返る。そのまま画面に並べられる。
  /// スレッドが存在しない場合は null。
  Future<ThreadHistory?> fetchThreadHistory(String threadId) async {
    if (threadId.isEmpty) return null;

    final response = await _requestOnce(
      payload: {'type': 'thread.history', 'threadId': threadId},
      matches: (r) => r.isThreadHistory,
      label: 'thread.history',
    );

    return ThreadHistory.fromJson(response);
  }

  /// 1往復だけの要求を送り、対応する応答を待つ
  ///
  /// sendMessage と違い、ストリーミングではなく単発の応答を返す。
  /// 一覧・履歴のような読み取り要求で使う。
  Future<Map<String, dynamic>> _requestOnce({
    required Map<String, dynamic> payload,
    required bool Function(LLMResponse) matches,
    required String label,
  }) async {
    if (_state == RaimConnectionState.offline ||
        _state == RaimConnectionState.disconnected) {
      await _wakeUp();
    }
    if (_state != RaimConnectionState.connected) {
      throw Exception('RAiMに接続できていません: state=$_state');
    }

    _broadcaster ??= StreamController<LLMResponse>.broadcast();
    final iterator = StreamIterator<LLMResponse>(_broadcaster!.stream);

    try {
      // 送信より先に受信待ちを始める（即答されても取り逃がさないため）
      var hasResponse = iterator.moveNext();
      _channel!.sink.add(jsonEncode(payload));

      // 目的の応答が来るまで読み飛ばす。
      // 会話の text_chunk などが混ざる可能性があるため。
      while (await hasResponse.timeout(
        threadRequestTimeout,
        onTimeout: () => throw TimeoutException(
          'RAiMからの$label応答が遅すぎます',
          threadRequestTimeout,
        ),
      )) {
        final response = iterator.current;

        if (matches(response)) {
          return response.raw;
        }
        if (response.isError) {
          throw Exception('$label に失敗しました: ${response.text}');
        }

        hasResponse = iterator.moveNext();
      }

      throw Exception('$label の応答が得られませんでした');
    } finally {
      await iterator.cancel();
    }
  }
}
