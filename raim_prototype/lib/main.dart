import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/services/llm_service.dart';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:raim_prototype/services/WindowsUnityBridge.dart';
import 'package:raim_prototype/services/embed_unity_bridge.dart';
import 'package:raim_prototype/screens/chat_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // プラットフォームに応じた Unity Communicator を選択
  final UnityCommunicator unityBridge = _createUnityBridge();
  await unityBridge.start();
  
  runApp(RaimApp(unityBridge: unityBridge));
}

UnityCommunicator _createUnityBridge() {
  if (kIsWeb) {
    // Web 版は当面非対応、Windows と同じく WebSocket でとりあえず作成
    return WindowsUnityBridge();
  }
  if (Platform.isAndroid || Platform.isIOS) {
    return EmbedUnityBridge();
  }
  // Windows / macOS / Linux
  return WindowsUnityBridge();
}

class RaimApp extends StatelessWidget {
  final UnityCommunicator unityBridge;
  
  const RaimApp({super.key, required this.unityBridge});
  
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      // create: (_) => ChatProvider(MockLLMService(), unityBridge), // Mockの場合
      create: (_) => ChatProvider(OllamaService(), unityBridge), // Ollamaの場合
      // create: (_) => ChatProvider(OllamaService(baseUrl: 'http://100.x.x.x:11434'), unityBridge), // Tailscale経由
      child: MaterialApp(
        title: 'RAiM',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
        ),
        home: const ChatScreen(),
      ),
    );
  }
}