import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/services/llm_service.dart';
import 'package:raim_prototype/services/unity_bridge.dart';
import 'package:raim_prototype/screens/chat_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Unity との通信ブリッジを起動
  final unityBridge = UnityBridge();
  await unityBridge.start();
  
  runApp(RaimApp(unityBridge: unityBridge));
}

class RaimApp extends StatelessWidget {
  final UnityBridge unityBridge;
  
  const RaimApp({super.key, required this.unityBridge});
  
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      // create: (_) => ChatProvider(MockLLMService(), unityBridge), // Mockの場合
      create: (_) => ChatProvider(OllamaService(), unityBridge), // Ollamaの場合
      // create: (_) => ChatProvider(OllamaService(baseUrl: 'http://100.x.x.x:11434'), unityBridge), // Tailscale経由で接続する場合
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