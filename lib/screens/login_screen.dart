import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/auth_provider.dart';

/// Cognito 認証を開始する画面です。
///
/// Windows と Android の両方で Google OAuth を安定させるため、アプリ内 WebView ではなく
/// OS の外部ブラウザを使います。
///
/// - Windows: Chrome を kiosk 表示で開き、`http://localhost:3000/callback` を
///   アプリ内の一時 HTTP サーバーで受け取ります。
/// - Android/iOS: 通常の外部ブラウザを開き、`raim://callback` の deep link を
///   `app_links` 経由で受け取ります。
///
/// この画面は「認証を開始した後、callback が戻るまで待つ」役割に絞っています。
/// Token 交換や保存は `AuthProvider` / `AuthService` 側で行います。
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _loginStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startLogin();
    });
  }

  Future<void> _startLogin({bool force = false}) async {
    if (_loginStarted && !force) return;

    _loginStarted = true;
    await context.read<AuthProvider>().startLogin();
  }

  Future<void> _retryLogin() async {
    final auth = context.read<AuthProvider>();
    if (auth.status == AuthStatus.authenticating ||
        auth.status == AuthStatus.checking) {
      return;
    }
    _loginStarted = false;
    await _startLogin(force: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      body: SafeArea(
        child: Consumer<AuthProvider>(
          builder: (context, auth, _) {
            final errorMessage = auth.errorMessage;

            return Column(
              children: [
                _buildHeader(errorMessage),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: _buildBody(auth, errorMessage),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(String? errorMessage) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
      child: Row(
        children: [
          const Text(
            'RAiM',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Text(
              errorMessage == null
                  ? 'Cognito で認証してください。'
                  : '認証画面を開けませんでした。',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          TextButton.icon(
            onPressed: _retryLogin,
            icon: const Icon(Icons.refresh),
            label: const Text('再読み込み'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AuthProvider auth, String? errorMessage) {
    // 認証処理が動いている間は、エラー表示が残っていても待機扱いにする。
    // 以前は errorMessage が付いた瞬間にボタンが出たため、
    // 古い試行のタイムアウトで表示されたエラーを見て押してしまい、
    // 進行中のログインと競合していた。
    final isAuthenticating = auth.status == AuthStatus.authenticating ||
        auth.status == AuthStatus.checking;
    final isWaiting = isAuthenticating ||
        (errorMessage == null &&
            auth.status == AuthStatus.unauthenticated);

    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              errorMessage == null
                  ? Icons.open_in_browser
                  : Icons.error_outline,
              color: errorMessage == null
                  ? Colors.lightGreenAccent
                  : Colors.redAccent,
              size: 44,
            ),
            const SizedBox(height: 18),
            Text(
              errorMessage == null
                  ? '外部ブラウザで Google 認証を開いています'
                  : '認証を完了できませんでした',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              errorMessage ??
                  '認証が完了すると、Windows では localhost callback、Android/iOS では '
                      'raim://callback の deep link でアプリに戻ります。',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.5),
            ),
            const SizedBox(height: 24),
            if (isWaiting) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 14),
              const Text(
                'ブラウザでログインを完了してください...',
                style: TextStyle(color: Colors.white70),
              ),
            ] else
              ElevatedButton.icon(
                onPressed: _retryLogin,
                icon: const Icon(Icons.refresh),
                label: const Text('認証をやり直す'),
              ),
          ],
        ),
      ),
    );
  }
}
