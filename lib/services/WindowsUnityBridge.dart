import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Windows 版での Unity 通信実装
///
/// FlutterはWebSocketサーバーとして動作し、Unityがクライアントとして接続する
/// Unityが接続している場合、FlutterからUnityへJSONメッセージを送信する。
class WindowsUnityBridge implements UnityCommunicator {
  final int port;

  final Set<WebSocketChannel> _clients = {};
  HttpServer? _server;

  /// Unity がまだ繋がっていない間のメッセージを溜めておく。
  /// Unity の起動が Flutter より遅れても直近の状態を復元できる。
  final List<String> _pending = [];
  static const int _maxPending = 16;

  WindowsUnityBridge({this.port = 8765});

  @override
  Future<void> start() async {
    final handler = webSocketHandler((WebSocketChannel webSocket, _) {
      print('Unity 接続: ${_clients.length + 1}台目');
      _clients.add(webSocket);

      // 溜まっていた分を流して、接続直後から正しい表情にする
      _flushPending(webSocket);

      webSocket.stream.listen(
        (message) {
          print('Unity から受信: $message');
        },
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
  }

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

  // ============================================================
  // v2.2: 複数感情送信
  // ============================================================
  // 新仕様では emotions / overallIntensity をUnityへ送る。
  // Windows版ではWebSocket経由で、接続中のUnityクライアント全てに送信する。
  //
  // Unity 側は HandleWebSocketMessage が type を見て振り分け、
  // ReceiveEmotions → EmotionsMessage(EmotionScores) でパースする。
  // EmotionScores は12感情を名前付きフィールドで持つので、
  // emotions マップをそのまま入れれば JsonUtility が読める。
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

  // ============================================================
  // 吹き出し（Windows版のデスクトップマスコット用）
  // ============================================================
  // Unity 側の SpeechBubbleController が受け取って表示する。
  // サーバーから届く text_chunk をそのまま転送するので、
  // 140〜270ms 間隔がそのままタイプライター表示になる。

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
    _broadcast(jsonEncode({
      'type': 'bubble_break',
    }));
  }

  @override
  void sendChatEnd({String? fullText}) {
    _broadcast(jsonEncode({
      'type': 'chat_end',
      'full_text': fullText,
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

  @override
  Future<void> stop() async {
    for (final client in _clients) {
      await client.sink.close();
    }
    _clients.clear();
    _pending.clear();
    await _server?.close();
    _server = null;
  }
}
