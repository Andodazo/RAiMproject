//プラットフォーム判定と起動 アプリ全体の土台を作る
// lib/main.dart  (v3 - 永続接続対応)
// 変更点:
// - main() で RaimServerService.connect() を起動時に呼ぶ
// - WidgetsBindingObserver でアプリのライフサイクルを監視し、終了時に disconnect()
// - 接続失敗してもアプリは起動する（裏で自動再接続が走る）

/*アプリ起動
↓
Unity連携準備
↓
RAiMサーバー接続開始
↓
Provider登録
↓
ChatScreenを表示*/

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/auth_provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/providers/camera_provider.dart';
import 'package:raim_prototype/screens/splash_screen.dart';
import 'package:raim_prototype/services/auth_service.dart';
import 'package:raim_prototype/services/raim_server_service.dart';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:raim_prototype/services/WindowsUnityBridge.dart';
import 'package:raim_prototype/services/embed_unity_bridge.dart';

// ====================================================
// RAiM サーバー接続先URL
// ====================================================
// [自宅で同一PC開発時] localhost
// const String _raimServerUrl = 'ws://127.0.0.1:8080';
//
// [Tailscale経由 / 学校から / 別デバイスから]
const String _raimServerUrl = 'ws://100.81.35.109:8080';
//
// ↑ 100.x.y.z は自宅PCのTailscale IPに置き換える
//   サーバー側で `tailscale ip -4` で確認可能
// ====================================================

void main() async {
  //ウィジェットを使うための初期化処理
  WidgetsFlutterBinding.ensureInitialized();

  // Unity Bridge
  final UnityCommunicator unityBridge = _createUnityBridge();
  await unityBridge.start();

  // RAiM サーバー接続（非同期、接続失敗してもアプリは起動）
  // 起動を待つとアプリ表示が遅れるので、裏で接続させる
  final authProvider = AuthProvider(AuthService());
  final raimService = RaimServerService(serverUrl: _raimServerUrl);
  // ignore: unawaited_futures
  raimService.connect(); // 失敗しても自動リトライ + offline 遷移
  //RaimAppにraimServiceとunityBridgeを入れている
  runApp(
    RaimApp(
      authProvider: authProvider,
      raimService: raimService,
      unityBridge: unityBridge,
    ),
  );
}

//webかアプリかを判定
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
  final AuthProvider authProvider;
  final RaimServerService raimService;
  final UnityCommunicator unityBridge;
  //Raimappのコンストラクタ
  const RaimApp({
    super.key,
    required this.authProvider,
    required this.raimService,
    required this.unityBridge,
  });

  @override
  State<RaimApp> createState() => _RaimAppState();
}

//RaimAppの状態を管理するクラスを作る
//アプリの起動中・終了・バックグラウンドなどの変化を監視できるようにする
class _RaimAppState extends State<RaimApp> with WidgetsBindingObserver {
  //RaimApp が起動したタイミングで、アプリのライフサイクル変化を受け取れるように登録している
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  //サーバーから切断された場合状態管理を解く処理
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.authProvider.disposeService();
    widget.raimService.disconnect();
    super.dispose();
  }

  //アプリの状態変化をみて終了しそうな時だけRaimサーバーから切断。バックグラウンドに行ったときは接続は維持のまま
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // バックグラウンド遷移時は接続維持（モバイルでは即切れる可能性あり）
    // 戻ってきた時に必要なら再接続が走る（RaimServerService 内部で）
    if (state == AppLifecycleState.detached) {
      //アプリ終了時に通信を残さないように
      widget.raimService.disconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    //MultiProviderに書き換えて、複数のプロバイダーを登録できるようにする
    return MultiProvider(
      providers: [
        // 起動時認証・ログイン状態管理
        ChangeNotifierProvider.value(value: widget.authProvider),
        // ログアウト終了処理などから明示的に disconnect できるように公開
        Provider<RaimServerService>.value(value: widget.raimService),
        //既存のChatProvider
        ChangeNotifierProvider(
          create: (_) => ChatProvider(widget.raimService, widget.unityBridge),
        ),
        //新しく追加するCameraProvider
        ChangeNotifierProvider(create: (_) => CameraProvider()),
      ],

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
        home: const SplashScreen(),
      ),
    );
  }
}
