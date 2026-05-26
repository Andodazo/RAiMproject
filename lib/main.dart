// lib/main.dart  (v3 - 永続接続対応)
//
// 変更点:
// - main() で RaimServerService.connect() を起動時に呼ぶ
// - WidgetsBindingObserver でアプリのライフサイクルを監視し、終了時に disconnect()
// - 接続失敗してもアプリは起動する（裏で自動再接続が走る）

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/services/llm_service.dart';
import 'package:raim_prototype/services/raim_server_service.dart';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:raim_prototype/services/WindowsUnityBridge.dart';
import 'package:raim_prototype/services/embed_unity_bridge.dart';
import 'package:raim_prototype/screens/chat_screen.dart';

// ====================================================
// RAiM サーバー接続先URL（用途に応じて1つだけ有効に）
// ====================================================
// [自宅で同一PC開発時] localhost
const String _raimServerUrl = 'ws://127.0.0.1:8080';
//
// [Tailscale経由 / 学校から / 別デバイスから]
//const String _raimServerUrl = 'ws://100.x.y.z:8080';
//
// ↑ 100.x.y.z は自宅PCのTailscale IPに置き換える
//   サーバー側で `tailscale ip -4` で確認可能
// ====================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Unity Bridge
  final UnityCommunicator unityBridge = _createUnityBridge();
  await unityBridge.start();

  // RAiM サーバー接続（非同期、接続失敗してもアプリは起動）
  // 起動を待つとアプリ表示が遅れるので、裏で接続させる
  final raimService = RaimServerService(serverUrl: _raimServerUrl);
  // ignore: unawaited_futures
  raimService.connect(); // 失敗しても自動リトライ + offline 遷移

  runApp(RaimApp(
    raimService: raimService,
    unityBridge: unityBridge,
  ));
}

UnityCommunicator _createUnityBridge() {
  if (kIsWeb) {
    return WindowsUnityBridge();
  }
  if (Platform.isAndroid || Platform.isIOS) {
    return EmbedUnityBridge();
  }
  return WindowsUnityBridge();
}

class RaimApp extends StatefulWidget {
  final RaimServerService raimService;
  final UnityCommunicator unityBridge;

  const RaimApp({
    super.key,
    required this.raimService,
    required this.unityBridge,
  });

  @override
  State<RaimApp> createState() => _RaimAppState();
}

class _RaimAppState extends State<RaimApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.raimService.disconnect();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // バックグラウンド遷移時は接続維持（モバイルでは即切れる可能性あり）
    // 戻ってきた時に必要なら再接続が走る（RaimServerService 内部で）
    if (state == AppLifecycleState.detached) {
      widget.raimService.disconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ChatProvider(widget.raimService, widget.unityBridge),

      // [旧] Ollama 直接接続（HTTP）に戻したい時は ↓
      // create: (_) => ChatProvider(OllamaService(), widget.unityBridge),

      // [テスト用] モック
      // create: (_) => ChatProvider(MockLLMService(), widget.unityBridge),

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