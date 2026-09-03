import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:raim_prototype/services/raim_log.dart';

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

  /// Unity との相互確認に使う合言葉。
  ///
  /// localhost:8765 は同じ PC のどのプロセスからでも接続できる。
  /// 起動のたびに作り直し、Flutter がファイルへ書いて Unity が読む。
  /// これで「Unity 以外は繋げない」「偽の Flutter には繋がない」の両方を満たす。
  final String _token = _createToken();

  /// 認証されるまで待つ時間。超えたら切断する。
  static const Duration _authTimeout = Duration(seconds: 5);

  /// 認証できなかった接続を切るときの close コード。
  ///
  /// WebSocket の仕様で、アプリが自由に使えるのは 4000〜4999。
  /// 1008（Policy Violation）は予約領域で、
  /// web_socket パッケージに弾かれる。
  static const int _unauthorizedCloseCode = 4401;

  /// Unity を起動中かどうか。
  ///
  /// 接続が来るまで数秒かかるため、_clients.isEmpty だけを見ていると
  /// トレイの「ライムを表示」を連打したときに Unity が多重起動する。
  bool _launching = false;

  /// Unity から上がってくるメッセージ（unity.clicked など）
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  /// Unity がまだ繋がっていない間のメッセージを溜めておく。
  final List<String> _pending = [];
  static const int _maxPending = 16;

  /// 受信ログを全部出すか。
  ///
  /// unity.moved は追従のため毎フレーム近く飛んでくるので、
  /// 既定ではログに出さない。通信を追いたいときだけ true にする。
  final bool verboseLog;

  /// ログに出さないメッセージ種別
  static const Set<String> _quietTypes = {'unity.moved'};

  WindowsUnityBridge({
    this.port = 8765,
    this.autoLaunchUnity = true,
    this.verboseLog = false,
  });

  @override
  Stream<Map<String, dynamic>> get unityEvents => _events.stream;

  @override
  bool get isUnityConnected => _clients.isNotEmpty;

  @override
  Future<void> ensureUnityRunning() async {
    if (_clients.isNotEmpty) {
      RaimLog.d('Unity は接続中のため起動しません');
      return;
    }
    await _launchUnity();
  }

  /// 接続してきたクライアントを受け付ける。
  ///
  /// 最初のメッセージが合言葉でなければ切る。
  /// 認証が済むまで _clients には入れないので、
  /// 未認証の接続へは何も送らないし、接続台数にも数えない。
  void _acceptClient(WebSocketChannel webSocket) {
    var authenticated = false;

    Timer? authTimer = Timer(_authTimeout, () {
      if (authenticated) return;
      RaimLog.w('[UnityBridge] 認証されないまま時間切れ。接続を切ります');
      webSocket.sink.close(_unauthorizedCloseCode, 'unauthorized');
    });

    void cleanUp() {
      authTimer?.cancel();
      authTimer = null;
      _clients.remove(webSocket);
    }

    webSocket.stream.listen(
      (message) {
        if (!authenticated) {
          if (!_verifyAuth(message)) {
            RaimLog.w('[UnityBridge] 合言葉が違う接続を切ります');
            webSocket.sink.close(_unauthorizedCloseCode, 'unauthorized');
            return;
          }

          authenticated = true;
          authTimer?.cancel();
          authTimer = null;

          // Unity 側にも同じ合言葉を返す。
          // これで Unity は「本物の RAiM に繋がっている」ことを確認できる。
          webSocket.sink.add(jsonEncode({'type': 'auth.ok', 'token': _token}));

          _clients.add(webSocket);
          RaimLog.d('Unity 認証成功: ${_clients.length}台目');

          // 溜まっていた分を流して、接続直後から正しい状態にする
          _flushPending(webSocket);
          return;
        }

        _handleMessageFromUnity(message);
      },
      onDone: () {
        RaimLog.d('Unity 切断');
        cleanUp();
      },
      onError: (e) {
        RaimLog.e('WebSocket エラー: $e');
        cleanUp();
      },
    );
  }

  /// 最初のメッセージが正しい合言葉かどうか。
  bool _verifyAuth(dynamic rawMessage) {
    if (rawMessage is! String) return false;

    try {
      final decoded = jsonDecode(rawMessage);
      if (decoded is! Map) return false;
      if (decoded['type'] != 'auth') return false;

      final token = decoded['token'];
      return token is String && token == _token;
    } catch (_) {
      return false;
    }
  }

  /// 推測されない合言葉を作る。
  static String _createToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// 合言葉をファイルへ書く。Unity はここから読む。
  Future<void> _writeTokenFile() async {
    final sep = Platform.pathSeparator;
    final baseDir =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    final dir = Directory('$baseDir${sep}RAiM');

    await dir.create(recursive: true);
    await File('${dir.path}${sep}bridge_token').writeAsString(_token, flush: true);
  }

  /// 合言葉ファイルを消す。終了後に残しても意味がないため。
  Future<void> _deleteTokenFile() async {
    try {
      final sep = Platform.pathSeparator;
      final baseDir =
          Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
      final file = File('$baseDir${sep}RAiM${sep}bridge_token');
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      RaimLog.e('[UnityBridge] 合言葉ファイルの削除に失敗', e);
    }
  }

  // ============================================================
  // 起動 / 終了
  // ============================================================

  @override
  Future<void> start() async {
    // allowedOrigins を空にすると、Origin ヘッダを付ける接続（＝ブラウザ）を
    // すべて弾く。Unity の WebSocket クライアントは Origin を付けないので通る。
    // これを指定しないと、悪意のあるページを開いただけで
    // localhost:$port へ接続されうる。
    final originGuardedHandler = webSocketHandler(
      (WebSocketChannel webSocket, _) => _acceptClient(webSocket),
      allowedOrigins: const <String>[],
    );

    // Unity が起動直後に読むので、サーバーより先に書いておく。
    await _writeTokenFile();

    try {
      _server = await shelf_io.serve(originGuardedHandler, 'localhost', port);
    } catch (e) {
      // ポートが既に使われている（RAiM の二重起動、他プロセスが占有）。
      // 以前はここで例外が main() まで抜け、UI が出ないまま落ちていた。
      RaimLog.e('WebSocketサーバーを起動できません (port=$port)', e);
      rethrow;
    }

    RaimLog.d('WebSocketサーバー起動: ws://localhost:$port');

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
      RaimLog.d('Unity は既に接続済みのため自動起動しません');
      return;
    }

    await _launchUnity();
  }

  @override
  Future<void> stop() async {
    // _clients をそのまま回すと、await の間に onDone が
    // _clients.remove() を呼んで ConcurrentModificationError になる。
    // コピーを回す。
    for (final client in _clients.toList()) {
      try {
        await client.sink.close();
      } catch (e) {
        RaimLog.e('クライアントの切断に失敗', e);
      }
    }
    _clients.clear();
    _pending.clear();

    _unityProcess?.kill();
    _unityProcess = null;

    await _server?.close();
    _server = null;

    await _deleteTokenFile();

    await _events.close();
  }

  // ============================================================
  // Unity の自動起動
  // ============================================================

  Future<void> _launchUnity() async {
    // 起動処理が走っている間は二重に起こさない。
    // Unity は接続まで数秒かかるので、_clients を見るだけでは足りない。
    if (_launching) {
      RaimLog.d('Unity を起動中のため、重ねて起動しません');
      return;
    }
    _launching = true;

    try {
      await _launchUnityInternal();
    } finally {
      _launching = false;
    }
  }

  Future<void> _launchUnityInternal() async {
    final exePath = _resolveUnityExePath();

    if (exePath == null) {
      RaimLog.d('Unity の実行ファイルが見つかりません。');
      RaimLog.d('Unity Editor から手動で再生してください。');
      return;
    }

    // 既に自分が起こしたプロセスがあるなら、二重に起こさない。
    if (_unityProcess != null) {
      RaimLog.d('Unity は起動済みのため、重ねて起動しません');
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
      RaimLog.d('Unity を起動しました: $exePath');
    } catch (e) {
      RaimLog.e('Unity の起動に失敗: $e');
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

    RaimLog.d('探した場所:');
    for (final path in candidates) {
      RaimLog.d('  $path');
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
      RaimLog.d('[UnityBridge] 未接続のため保留 ${RaimLog.size(message)}');
      return;
    }

    for (final client in _clients) {
      try {
        client.sink.add(message);
      } catch (e) {
        RaimLog.e('送信エラー: $e');
      }
    }

    RaimLog.d('[UnityBridge] 送信 ${RaimLog.size(message)} (${_clients.length}台に配信)');
  }

  void _flushPending(WebSocketChannel client) {
    for (final message in _pending) {
      try {
        client.sink.add(message);
      } catch (e) {
        RaimLog.e('保留分の送信エラー: $e');
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

      final type = decoded['type'] as String?;
      if (verboseLog || !_quietTypes.contains(type)) {
        RaimLog.d('[UnityBridge] 受信 type=$type ${RaimLog.size(message)}');
      }

      _events.add(decoded);
    } catch (e) {
      RaimLog.w('[UnityBridge] 不正なメッセージ ${RaimLog.size(message)}: $e');
    }
  }
}
