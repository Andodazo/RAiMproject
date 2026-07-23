import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/auth_provider.dart';
import 'package:raim_prototype/screens/chat_screen.dart';
import 'package:raim_prototype/screens/login_screen.dart';
import 'package:raim_prototype/services/raim_server_service.dart';

/// アプリ起動直後に表示する認証振り分け画面です。
///
/// ここで保存済み Token の有無・期限・Refresh 可否を確認し、
/// 認証済みなら ChatScreen、未認証なら LoginScreen へ進めます。
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthProvider>().initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        switch (auth.status) {
          case AuthStatus.authenticated:
            return const _AuthenticatedChatScreen();
          case AuthStatus.unauthenticated:
          case AuthStatus.authenticating:
          case AuthStatus.error:
            return const LoginScreen();
          case AuthStatus.checking:
            return const _SplashLoadingView();
        }
      },
    );
  }
}

class _AuthenticatedChatScreen extends StatefulWidget {
  const _AuthenticatedChatScreen();

  @override
  State<_AuthenticatedChatScreen> createState() =>
      _AuthenticatedChatScreenState();
}

class _AuthenticatedChatScreenState extends State<_AuthenticatedChatScreen> {
  bool _startedConnection = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_startedConnection) return;
    _startedConnection = true;

    // 非同期でトークンを取得して接続を開始する
    _connectWithToken();
  }

  Future<void> _connectWithToken() async {
    final raimService = context.read<RaimServerService>();
    final authProvider = context.read<AuthProvider>();

    // 有効なアクセストークンを取得
    final accessToken = await authProvider.getValidAccessToken();

    // トークンを添えて WebSocket へ接続！
    await raimService.connect(accessToken: accessToken);
  }

  @override
  Widget build(BuildContext context) {
    return const ChatScreen();
  }
}

class _SplashLoadingView extends StatelessWidget {
  const _SplashLoadingView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF1a1a2e),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('認証状態を確認しています...', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
