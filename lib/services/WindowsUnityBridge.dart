import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Windows 版での Unity 通信実装
///
/// FlutterはWebSocketサーバーとして動作し、Unityがクライアントとして接続する。
/// Flutter が先にサーバーを立ててから Unity を起動するので、
/// 起動順は常に正しくなる。
class WindowsUnityBridge implements UnityCommunicator {
  final int port;

  /// Unity を自動起動するか。
  /// 開発中は Unity Editor から再生したいので false にできるようにしてある。
  final bool autoLaunchUnity;

  final Set<WebSocketChannel> _clients = {};
  HttpServer? _server;
  Process? _unityProcess;

  /// Unity から上がってくるメッセージ（unity.clicked など）
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  /// Unity がまだ繋がっていない間のメッセージを溜めておく。
  final List<String> _pending = [];
  static const int _maxPending = 16;

  WindowsUnityBridge({
    this.port = 8765,
    this.autoLaunchUnity = true,
  });

  @override
  Stream<Map<String, dynamic>> get unityEvents => _events.stream;

  @override
  bool get isUnityConnected => _clients.isNotEmpty;

  @override
  Future<void> ensureUnityRunning() async {
    if (_clients.isNotEmpty) {
      print('Unity は接続中のため起動しません');
      return;
    }
    await _launchUnity();
  }

  // ============================================================
  // 起動 / 終了
  // ============================================================

  @override
  Future<void> start() async {
    final handler = webSocketHandler((WebSocketChannel webSocket, _) {
      print('Unity 接続: ${_clients.length + 1}台目');
      _clients.add(webSocket);

      // 溜まっていた分を流して、接続直後から正しい状態にする
      _flushPending(webSocket);

      webSocket.stream.listen(
        (message) => _handleMessageFromUnity(message),
        onDone: () {
          print('Unity 切断');
          _clients.remove(webSocket);
        },
        onError: (e) {
          print('WebSocket エラー: $e');
          _clients.remove(webSocket);
        },
      );
    });

    _server = await shelf_io.serve(handler, 'localhost', port);
    print('WebSocketサーバー起動: ws://localhost:$port');

    // サーバーを立ててから Unity を起こす。この順序が大事で、
    // 逆にすると Unity 側が接続に失敗して再接続待ちになる。
    if (autoLaunchUnity) {
      unawaited(_launchUnityIfNeeded());
    }
  }

  /// Unity が自分で繋いでくるのを少し待ってから起動する。
  ///
  /// Unity Editor から再生している開発中は、待っている間に接続が来るので
  /// 二重起動しない。誰も来なければビルド版を起こす。
  /// フラグを切り替えなくても手動起動とビルド版の両方に対応できる。
  Future<void> _launchUnityIfNeeded() async {
    await Future.delayed(const Duration(seconds: 2));

    if (_clients.isNotEmpty) {
      print('Unity は既に接続済みのため自動起動しません');
      return;
    }

    await _launchUnity();
  }

  @override
  Future<void> stop() async {
    for (final client in _clients) {
      await client.sink.close();
    }
    _clients.clear();
    _pending.clear();

    _unityProcess?.kill();
    _unityProcess = null;

    await _server?.close();
    _server = null;

    await _events.close();
  }

  // ============================================================
  // Unity の自動起動
  // ============================================================

  Future<void> _launchUnity() async {
    final exePath = _resolveUnityExePath();

    if (exePath == null) {
      print('Unity の実行ファイルが見つかりません。');
      print('Unity Editor から手動で再生してください。');
      return;
    }

    try {
      _unityProcess = await Process.start(
        exePath,
        [],
        // Flutter 側が Unity の標準出力を握り続けないよう分離する。
        // Unity はログを大量に吐くため。終了は stop() の kill で行う。
        mode: ProcessStartMode.detached,
      );
      print('Unity を起動しました: $exePath');
    } catch (e) {
      print('Unity の起動に失敗: $e');
    }
  }

  /// Unity の exe を探す。
  ///
  /// - 配布時: Flutter の exe と同じ階層の unity\ に置く想定
  /// - 開発時: リポジトリ内の builds\Windows\ を見る
  String? _resolveUnityExePath() {
    final sep = Platform.pathSeparator;
    final flutterDir = File(Platform.resolvedExecutable).parent.path;
    final cwd = Directory.current.path;

    final candidates = <String>[
      // 配布時（Flutter exe の隣）
      '$flutterDir${sep}unity${sep}raim.exe',
      // 開発時（flutter run をリポジトリ直下で実行した場合）
      '$cwd${sep}unity${sep}raim_unity${sep}builds${sep}Windows${sep}raim.exe',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }

    print('探した場所:');
    for (final path in candidates) {
      print('  $path');
    }
    return null;
  }

  // ============================================================
  // 送信
  // ============================================================

  /// 接続中の Unity 全部へ送る。誰もいなければ保留に積む。
  void _broadcast(String message) {
    if (_clients.isEmpty) {
      if (_pending.length >= _maxPending) _pending.removeAt(0);
      _pending.add(message);
      print('Unity 未接続のため保留: $message');
      return;
    }

    for (final client in _clients) {
      try {
        client.sink.add(message);
      } catch (e) {
        print('送信エラー: $e');
      }
    }

    print('送信: $message (${_clients.length}台に配信)');
  }

  void _flushPending(WebSocketChannel client) {
    for (final message in _pending) {
      try {
        client.sink.add(message);
      } catch (e) {
        print('保留分の送信エラー: $e');
      }
    }
    _pending.clear();
  }

  @override
  void sendEmotion({
    required String text,
    required String emotion,
    required double intensity,
  }) {
    _broadcast(jsonEncode({
      'type': 'emotion_change',
      'text': text,
      'emotion': emotion,
      'intensity': intensity,
    }));
  }

  /// v2.2: 複数感情送信
  ///
  /// Unity 側は HandleWebSocketMessage が type を見て振り分け、
  /// ReceiveEmotions → EmotionsMessage(EmotionScores) でパースする。
  /// EmotionScores は12感情を名前付きフィールドで持つので、
  /// emotions マップをそのまま入れれば JsonUtility が読める。
  @override
  void sendEmotions({
    required Map<String, double> emotions,
    required double overallIntensity,
  }) {
    _broadcast(jsonEncode({
      'type': 'emotions',
      'emotions': emotions,
      'overall_intensity': overallIntensity,
    }));
  }

  @override
  void sendToolState({
    required bool isUsingTool,
    String? description,
  }) {
    _broadcast(jsonEncode({
      'type': 'tool_state',
      'is_using_tool': isUsingTool,
      'description': description,
    }));
  }

  // ------------------------------------------------------------
  // 吹き出し
  // ------------------------------------------------------------

  @override
  void sendText({
    required String text,
    bool isFiller = false,
  }) {
    _broadcast(jsonEncode({
      'type': 'text_chunk',
      'text': text,
      'is_filler': isFiller,
    }));
  }

  @override
  void sendBubbleBreak() {
    _broadcast(jsonEncode({'type': 'bubble_break'}));
  }

  @override
  void sendChatEnd({String? fullText}) {
    _broadcast(jsonEncode({
      'type': 'chat_end',
      'full_text': fullText,
    }));
  }

  @override
  void sendError({required String message}) {
    _broadcast(jsonEncode({
      'type': 'error',
      'message': message,
    }));
  }

  @override
  void sendAppQuit() {
    _broadcast(jsonEncode({'type': 'app.quit'}));
  }

  // ============================================================
  // 受信（Unity → Flutter）
  // ============================================================

  /// Unity から届いたメッセージを events ストリームに流す。
  ///
  /// 今のところ来るのは:
  ///   {"type":"unity.clicked"}                       ライムがクリックされた
  ///   {"type":"unity.moved","x":..,"y":..,           ウィンドウが動いた
  ///    "width":..,"height":..}
  void _handleMessageFromUnity(dynamic message) {
    if (message is! String) return;

    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return;

      print('Unity から受信: $message');
      _events.add(decoded);
    } catch (e) {
      print('Unity からの不正なメッセージ: $message ($e)');
    }
  }
}
