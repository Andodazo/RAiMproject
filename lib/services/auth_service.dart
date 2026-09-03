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
import 'package:raim_prototype/services/raim_log.dart';

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
  bool _callbackInFlight = false;
  String? _lastHandledCallbackUri;

  /// 進行中のログイン処理。多重実行を防ぐために共有する。
  Future<AuthTokens?>? _loginInFlight;

  /// 進行中のトークン更新。同じ refresh token で二重に叩かないために共有する。
  Future<AuthTokens?>? _refreshInFlight;

  /// Cognito への HTTP 呼び出しのタイムアウト。
  ///
  /// 指定しないと、電波の悪い場所で起動したときに Splash が
  /// 無期限に固まる（既定のタイムアウトが無いため）。
  static const Duration _httpTimeout = Duration(seconds: 15);

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
        RaimLog.d('[AuthService] Deep Link listen error: $error');
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
  Future<AuthTokens?> startLogin() {
    // 再試行ボタンの連打や deep link との競合で複数のログインが並走すると、
    // 後から始まった試行が PKCE の state/verifier を上書きし、
    // 古い試行は 10 分後にタイムアウトして、成功済みの状態を error へ戻していた。
    // 進行中の試行があれば、その結果をそのまま返す。
    final inFlight = _loginInFlight;
    if (inFlight != null) {
      RaimLog.d('[AuthService] ログイン処理中のため既存の試行を待ちます');
      return inFlight;
    }

    final future = _startLoginInternal();
    _loginInFlight = future;
    return future.whenComplete(() {
      if (identical(_loginInFlight, future)) {
        _loginInFlight = null;
      }
    });
  }

  Future<AuthTokens?> _startLoginInternal() async {
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
      // 例外文は画面に表示されるため、URI（認可コード入り）を含めない
      throw Exception('RAiM用ではないcallbackを受け取りました。');
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

  /// 保存済みトークンを更新する。
  ///
  /// 起動時の [loadValidTokens] と、WebSocket 接続ごとの
  /// [getValidAccessToken] の両方から呼ばれる。並走すると同じ
  /// refresh token で 2 回叩くことになり、Cognito のローテーションが
  /// 有効なら片方が invalid_grant で弾かれて強制ログアウトになる。
  /// 進行中の更新があればそれを共有する。
  Future<AuthTokens?> refreshTokens(AuthTokens currentTokens) {
    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      RaimLog.d('[AuthService] トークン更新が進行中のため結果を共有します');
      return inFlight;
    }

    final future = _refreshTokensInternal(currentTokens);
    _refreshInFlight = future;
    return future.whenComplete(() {
      if (identical(_refreshInFlight, future)) {
        _refreshInFlight = null;
      }
    });
  }

  Future<AuthTokens?> _refreshTokensInternal(AuthTokens currentTokens) async {
    final refreshToken = currentTokens.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      await _storage.clearTokens();
      return null;
    }

    final tokenUri = Uri.parse('${RaimConfig.cognitoDomain}/oauth2/token');
    http.Response response;

    try {
      response = await http
          .post(
            tokenUri,
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: {
              'grant_type': 'refresh_token',
              'client_id': RaimConfig.clientId,
              'refresh_token': refreshToken,
            },
          )
          .timeout(_httpTimeout);
    } catch (e) {
      // 通信できないだけ。保存済みトークンは消さない。
      // 消すと、機内モードや電波の悪い場所で起動しただけで
      // 再ログインを強いられる。
      RaimLog.e('[AuthService] トークン更新の通信に失敗', e);
      return currentTokens.isExpired ? null : currentTokens;
    }

    if (response.statusCode != 200) {
      // refresh token が本当に無効になったときだけ消す。
      // 以前は 5xx や一時的な失敗でも消していたため、
      // サーバー側の一瞬の不調で強制ログアウトになっていた。
      final revoked = response.statusCode == 400 &&
          response.body.contains('invalid_grant');

      RaimLog.e(
        '[AuthService] トークン更新に失敗 status=${response.statusCode} '
        'revoked=$revoked',
      );

      if (revoked) {
        await _storage.clearTokens();
        return null;
      }
      return currentTokens.isExpired ? null : currentTokens;
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      RaimLog.e('[AuthService] トークン更新の応答が JSON ではない', e);
      return currentTokens.isExpired ? null : currentTokens;
    }

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
    // 端末からトークンを消すだけでは Cognito 側のセッションと
    // refresh token が生き続ける。revoke してから消す。
    final tokens = await _storage.readTokens();
    await _revokeRefreshToken(tokens?.refreshToken);

    await _browserLoginLauncher.closeLaunchedBrowser();
    // Windows の認証用 Chrome プロファイルにセッション Cookie が残るため、
    // 共用 PC で「ログアウトしたのに次の人が同じアカウントで入れる」状態を防ぐ。
    await _browserLoginLauncher.clearSavedSession();

    await _storage.clearPkceState();
    await _storage.clearTokens();
  }

  /// refresh token を Cognito 側で無効化する。
  ///
  /// 失敗してもログアウト自体は続行する。端末側の削除のほうが重要なため。
  Future<void> _revokeRefreshToken(String? refreshToken) async {
    if (refreshToken == null || refreshToken.isEmpty) return;

    try {
      final revokeUri = Uri.parse('${RaimConfig.cognitoDomain}/oauth2/revoke');
      final response = await http
          .post(
            revokeUri,
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: {
              'token': refreshToken,
              'client_id': RaimConfig.clientId,
            },
          )
          .timeout(_httpTimeout);

      RaimLog.d('[AuthService] revoke status=${response.statusCode}');
    } catch (e) {
      RaimLog.e('[AuthService] revoke に失敗（ログアウトは継続）', e);
    }
  }

  Future<void> _handleIncomingUri(Uri uri) async {
    final callback = _onCallback;
    if (callback == null) return;

    if (!_isExpectedCallbackUri(uri)) return;

    final callbackUri = uri.toString();
    if (_callbackInFlight || _lastHandledCallbackUri == callbackUri) {
      // URI には認可コードが含まれるためログに出さない
      RaimLog.d('[AuthService] 重複した callback を無視しました');
      return;
    }

    _callbackInFlight = true;
    try {
      // Token交換を待たず、callbackを受け取った時点で認証画面を閉じる。
      await _browserLoginLauncher.closeLaunchedBrowser();
      await callback(uri);
      _lastHandledCallbackUri = callbackUri;
    } finally {
      _callbackInFlight = false;
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
    final response = await http
        .post(
          tokenUri,
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'authorization_code',
            'client_id': RaimConfig.clientId,
            'code': code,
            'redirect_uri': _redirectUri,
            'code_verifier': codeVerifier,
          },
        )
        .timeout(_httpTimeout);

    if (response.statusCode != 200) {
      throw Exception('Token取得に失敗しました: ${response.statusCode}');
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Tokenレスポンスを解釈できませんでした。');
    }
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
