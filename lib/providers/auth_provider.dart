import 'package:flutter/foundation.dart';
import 'package:raim_prototype/models/auth_tokens.dart';
import 'package:raim_prototype/services/app_window_service.dart';
import 'package:raim_prototype/services/auth_service.dart';

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

  AuthProvider(this._authService);

  AuthStatus get status => _status;
  AuthTokens? get tokens => _tokens;
  String? get errorMessage => _errorMessage;
  bool get isAuthenticated => _status == AuthStatus.authenticated;

  Future<void> initialize() async {
    _setStatus(AuthStatus.checking);

    await _authService.startListening(onCallback: handleCallback);

    final tokens = await _authService.loadValidTokens();
    if (tokens == null) {
      _tokens = null;
      _setStatus(AuthStatus.unauthenticated);
      return;
    }

    _tokens = tokens;
    _setStatus(AuthStatus.authenticated);
  }

  Future<void> startLogin() async {
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

  Future<String?> getValidAccessToken() {
    return _authService.getValidAccessToken();
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
  }

  Future<void> disposeService() {
    return _authService.dispose();
  }

  void _setStatus(AuthStatus status) {
    _status = status;
    notifyListeners();
  }
}
