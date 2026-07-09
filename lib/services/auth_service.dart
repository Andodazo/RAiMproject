import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:raim_prototype/config/raim_config.dart';
import 'package:raim_prototype/models/auth_tokens.dart';
import 'package:raim_prototype/services/browser_login_launcher.dart';
import 'package:raim_prototype/services/local_callback_server.dart';
import 'package:raim_prototype/services/token_storage.dart';

/// Cognito Managed Login / PKCE / Token 保存をまとめて扱うサービスです。
///
/// 画面側はこのクラスの細かい OAuth 処理を知らなくてよく、
/// 「起動時確認」「ログイン開始」「callback処理」「ログアウト」だけを呼びます。
class AuthService {
  final TokenStorage _storage;
  final AppLinks _appLinks;
  final LocalCallbackServer _localCallbackServer;
  final BrowserLoginLauncher _browserLoginLauncher;

  StreamSubscription<Uri>? _linkSubscription;
  Future<void> Function(Uri uri)? _onCallback;

  AuthService({
    TokenStorage? storage,
    AppLinks? appLinks,
    LocalCallbackServer? localCallbackServer,
    BrowserLoginLauncher? browserLoginLauncher,
  }) : _storage = storage ?? TokenStorage(),
       _appLinks = appLinks ?? AppLinks(),
       _localCallbackServer = localCallbackServer ?? LocalCallbackServer(),
       _browserLoginLauncher = browserLoginLauncher ?? BrowserLoginLauncher();

  /// Deep Link 受信を開始します。
  ///
  /// アプリ起動後すぐに呼んでおくことで、Cognito から
  /// `raim://callback?code=...&state=...` で戻ってきた時に処理できます。
  Future<void> startListening({
    required Future<void> Function(Uri uri) onCallback,
  }) async {
    _onCallback = onCallback;

    await _linkSubscription?.cancel();
    _linkSubscription = _appLinks.uriLinkStream.listen(
      _handleIncomingUri,
      onError: (error) {
        debugPrint('[AuthService] Deep Link listen error: $error');
      },
    );

    // アプリが callback URL から cold start された場合に備えます。
    final initialUri = await _appLinks.getInitialLink();
    if (initialUri != null) {
      await _handleIncomingUri(initialUri);
    }
  }

  Future<void> dispose() async {
    await _linkSubscription?.cancel();
    await _localCallbackServer.close();
    await _browserLoginLauncher.closeLaunchedBrowser();
  }

  /// 保存済み Token を読み、必要なら Refresh します。
  ///
  /// 起動時の Splash 画面と、WebSocket 接続前の両方から使います。
  Future<AuthTokens?> loadValidTokens() async {
    final tokens = await _storage.readTokens();
    if (tokens == null) return null;

    if (!tokens.isExpiringSoon) {
      return tokens;
    }

    return refreshTokens(tokens);
  }

  /// Cognito Managed Login の URL を作ります。
  ///
  /// PKCE の `code_verifier` と `state` は callback 処理で必要になるため、
  /// URL 作成時に一時保存します。
  Future<Uri> createLoginUri() async {
    final codeVerifier = _createRandomUrlSafeString(64);
    final state = _createRandomUrlSafeString(32);
    final codeChallenge = _createCodeChallenge(codeVerifier);

    await _storage.savePkceState(codeVerifier: codeVerifier, state: state);

    return Uri.parse('${RaimConfig.cognitoDomain}/login').replace(
      queryParameters: {
        'client_id': RaimConfig.clientId,
        'response_type': 'code',
        'scope': RaimConfig.scope,
        'redirect_uri': _redirectUri,
        'code_challenge_method': 'S256',
        'code_challenge': codeChallenge,
        'state': state,
        // Cognito Managed Login の表示言語を日本語へ寄せる。
        // `lang` は Cognito Hosted UI / Managed Login 向け、`ui_locales` は OAuth/OIDC の
        // 一般的なUIロケール指定として付けておく。
        'lang': 'ja',
        'ui_locales': 'ja',
        // WebView内の検証では、Cognitoが既存セッションを見つけた時に
        // "You're still signed in" 画面で止まりやすいので、毎回ログイン操作を促す。
        'prompt': 'login',
      },
    );
  }

  /// Cognito Managed Login を外部ブラウザで開きます。
  ///
  /// Google OAuth は埋め込み WebView で完走できないことがあるため、Windows では
  /// `http://localhost:3000/callback` を一時HTTPサーバーで待ち受けてから、
  /// Chrome を kiosk モードで起動してCognitoを開きます。
  ///
  /// Windows 以外では従来どおり Deep Link が戻ってくるのを待つため、ここでは Token を返しません。
  Future<AuthTokens?> startLogin() async {
    final loginUri = await createLoginUri();
    Future<Uri>? loopbackCallback;

    if (_usesLoopbackRedirect) {
      loopbackCallback = _localCallbackServer.waitForCallback();
    }

    final launched = await _browserLoginLauncher.launch(loginUri);

    if (!launched) {
      await _localCallbackServer.close();
      throw Exception('Cognitoログイン画面を開けませんでした。');
    }

    if (loopbackCallback == null) {
      return null;
    }

    try {
      final callbackUri = await loopbackCallback;
      return handleCallback(callbackUri);
    } finally {
      await _browserLoginLauncher.closeLaunchedBrowser();
    }
  }

  /// Cognito から戻ってきた callback URL を処理します。
  Future<AuthTokens> handleCallback(Uri uri) async {
    if (!_isExpectedCallbackUri(uri)) {
      throw Exception('RAiM用ではないcallbackです: $uri');
    }

    final error = uri.queryParameters['error'];
    if (error != null) {
      final description = uri.queryParameters['error_description'];
      throw Exception('Cognitoログインエラー: $error ${description ?? ''}');
    }

    final code = uri.queryParameters['code'];
    final receivedState = uri.queryParameters['state'];
    final savedState = await _storage.readState();
    final codeVerifier = await _storage.readCodeVerifier();

    if (code == null || code.isEmpty) {
      throw Exception('callbackに認証codeが含まれていません。');
    }
    if (receivedState == null ||
        savedState == null ||
        receivedState != savedState) {
      throw Exception('callbackのstateが一致しません。ログインをやり直してください。');
    }
    if (codeVerifier == null || codeVerifier.isEmpty) {
      throw Exception('PKCE code_verifierが見つかりません。ログインをやり直してください。');
    }

    try {
      final tokens = await _exchangeCodeForTokens(
        code: code,
        codeVerifier: codeVerifier,
      );
      await _storage.saveTokens(tokens);
      return tokens;
    } finally {
      await _storage.clearPkceState();
    }
  }

  Future<AuthTokens?> refreshTokens(AuthTokens currentTokens) async {
    final refreshToken = currentTokens.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      await _storage.clearTokens();
      return null;
    }

    final tokenUri = Uri.parse('${RaimConfig.cognitoDomain}/oauth2/token');
    final response = await http.post(
      tokenUri,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'refresh_token',
        'client_id': RaimConfig.clientId,
        'refresh_token': refreshToken,
      },
    );

    if (response.statusCode != 200) {
      await _storage.clearTokens();
      debugPrint('[AuthService] refresh failed: ${response.statusCode}');
      return null;
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final refreshedTokens = _tokensFromResponse(
      body,
      fallbackRefreshToken: refreshToken,
    );
    await _storage.saveTokens(refreshedTokens);
    return refreshedTokens;
  }

  Future<String?> getValidAccessToken() async {
    final tokens = await loadValidTokens();
    return tokens?.accessToken;
  }

  Future<void> logout() async {
    await _browserLoginLauncher.closeLaunchedBrowser();
    await _storage.clearPkceState();
    await _storage.clearTokens();
  }

  Future<void> _handleIncomingUri(Uri uri) async {
    final callback = _onCallback;
    if (callback == null) return;
    if (_isExpectedCallbackUri(uri)) {
      await callback(uri);
    }
  }

  bool get _usesLoopbackRedirect =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  String get _redirectUri => _usesLoopbackRedirect
      ? RaimConfig.windowsRedirectUri
      : RaimConfig.redirectUri;

  bool _isExpectedCallbackUri(Uri uri) {
    final isCustomSchemeCallback =
        uri.scheme == 'raim' && uri.host == 'callback';
    final isLoopbackCallback =
        _usesLoopbackRedirect &&
        uri.scheme == 'http' &&
        (uri.host == 'localhost' || uri.host == '127.0.0.1') &&
        uri.port == 3000 &&
        uri.path == '/callback';

    return isCustomSchemeCallback || isLoopbackCallback;
  }

  Future<AuthTokens> _exchangeCodeForTokens({
    required String code,
    required String codeVerifier,
  }) async {
    final tokenUri = Uri.parse('${RaimConfig.cognitoDomain}/oauth2/token');
    final response = await http.post(
      tokenUri,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'client_id': RaimConfig.clientId,
        'code': code,
        'redirect_uri': _redirectUri,
        'code_verifier': codeVerifier,
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Token取得に失敗しました: ${response.statusCode}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return _tokensFromResponse(body);
  }

  AuthTokens _tokensFromResponse(
    Map<String, dynamic> body, {
    String? fallbackRefreshToken,
  }) {
    final accessToken = body['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw Exception('Tokenレスポンスにaccess_tokenがありません。');
    }

    final expiresIn = (body['expires_in'] as num?)?.toInt() ?? 3600;

    return AuthTokens(
      accessToken: accessToken,
      idToken: body['id_token'] as String?,
      refreshToken: (body['refresh_token'] as String?) ?? fallbackRefreshToken,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
    );
  }

  String _createCodeChallenge(String codeVerifier) {
    final digest = sha256.convert(utf8.encode(codeVerifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  String _createRandomUrlSafeString(int byteLength) {
    final random = Random.secure();
    final bytes = List<int>.generate(byteLength, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
