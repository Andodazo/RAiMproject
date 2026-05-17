import 'dart:async';
import 'dart:convert';
import 'dart:io';                      // ← これを追加
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Unity との通信を担当するブリッジ
/// 
/// FlutterはWebSocketサーバーとして動作し、Unityがクライアントとして接続する
/// Flutterから感情パラメータを送信すると、Unity側で立ち絵が切り替わる
class UnityBridge {
  final int port;
  
  // 接続中のクライアント（Unity）を保持
  final Set<WebSocketChannel> _clients = {};
  
  HttpServer? _server;
  
  UnityBridge({this.port = 8765});
  
  /// WebSocketサーバーを起動
  Future<void> start() async {
    final handler = webSocketHandler((WebSocketChannel webSocket, _) {
      print('Unity 接続: ${_clients.length + 1}台目');
      _clients.add(webSocket);
      
      // クライアントからのメッセージを受信（今は使わないが将来用）
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
  
  /// 全クライアントに感情パラメータを送信
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
  
  /// サーバー停止
  Future<void> stop() async {
    for (final client in _clients) {
      await client.sink.close();
    }
    _clients.clear();
    await _server?.close();
    _server = null;
  }
}