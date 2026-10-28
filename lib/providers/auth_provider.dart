import 'package:flutter/foundation.dart';
import 'package:raim_prototype/models/auth_tokens.dart';
import 'package:raim_prototype/services/app_window_service.dart';
import 'package:raim_prototype/services/auth_service.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/passkey_registration.dart';

enum AuthStatus {
  checking,
  authenticated,
  unauthenticated,
  authenticating,
  error,
}

/// 起動時認証とログイン状態を UI に渡す Provider です。
class AuthProvider extends ChangeNotifier {
  final AuthService _authService;

  AuthStatus _status = AuthStatus.checking;
  AuthTokens? _tokens;
  String? _errorMessage;
  PasskeyRegistrationResult? _passkeyNotice;

  AuthProvider(this._authService);

  AuthStatus get status => _status;
  AuthTokens? get tokens => _tokens;
  String? get errorMessage => _errorMessage;
  bool get isAuthenticated => _status == AuthStatus.authenticated;
  PasskeyRegistrationResult? get passkeyNotice => _passkeyNotice;

  Future<void> initialize() async {
    _setStatus(AuthStatus.checking);

    // ここで例外が抜けると SplashScreen は checking のまま固まり、
    // 再試行もログイン画面への遷移もできなくなる。
    // 起動できないより、未認証としてログイン画面へ進めるほうがまし。
    try {
      await _authService.startListening(onCallback: handleCallback);

      final tokens = await _authService.loadValidTokens();
      if (tokens == null) {
        _tokens = null;
        _setStatus(AuthStatus.unauthenticated);
        return;
      }

      _tokens = tokens;
      _setStatus(AuthStatus.authenticated);
    } catch (e) {
      RaimLog.e('[AuthProvider] 起動時の認証初期化に失敗', e);
      _tokens = null;
      _errorMessage = '認証情報を確認できませんでした。通信状態を確認してやり直してください。';
      _setStatus(AuthStatus.unauthenticated);
    }
  }

  Future<void> startLogin() async {
    // 進行中のログインがあるうちは新しい試行を始めない。
    // AuthService 側でも共有するが、UI 側の状態遷移も抑える。
    if (_status == AuthStatus.authenticating) {
      return;
    }

    try {
      _errorMessage = null;
      _setStatus(AuthStatus.authenticating);
      final tokens = await _authService.startLogin();
      if (tokens != null) {
        _tokens = tokens;
        _setStatus(AuthStatus.authenticated);
        await AppWindowService.activateAfterLogin();
      }
    } catch (e) {
      _errorMessage = e.toString();
      _setStatus(AuthStatus.error);
    }
  }

  Future<Uri> createEmbeddedLoginUri() async {
    try {
      _errorMessage = null;
      _setStatus(AuthStatus.authenticating);
      return await _authService.createLoginUri();
    } catch (e) {
      _errorMessage = e.toString();
      _setStatus(AuthStatus.error);
      rethrow;
    }
  }

  Future<void> handleCallback(Uri uri) async {
    final wasPending = _authService.isPasskeyRegistrationPending;
    if (await _authService.shouldHandlePasskeyCallback(uri)) {
      final result = await _authService.handlePasskeyCallback(uri);
      // 同じプロセスの登録は、登録開始側が結果を表示する。アプリ再起動後
      // の callback だけここで通知を保持し、ChatScreen に表示させる。
      if (!wasPending) {
        _passkeyNotice = result;
        notifyListeners();
      }
      return;
    }

    try {
      _errorMessage = null;
      _setStatus(AuthStatus.checking);
      _tokens = await _authService.handleCallback(uri);
      _setStatus(AuthStatus.authenticated);
      await AppWindowService.activateAfterLogin();
    } catch (e) {
      _tokens = null;
      _errorMessage = e.toString();
      _setStatus(AuthStatus.error);
    }
  }

  void clearPasskeyNotice() {
    _passkeyNotice = null;
  }

  /// 認証済みユーザーのパスキー登録ページを開きます。
  Future<PasskeyRegistrationResult> startPasskeyRegistration() {
    if (!isAuthenticated) {
      return Future<PasskeyRegistrationResult>.value(
        PasskeyRegistrationResult.failed,
      );
    }
    return _authService.startPasskeyRegistration();
  }

  Future<bool> hasRegisteredPasskey() {
    return _authService.hasRegisteredPasskey();
  }

  Future<String?> getValidAccessToken() {
    return _authService.getValidAccessToken();
  }

  // 修正: main.dart から参照するIDトークン取得APIを保持し、接続時のコンパイルエラーを防ぐ。
  Future<String?> getValidIdToken() {
    return _authService.getValidIdToken();
  }

  Future<void> logout() async {
    await _authService.logout();
    _tokens = null;
    _setStatus(AuthStatus.unauthenticated);
  }

  /// アプリ終了を前提にしたログアウト処理です。
  ///
  /// 通常の `logout()` は未認証状態を通知して LoginScreen へ戻します。
  /// ただし今回のWindows検証では「ログアウトしたらそのままアプリを閉じる」ため、
  /// 終了直前にLoginScreenの自動認証開始が走らないよう、状態通知は行いません。
  Future<void> logoutForExit() async {
    await _authService.logout();
    _tokens = null;
    // 修正（1）: アプリを終了できない場合も、ログアウト後の状態を未認証にする。
    _status = AuthStatus.unauthenticated;
  }

  // 修正（1）: chat_screen.dart が終了失敗時に呼ぶ通知APIを保持する。
  void notifyLogoutFallback() {
    notifyListeners();
  }

  Future<void> disposeService() {
    return _authService.dispose();
  }

  void _setStatus(AuthStatus status) {
    _status = status;
    notifyListeners();
  }
}
