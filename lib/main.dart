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

import 'dart:async' show StreamSubscription, unawaited;
import 'dart:io' show Platform, exit;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/config/raim_config.dart';
import 'package:raim_prototype/providers/auth_provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/providers/camera_provider.dart';
import 'package:raim_prototype/providers/voice_settings_provider.dart';
import 'package:raim_prototype/screens/splash_screen.dart';
import 'package:raim_prototype/services/auth_service.dart';
import 'package:raim_prototype/services/raim_server_service.dart';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:raim_prototype/services/noop_unity_bridge.dart';
import 'package:raim_prototype/services/windows_unity_bridge.dart';
import 'package:raim_prototype/services/embed_unity_bridge.dart';
import 'package:raim_prototype/services/mascot_window_service.dart';
import 'package:raim_prototype/services/tray_service.dart';
import 'package:raim_prototype/services/mic_stream_service.dart';
import 'package:raim_prototype/services/raim_log.dart';


void main() async {
  //ウィジェットを使うための初期化処理
  WidgetsFlutterBinding.ensureInitialized();

  // Windows のウィンドウ制御を初期化する。
  // 認証中は通常のウィンドウのままで、認証後に入力小窓へ切り替える。
  await MascotWindowService.initialize();

  // トレイの登録はウィジェットのライフサイクルに依存させない。
  // 入力小窓を閉じるとタスクバーからも消えるので、
  // トレイは確実に立ち上がっていないと復帰できなくなる。
  await TrayService.instance.setup();

  // Unity Bridge
  final UnityCommunicator unityBridge = _createUnityBridge();
  // ポートが埋まっている（RAiM の二重起動など）と start() は例外を投げる。
  // ここで落とすと UI が一切出ないまま終了してしまうため、
  // マスコット無しでも起動できるようにする。
  try {
    await unityBridge.start();
  } catch (e) {
    // よくある原因は RAiM の二重起動。マスコットは出ないが、
    // チャット自体は動くのでアプリは続行する。
    RaimLog.e('Unity ブリッジを起動できませんでした（マスコット無しで続行）', e);
  }

  // RAiM サーバー接続用のサービスを作成する。
  // 未認証状態で WebSocket 接続しないよう、connect() は SplashScreen で認証済みを確認してから呼ぶ。
  // 音声機能の設定は runApp より前に読み込む。
  // 起動直後の画面がウェイクワードの ON/OFF を参照するため、
  // 非同期で後から入ると一瞬 OFF の状態が描画される。
  final voiceSettings = VoiceSettingsProvider();
  await voiceSettings.load();

  final authProvider = AuthProvider(AuthService());
  final raimService = RaimServerService(serverUrl: RaimConfig.serverUrl, accessTokenGetter: () => authProvider.getValidAccessToken(),);
  //RaimAppにraimServiceとunityBridgeを入れている
  runApp(
    RaimApp(
      authProvider: authProvider,
      raimService: raimService,
      unityBridge: unityBridge,
      voiceSettings: voiceSettings,
    ),
  );
}

/// 実行中のプラットフォームに合ったマスコット連携を選ぶ。
///
/// 対応しているのは Windows / Android / iOS の3つだけ。
/// Web・macOS・Linux はビルドこそ通るがマスコットは動かないので、
/// 何もしない実装を返してチャットだけ使えるようにする。
/// （以前はどちらも Windows 用へ落ちていて、Web では dart:io の
/// HttpServer で例外、macOS / Linux では raim.exe を探しに行っていた）
UnityCommunicator _createUnityBridge() {
  if (kIsWeb) {
    return NoopUnityBridge();
  }
  if (Platform.isAndroid || Platform.isIOS) {
    return EmbedUnityBridge();
  }
  if (!Platform.isWindows) {
    return NoopUnityBridge();
  }

  // Windows: Unity を自動起動する。
  // ただし Unity Editor から手動で再生している場合に二重起動しないよう、
  // 起動判断は WindowsUnityBridge 側で「2秒待って未接続なら起動」としている。
  return WindowsUnityBridge(autoLaunchUnity: true);
}

class RaimApp extends StatefulWidget {
  final AuthProvider authProvider;
  final RaimServerService raimService;
  final UnityCommunicator unityBridge;
  final VoiceSettingsProvider voiceSettings;
  //Raimappのコンストラクタ
  const RaimApp({
    super.key,
    required this.authProvider,
    required this.raimService,
    required this.unityBridge,
    required this.voiceSettings,
  });

  @override
  State<RaimApp> createState() => _RaimAppState();
}

//RaimAppの状態を管理するクラスを作る
//アプリの起動中・終了・バックグラウンドなどの変化を監視できるようにする
class _RaimAppState extends State<RaimApp> with WidgetsBindingObserver {
  // Unity から届くイベント（Windows のみ流れる）
  StreamSubscription<Map<String, dynamic>>? _unitySub;

  //RaimApp が起動したタイミングで、アプリのライフサイクル変化を受け取れるように登録している
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenUnityEvents();
  }

  // ====================================================
  // Unity → Flutter のイベント購読（Windows のみ）
  // ====================================================
  // モバイルでは EmbedUnityBridge が空の Stream を返すので何も流れない。
  //
  // ここで扱うのはアプリ全体に関わる unity.quit だけ。
  // unity.clicked（入力小窓を開く）と unity.moved（追従）は
  // 窓そのものを操作するものなので WindowsInputWindow 側で購読している。
  //
  // unityEvents は broadcast なので購読者が複数いても問題ないが、
  // 同じイベントを2箇所で処理すると後から追いにくくなる。
  // 「アプリの寿命に関わるものはここ、窓の見た目はウィンドウ側」で分けている。
  void _listenUnityEvents() {
    _unitySub = widget.unityBridge.unityEvents.listen((event) {
      if (event['type'] == 'unity.quit') {
        RaimLog.d('[Unity] 終了通知を受信。Flutter も終了します');
        _quitWithUnity();
      }
    });
  }

  /// Unity 側の Ctrl+Q を受けて Flutter も終了する。
  ///
  /// このメソッドは unityEvents のリスナー内から呼ばれる。
  /// その場で unityBridge.stop() を await すると、閉じようとしている
  /// Stream のコールバック中で待つことになり進まなくなるため、
  /// stop() は呼ばず microtask に逃がしてから終了する。
  /// exit(0) でプロセスが終われば WebSocket サーバーも一緒に閉じる。
  void _quitWithUnity() {
    Future.microtask(() async {
      try {
        await widget.raimService.dispose();
      } catch (_) {
        // 終了処理なので失敗しても構わない
      }
      exit(0);
    });
  }

  //サーバーから切断された場合状態管理を解く処理
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unitySub?.cancel();
    widget.authProvider.disposeService();
    unawaited(widget.raimService.dispose());
    // マイクを掴んだままにすると、他アプリから使えなくなる。
    unawaited(MicStreamService.instance.dispose());
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
        // 入力小窓が unity.clicked / unity.moved を購読するために公開
        Provider<UnityCommunicator>.value(value: widget.unityBridge),
        //既存のChatProvider
        ChangeNotifierProvider(
          create: (_) => ChatProvider(widget.raimService, widget.unityBridge),
        ),
        //新しく追加するCameraProvider
        ChangeNotifierProvider(create: (_) => CameraProvider()),
        // 音声機能の ON/OFF。main() で読み込み済みのものを渡す。
        ChangeNotifierProvider.value(value: widget.voiceSettings),
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
