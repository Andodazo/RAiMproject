// lib/services/raim_server_service.dart  (v3 - 永続接続版)
//
// 設計方針:
// - WebSocket を1本の永続接続として扱う
// - sendMessage 毎に接続を張らない（旧v2の構造的問題を解消）
// - 接続状態を enum で管理（将来の「寝てる演出」拡張ポイント）
// - 切断時は指数バックオフで自動再接続（最大3回）
// - 3回失敗で offline 状態に遷移
// - ユーザー送信時、offline なら再接続を試行（「話しかけて起こす」）
// - 1リクエスト＝1 chat受信＋途中のfiller_audio
//   sendMessage は次の chat が来たら終了

import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/services/llm_service.dart';

/// 接続状態
/// 将来「寝てるライムを起こす」演出はこの状態を見て分岐する
enum RaimConnectionState {
  /// 接続中（初回起動 or 再接続中）
  connecting,

  /// 繋がってる（ライム起きてる）
  connected,

  /// 切断検知、自動再接続中
  disconnected,

  /// 自動再接続を諦めた（ライム寝てる）
  /// → ユーザー送信時に手動で再接続試行する
  offline,
}

class RaimServerService implements LLMService {
  final String serverUrl;

  /// 再接続の最大試行回数（これを超えると offline 状態に遷移）
  final int maxReconnectAttempts;

  /// 1リクエストの全体タイムアウト
  /// （chat 受信までこの時間以内に来なければエラー扱い）
  final Duration requestTimeout;

  RaimServerService({
    required this.serverUrl,
    this.maxReconnectAttempts = 3,
    this.requestTimeout = const Duration(seconds: 60),
  });

  // ─── 内部状態 ───
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  StreamController<LLMResponse>? _broadcaster;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  bool _intentionalClose = false; // disposeか自動切断かの判別

  // ─── 接続状態（外部公開） ───
  final _stateController = StreamController<RaimConnectionState>.broadcast();
  RaimConnectionState _state = RaimConnectionState.connecting;
  RaimConnectionState get state => _state;

  /// 接続状態の変化を購読するための Stream
  Stream<RaimConnectionState> get stateStream => _stateController.stream;

  /// プロアクティブメッセージなど、リクエスト外の受信を購読したい場合に使う
  /// 将来の `proactive_message` 拡張で使用
  Stream<LLMResponse> get incomingStream {
    _broadcaster ??= StreamController<LLMResponse>.broadcast();
    return _broadcaster!.stream;
  }

  void _setState(RaimConnectionState newState) {
    if (_state == newState) return;
    _state = newState;
    _stateController.add(newState);
    // ignore: avoid_print
    print('[RaimServerService] State: $newState');
  }

  // ─────────────────────────────────────────────
  // ライフサイクル: connect / disconnect
  // ─────────────────────────────────────────────

  /// 接続を確立する（アプリ起動時に呼ぶ）
  /// 既に接続中なら何もしない
  Future<void> connect() async {
    if (_state == RaimConnectionState.connected) return;
    _intentionalClose = false;
    _setState(RaimConnectionState.connecting);

    try {
      _channel = WebSocketChannel.connect(Uri.parse(serverUrl));

      // ready を待ってから state 更新（web_socket_channel v3 から ready が使える）
      await _channel!.ready;

      _broadcaster ??= StreamController<LLMResponse>.broadcast();

      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      _reconnectAttempts = 0;
      _setState(RaimConnectionState.connected);
    } catch (e) {
      // ignore: avoid_print
      print('[RaimServerService] connect failed: $e');
      await _scheduleReconnect();
    }
  }

  /// 接続を切断する（アプリ終了時に呼ぶ）
  Future<void> disconnect() async {
    _intentionalClose = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close(ws_status.normalClosure);
    _channel = null;
    _subscription = null;
    await _broadcaster?.close();
    _broadcaster = null;
    await _stateController.close();
  }

  // ─────────────────────────────────────────────
  // 受信ハンドラ
  // ─────────────────────────────────────────────

  void _onMessage(dynamic rawMessage) {
    try {
      final data = jsonDecode(rawMessage as String) as Map<String, dynamic>;
      final response = LLMResponse.fromJson(data);
      _broadcaster?.add(response);
    } catch (e) {
      // ignore: avoid_print
      print('[RaimServerService] Parse error: $e (raw: $rawMessage)');
      // パース失敗してもアプリは落とさず、エラーを broadcaster に流すかは要検討
    }
  }

  void _onError(dynamic error) {
    // ignore: avoid_print
    print('[RaimServerService] Stream error: $error');
  }

  void _onDone() {
    // ignore: avoid_print
    print('[RaimServerService] Connection closed by server');
    if (_intentionalClose) return;
    _scheduleReconnect();
  }

  // ─────────────────────────────────────────────
  // 自動再接続（指数バックオフ）
  // ─────────────────────────────────────────────

  Future<void> _scheduleReconnect() async {
    _reconnectAttempts++;

    if (_reconnectAttempts > maxReconnectAttempts) {
      _setState(RaimConnectionState.offline);
      return;
    }

    _setState(RaimConnectionState.disconnected);

    // 1秒 → 2秒 → 4秒 ...
    final delaySeconds = 1 << (_reconnectAttempts - 1);
    // ignore: avoid_print
    print('[RaimServerService] Reconnect attempt $_reconnectAttempts in ${delaySeconds}s');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      // 既存の接続オブジェクトをクリーンアップ
      await _subscription?.cancel();
      _subscription = null;
      _channel = null;
      // 再接続試行
      await connect();
    });
  }

  /// 「寝てるライムを起こす」用：offline 状態から手動で再接続を試みる
  /// sendMessage が呼ばれた時に内部で使う
  Future<void> _wakeUp() async {
    _reconnectAttempts = 0; // カウンタをリセット
    await connect();
  }

  // ─────────────────────────────────────────────
  // LLMService 実装: sendMessage
  // ─────────────────────────────────────────────

  @override
  Stream<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
  }) async* {
    // offline ならまず起こす
    if (_state == RaimConnectionState.offline ||
        _state == RaimConnectionState.disconnected) {
      // ignore: avoid_print
      print('[RaimServerService] Waking up RAiM...');
      await _wakeUp();
    }

    // 接続できなかったら諦めてエラー
    if (_state != RaimConnectionState.connected) {
      throw Exception('ライムに繋がらないみたい……（state=$_state）');
    }

    // 既存接続でメッセージ送信
    _channel!.sink.add(jsonEncode({'text': userInput}));

    // ブロードキャストから次の chat が来るまで listening
    // 同じユーザー入力の応答だけを抽出するための簡易ルール:
    //   - filler_audio はスルー
    //   - chat が来たら break
    final completer = Completer<void>();
    final responses = <LLMResponse>[];
    StreamSubscription? sub;
    Timer? timeoutTimer;

    timeoutTimer = Timer(requestTimeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('ライムからの応答が遅すぎます', requestTimeout),
        );
      }
    });

    sub = _broadcaster!.stream.listen((response) {
      responses.add(response);
      if (response.isChat) {
        if (!completer.isCompleted) completer.complete();
      }
    });

    try {
      await completer.future;
    } finally {
      timeoutTimer.cancel();
      await sub.cancel();
    }

    // 受け取った順に yield
    for (final r in responses) {
      yield r;
    }
  }
}