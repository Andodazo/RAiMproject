import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/services/llm_service.dart';
import 'package:raim_prototype/screens/chat_screen.dart';

void main() {
  runApp(const RaimApp());
}

class RaimApp extends StatelessWidget {
  const RaimApp({super.key});
  
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      // create: (_) => ChatProvider(MockLLMService()), // Mockの場合
      create: (_) => ChatProvider(OllamaService()), // Ollamaの場合
      // create: (_) => ChatProvider(OllamaService(baseUrl: 'http://100.x.x.x:11434')), //Tailscale経由で接続する場合
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