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
  
  WindowsUnityBridge({this.port = 8765});
  
  @override
  Future<void> start() async {
    final handler = webSocketHandler((WebSocketChannel webSocket, _) {
      print('Unity 接続: ${_clients.length + 1}台目');
      _clients.add(webSocket);
      
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
  
  @override
  void sendEmotion({
    required String text,
    required String emotion,
    required double intensity,
  }) {
    final message = jsonEncode({
      'type': 'emotion_change',
      'text': text,
      'emotion': emotion,
      'intensity': intensity,
    });
    
    for (final client in _clients) {
      try {
        client.sink.add(message);
      } catch (e) {
        print('送信エラー: $e');
      }
    }
    
    print('送信: $message (${_clients.length}台に配信)');
  }
  // ============================================================
  // v2.2: 複数感情送信
  // ============================================================
  // 新仕様では emotions / overallIntensity をUnityへ送る。
  // Windows版ではWebSocket経由で、接続中のUnityクライアント全てに送信する。
  @override
  void sendEmotions({
    required Map<String, double> emotions,
    required double overallIntensity,
  }) {
    // Unity がない環境では何もしない
  }

@override
void sendToolState({
  required bool isUsingTool,
  String? description,
}) {
  final message = jsonEncode({
    'type': 'tool_state',
    'is_using_tool': isUsingTool,
    'description': description,
  });

  for (final client in _clients) {
    try {
      client.sink.add(message);
    } catch (e) {
      print('Tool状態送信エラー: $e');
    }
  }

  print(
    'Tool状態送信: $message '
    '(${_clients.length}台に配信)',
  );
}
  
  @override
  Future<void> stop() async {
    for (final client in _clients) {
      await client.sink.close();
    }
    _clients.clear();
    await _server?.close();
    _server = null;
  }
}