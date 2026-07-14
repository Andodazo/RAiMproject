//プラットフォーム判定と起動 アプリ全体の土台を作る
// lib/main.dart  (v3 - 認証後接続対応)
// 変更点:
// - main() では Unity Bridge と Provider の準備だけを行う
// - WebSocket 接続は Cognito 認証済みになってから SplashScreen 側で開始する
// - WidgetsBindingObserver でアプリのライフサイクルを監視し、終了時に RaimServerService を破棄する

/*アプリ起動
↓
Unity連携準備
↓
Provider登録
↓
SplashScreen表示
↓
Cognito認証状態を確認
↓
認証済みなら既存WebSocket接続を開始してChatScreenを表示*/

import 'dart:async' show unawaited;
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

  // RAiM サーバー接続用のサービスを作成する。
  // 未認証状態で WebSocket 接続しないよう、connect() は SplashScreen で認証済みを確認してから呼ぶ。
  final authProvider = AuthProvider(AuthService());
  final raimService = RaimServerService(serverUrl: _raimServerUrl);
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
    unawaited(widget.raimService.dispose());
    super.dispose();
  }

  //アプリの状態変化をみて終了しそうな時だけRaimサーバーから切断。バックグラウンドに行ったときは接続は維持のまま
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // バックグラウンド遷移時は接続維持（モバイルでは即切れる可能性あり）
    // 戻ってきた時に必要なら再接続が走る（RaimServerService 内部で）
    if (state == AppLifecycleState.detached) {
      //アプリ終了時に通信を残さないように
      unawaited(widget.raimService.disconnect());
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
