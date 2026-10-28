// 修正: 競合を解消し、更新済みの通常認証の世代管理・破棄処理を保持した。
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:http/http.dart' as http;
import 'package:raim_prototype/services/aws/cognito_credentials_provider.dart';
import 'package:raim_prototype/config/raim_config.dart';
import 'package:raim_prototype/models/auth_tokens.dart';
import 'package:raim_prototype/services/browser_login_launcher.dart';
import 'package:raim_prototype/services/local_callback_server.dart';
import 'package:raim_prototype/services/passkey_registration.dart';
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
  final PasskeyRegistrationStateStorage _passkeyState;

  StreamSubscription<Uri>? _linkSubscription;
  Future<void> Function(Uri uri)? _onCallback;
  bool _callbackInFlight = false;
  String? _lastHandledCallbackUri;

  /// 進行中のログイン処理。多重実行を防ぐために共有する。
  Future<AuthTokens?>? _loginInFlight;

  /// 進行中のパスキー登録。登録ページから戻るまで同じ Future を共有する。
  Future<PasskeyRegistrationResult>? _passkeyInFlight;
  Completer<PasskeyRegistrationResult>? _passkeyCallbackCompleter;

  /// 進行中のトークン更新。同じ refresh token で二重に叩かないために共有する。
  Future<AuthTokens?>? _refreshInFlight;

  // 【追加】古い更新を無効にするための認証世代。
  int _authGeneration = 0;
  // revoke待ちの間も、更新やログイン確定を止める。
  bool _signingOut = false;
  // 同時にログアウトされた場合、同じ処理を待たせる。
  Future<void>? _logoutInFlight;
  // 保存と削除が交互に実行されないようにする順番待ち。
  Future<void> _tokenStorageTail = Future<void>.value();

  /// Cognito への HTTP 呼び出しのタイムアウト。
  ///
  /// 指定しないと、電波の悪い場所で起動したときに Splash が
  /// 無期限に固まる（既定のタイムアウトが無いため）。
  static const Duration _httpTimeout = Duration(seconds: 15);

  /// パスキー登録ページから戻るのを待つ時間。
  // 修正: 以前は10分待っていた。ブラウザを閉じただけでも10分間「登録中」のままに
  // なり、Windows では小窓も消えたままだったので5分に縮めた。
  static const Duration _passkeyTimeout = Duration(minutes: 5);

  /// アプリに戻ってから、callback が届くのを待つ時間。
  static const Duration _passkeyResumeGrace = Duration(seconds: 3);

  AuthService({
    TokenStorage? storage,
    AppLinks? appLinks,
    LocalCallbackServer? localCallbackServer,
    BrowserLoginLauncher? browserLoginLauncher,
    PasskeyRegistrationStateStorage? passkeyState,
  }) : _storage = storage ?? TokenStorage(),
       _appLinks = appLinks ?? AppLinks(),
       _localCallbackServer = localCallbackServer ?? LocalCallbackServer(),
       _browserLoginLauncher = browserLoginLauncher ?? BrowserLoginLauncher(),
       _passkeyState = passkeyState ?? PasskeyRegistrationStateStorage();

  // 【追加】開始時と現在が同じ認証状態かを確認する。
  bool _isCurrentAuth(int generation) =>
      !_signingOut && generation == _authGeneration;

  // 【追加】トークン操作を、前の操作の完了後に実行する。
  Future<T> _withTokenStorage<T>(Future<T> Function() operation) {
    final result = _tokenStorageTail.then((_) => operation());

    // 操作のエラーは呼び出し元へ返すが、次の操作は止めない。
    _tokenStorageTail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  // 【追加】古い更新の失敗で、次の人のトークンを消さない。
  Future<void> _clearTokensForGeneration(int generation) {
    return _withTokenStorage(() async {
      if (!_isCurrentAuth(generation)) return;
      await _storage.clearTokens();
    });
  }

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

  /// 保存済みTokenを読み、必要なら更新する。
  Future<AuthTokens?> loadValidTokens() async {
    // 【追加】保存領域を読む前に、この認証の世代を記録する。
    final generation = _authGeneration;
    if (!_isCurrentAuth(generation)) return null;

    // 【変更】保存途中の値を読まないよう、同じ順番待ちに通す。
    final tokens = await _withTokenStorage(_storage.readTokens);
    if (!_isCurrentAuth(generation) || tokens == null) return null;

    final result = tokens.isExpiringSoon ? await refreshTokens(tokens) : tokens;

    // 【追加】更新待ちの間にログアウトされた場合も返さない。
    return _isCurrentAuth(generation) ? result : null;
  }

  /// 保存済みの認証情報を明示的に破棄する。
  Future<void> clearStoredTokens() {
    // 【追加】進行中の更新も無効にし、削除を直列化する。
    _authGeneration++;
    _refreshInFlight = null;
    // 修正: 以前はパスキーの状態を先に消していた。端末の保存領域でそこが失敗すると
    // トークンが消えずに残り、ログアウトにならなかったので、トークンを先に消す。
    return _withTokenStorage(() async {
      await _storage.clearTokens();
      await _clearPasskeyStateQuietly();
    });
  }

  /// パスキーの表示用の状態を消す。失敗してもログアウトは止めない。
  Future<void> _clearPasskeyStateQuietly() async {
    try {
      await _passkeyState.clearAll();
    } catch (e) {
      RaimLog.d('[Passkey] 登録状態を消せませんでした: ${e.runtimeType}');
    }
  }

  /// 現在のユーザーに登録済みのパスキーがあるか確認します。
  ///
  /// Cognito の一覧 API が一時的に利用できない場合は、直近にこのアプリで
  /// 登録成功を確認した状態へフォールバックします。トークンや API 応答の
  /// 内容はログへ出力しません。
  Future<bool> hasRegisteredPasskey() async {
    final locallyKnown = await _passkeyState.isRegistered();
    final accessToken = await getValidAccessToken();
    if (accessToken == null || accessToken.isEmpty) return locallyKnown;

    try {
      String? nextToken;
      do {
        final response = await http
            .post(
              Uri.parse(
                'https://cognito-idp.${RaimConfig.cognitoRegion}.amazonaws.com/',
              ),
              headers: {
                'Content-Type': 'application/x-amz-json-1.1',
                'X-Amz-Target':
                    'AWSCognitoIdentityProviderService.ListWebAuthnCredentials',
              },
              body: jsonEncode({
                'AccessToken': accessToken,
                'MaxResults': 20,
                ...?nextToken == null ? null : {'NextToken': nextToken},
              }),
            )
            .timeout(_httpTimeout);

        if (response.statusCode != 200) return locallyKnown;

        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final credentials = body['Credentials'];
        if (credentials is List && credentials.isNotEmpty) {
          await _passkeyState.markRegistered();
          return true;
        }
        nextToken = body['NextToken'] as String?;
      } while (nextToken != null && nextToken.isNotEmpty);

      await _passkeyState.clearRegistered();
      return false;
    } catch (e) {
      RaimLog.d('[Passkey] 登録状態の確認に失敗しました: ${e.runtimeType}');
      return locallyKnown;
    }
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
      },
    );
  }

  /// Cognito Managed Login のパスキー登録 URL を作ります。
  ///
  /// WebAuthn の処理は Cognito と OS の認証器に委譲し、アプリでは URL の
  /// 作成と登録後の callback の受け取りだけを行います。
  Uri createPasskeyRegistrationUri() {
    return Uri.parse(RaimConfig.cognitoDomain).replace(
      path: '/passkeys/add',
      queryParameters: {
        'client_id': RaimConfig.clientId,
        'redirect_uri': _redirectUri,
      },
    );
  }

  bool get isPasskeyRegistrationPending =>
      _passkeyCallbackCompleter != null &&
      !_passkeyCallbackCompleter!.isCompleted;

  /// アプリ再起動後の Web callback も、通常ログインの code と区別します。
  /// 通常ログインの成功には必ず code があり、パスキー登録の成功 callback
  /// には code がありません。
  Future<bool> shouldHandlePasskeyCallback(Uri uri) async {
    if (!_isExpectedCallbackUri(uri)) return false;
    if (isPasskeyRegistrationPending) return true;
    // 修正: 以前は code だけを見ていた。登録中にアプリが落ちて pending が残ると、
    // 後のログインのエラー callback（code なし）までパスキー登録として扱っていた。
    // ログインの callback には成功でも失敗でも state が付くので、それも除く。
    if (uri.queryParameters.containsKey('code') ||
        uri.queryParameters.containsKey('state')) {
      return false;
    }
    return _passkeyState.isPending();
  }

  /// ログイン済みの Managed Login セッションでパスキー登録を開始します。
  Future<PasskeyRegistrationResult> startPasskeyRegistration() {
    final inFlight = _passkeyInFlight;
    if (inFlight != null) return inFlight;

    final future = _startPasskeyRegistrationInternal();
    _passkeyInFlight = future;
    return future.whenComplete(() {
      if (identical(_passkeyInFlight, future)) {
        _passkeyInFlight = null;
      }
    });
  }

  Future<PasskeyRegistrationResult> _startPasskeyRegistrationInternal() async {
    final callbackCompleter = Completer<PasskeyRegistrationResult>();
    _passkeyCallbackCompleter = callbackCompleter;
    await _passkeyState.markPending();

    Future<Uri>? loopbackCallback;
    if (_usesLoopbackRedirect) {
      loopbackCallback = _localCallbackServer.waitForCallback(
        timeout: _passkeyTimeout,
      );
    }

    final bool launched;
    try {
      launched = await _browserLoginLauncher.launch(
        createPasskeyRegistrationUri(),
      );
    } catch (e) {
      RaimLog.e('[Passkey] 登録ページを開けませんでした', e.runtimeType);
      await _localCallbackServer.close();
      await _passkeyState.clear();
      _passkeyCallbackCompleter = null;
      return PasskeyRegistrationResult.failed;
    }
    if (!launched) {
      await _localCallbackServer.close();
      await _passkeyState.clear();
      _passkeyCallbackCompleter = null;
      return PasskeyRegistrationResult.failed;
    }

    // 修正: 以前は登録ページを閉じてアプリに戻っても callback が来ないため、
    // 10分のタイムアウトまで結果が出なかった。Android/iOS では、アプリに戻って
    // 少し待っても callback が来なければキャンセルとして扱う。
    AppLifecycleListener? lifecycle;
    if (!kIsWeb && !_usesLoopbackRedirect) {
      lifecycle = AppLifecycleListener(
        onResume: () {
          Future<void>.delayed(_passkeyResumeGrace, () {
            if (!callbackCompleter.isCompleted) {
              callbackCompleter.complete(PasskeyRegistrationResult.cancelled);
            }
          });
        },
      );
    }

    try {
      if (loopbackCallback != null) {
        final Uri callbackUri;
        try {
          callbackUri = await loopbackCallback;
        } on TimeoutException {
          // 修正: 以前はタイムアウトが例外のまま上がり「登録できませんでした」と
          // 出ていた。ブラウザを閉じただけなのでキャンセルとして扱う。
          return PasskeyRegistrationResult.cancelled;
        }
        return await handlePasskeyCallback(callbackUri);
      }

      return await callbackCompleter.future.timeout(
        _passkeyTimeout,
        onTimeout: () => PasskeyRegistrationResult.cancelled,
      );
    } finally {
      lifecycle?.dispose();
      await _passkeyState.clear();
      _passkeyCallbackCompleter = null;
      await _browserLoginLauncher.closeLaunchedBrowser();
    }
  }

  /// パスキー登録ページから戻った callback を処理します。
  ///
  /// callback に含まれる値は分類にだけ使い、ログや画面には出しません。
  Future<PasskeyRegistrationResult> handlePasskeyCallback(Uri uri) async {
    if (!_isExpectedCallbackUri(uri)) {
      return PasskeyRegistrationResult.failed;
    }

    final result = _classifyPasskeyCallback(uri);
    if (result == PasskeyRegistrationResult.registered) {
      await _passkeyState.markRegistered();
    }
    await _passkeyState.clear();
    final completer = _passkeyCallbackCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
    await _browserLoginLauncher.closeLaunchedBrowser();
    return result;
  }

  PasskeyRegistrationResult _classifyPasskeyCallback(Uri uri) {
    final error = uri.queryParameters['error']?.toLowerCase() ?? '';
    // Cognito の正常な登録完了 callback では error が返りません。
    // error_description だけが付いている場合も成功として扱います。
    // エラーの詳細文字列は仕様上固定されていないため、error が無い
    // callback を詳細文だけで失敗扱いにしないようにします。
    if (error.isEmpty) return PasskeyRegistrationResult.registered;

    final description =
        uri.queryParameters['error_description']?.toLowerCase() ?? '';
    final reason = '$error $description';

    if (reason.contains('redirect')) {
      return PasskeyRegistrationResult.redirectUriMismatch;
    }
    if (RegExp(
      r'not[_ -]supported|no[_ -]authenticator|no[_ -]credential',
    ).hasMatch(reason)) {
      return PasskeyRegistrationResult.noAuthenticator;
    }
    if (RegExp(r'cancel|denied|abort|notallowed').hasMatch(reason)) {
      return PasskeyRegistrationResult.cancelled;
    }
    if (RegExp(r'network|timeout|temporar|unavailable').hasMatch(reason)) {
      return PasskeyRegistrationResult.networkError;
    }
    return PasskeyRegistrationResult.failed;
  }

  /// Cognito Managed Login を通常の外部ブラウザで開きます。
  ///
  /// Google OAuth は埋め込み WebView で完走できないことがあるため、Windows では
  /// `http://localhost:3000/callback` を一時HTTPサーバーで待ち受けてから、
  /// Windowsを含むすべてのプラットフォームで、ユーザーの通常ブラウザを開きます。
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
      return await handleCallback(callbackUri);
    } finally {
      await _browserLoginLauncher.closeLaunchedBrowser();
    }
  }

  /// Cognito から戻ってきた callback URL を処理します。
  Future<AuthTokens> handleCallback(Uri uri) async {
    // 【追加】開始時の認証世代を覚える。ログイン確定時に更新する。
    var generation = _authGeneration;
    if (!_isCurrentAuth(generation)) {
      throw StateError('ログアウト処理中です。');
    }

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

    late final AuthTokens tokens;

    try {
      // 【追加】stateなどの読み込み待ちでログアウトされた場合も止める。
      if (!_isCurrentAuth(generation)) {
        throw StateError('ログイン処理は取り消されました。');
      }

      tokens = await _exchangeCodeForTokens(
        code: code,
        codeVerifier: codeVerifier,
      );

      // 【追加】交換待ちの間にログアウトされたら、保存しない。
      if (!_isCurrentAuth(generation)) {
        throw StateError('ログイン処理は取り消されました。');
      }

      // 【追加】新しいログインを確定する前に、古い更新を無効にする。
      generation = ++_authGeneration;
      _refreshInFlight = null;

      // 【変更】更新の保存やログアウトによる削除と、順番に実行する。
      await _withTokenStorage(() async {
        if (!_isCurrentAuth(generation)) return;
        await _storage.saveTokens(tokens);
      });
    } finally {
      // 【変更】古いログイン処理で、次のログインのPKCE情報を消さない。
      await _withTokenStorage(() async {
        if (!_isCurrentAuth(generation)) return;
        await _storage.clearPkceState();
      });
    }

    // 【追加】保存・後片付けの待機中にログアウトされた場合も返さない。
    if (!_isCurrentAuth(generation)) {
      throw StateError('ログイン処理は取り消されました。');
    }
    return tokens;
  }

  /// 保存済みトークンを更新する。
  ///
  /// 起動時の [loadValidTokens] と、WebSocket 接続ごとの
  /// [getValidAccessToken] の両方から呼ばれる。並走すると同じ
  /// refresh token で 2 回叩くことになり、Cognito のローテーションが
  /// 有効なら片方が invalid_grant で弾かれて強制ログアウトになる。
  /// 進行中の更新があればそれを共有する。
  Future<AuthTokens?> refreshTokens(AuthTokens currentTokens) {
    // 【追加】ログアウト開始後は、revoke待ちでも更新を開始しない。
    if (_signingOut) return Future<AuthTokens?>.value(null);
    final generation = _authGeneration;

    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      RaimLog.d('[AuthService] トークン更新が進行中のため結果を共有します');
      return inFlight;
    }

    // 【変更】この更新が属する認証世代を、内部処理へ渡す。
    final future = _refreshTokensInternal(
      currentTokens,
      generation,
    ).then((tokens) => _isCurrentAuth(generation) ? tokens : null);
    _refreshInFlight = future;
    return future.whenComplete(() {
      if (identical(_refreshInFlight, future)) {
        _refreshInFlight = null;
      }
    });
  }

  Future<AuthTokens?> _refreshTokensInternal(
    AuthTokens currentTokens,
    int generation, // 【追加】更新開始時の認証世代。
  ) async {
    final refreshToken = currentTokens.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      // 【変更】現在の認証状態の更新だけが削除できる。
      await _clearTokensForGeneration(generation);
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
      // 【追加】通信失敗時にも、前の人のトークンを返さない。
      if (!_isCurrentAuth(generation)) return null;

      // 通信できないだけ。保存済みトークンは消さない。
      // 消すと、機内モードや電波の悪い場所で起動しただけで
      // 再ログインを強いられる。
      RaimLog.e('[AuthService] トークン更新の通信に失敗', e);
      return currentTokens.isExpired ? null : currentTokens;
    }

    // 【追加】通信待ちの間に認証状態が変わったら、返事を使わない。
    if (!_isCurrentAuth(generation)) return null;

    if (response.statusCode != 200) {
      // refresh token が本当に無効になったときだけ消す。
      // 以前は 5xx や一時的な失敗でも消していたため、
      // サーバー側の一瞬の不調で強制ログアウトになっていた。
      final revoked =
          response.statusCode == 400 && response.body.contains('invalid_grant');

      RaimLog.e(
        '[AuthService] トークン更新に失敗 status=${response.statusCode} '
        'revoked=$revoked',
      );

      if (revoked) {
        // 【変更】現在の認証状態の更新だけが削除できる。
        await _clearTokensForGeneration(generation);
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
    // 【変更】保存とログアウトの削除が交互に進まないよう直列化する。
    await _withTokenStorage(() async {
      // 順番待ち中にも認証状態は変わり得るので、保存直前に確認する。
      if (!_isCurrentAuth(generation)) return;
      await _storage.saveTokens(refreshedTokens);
    });

    // 【追加】保存の待機中にログアウトされた場合も返さない。
    return _isCurrentAuth(generation) ? refreshedTokens : null;
  }

  Future<String?> getValidAccessToken() async {
    final tokens = await loadValidTokens();
    return tokens?.accessToken;
  }

  /// Identity Pool連携に使う、期限確認済みのUser Pool ID Tokenを返す。
  Future<String?> getValidIdToken() async {
    final tokens = await loadValidTokens();
    return tokens?.idToken;
  }

  Future<void> logout() {
    // 【追加】同時に呼ばれたログアウトは、同じ処理の完了を待つ。
    final inFlight = _logoutInFlight;
    if (inFlight != null) return inFlight;

    // 【追加】最初のawaitより前に、すべての古い更新を無効にする。
    _signingOut = true;
    _authGeneration++;
    _refreshInFlight = null;

    final future = _logoutInternal().whenComplete(() {
      _signingOut = false;
      _logoutInFlight = null;
    });
    _logoutInFlight = future;
    return future;
  }

  // 【追加】認証状態を無効にした後の、ログアウトの後片付け。
  Future<void> _logoutInternal() async {
    final previousTokens = await _withTokenStorage(() async {
      // revoke用に、消す前のトークンを取得しておく。
      final tokens = await _storage.readTokens();

      // 【変更】ネットワークを待つ前に、端末側の認証情報を消す。
      await _storage.clearPkceState();
      await _storage.clearTokens();
      // 修正: 以前はここで例外が出ると revoke まで進まなかった。
      await _clearPasskeyStateQuietly();
      return tokens;
    });

    CognitoCredentialsProvider.instance.clear();

    // 削除前に取得した値を使うので、端末から消した後もrevokeできる。
    await _revokeRefreshToken(previousTokens?.refreshToken);
    await _browserLoginLauncher.closeLaunchedBrowser();
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
            body: {'token': refreshToken, 'client_id': RaimConfig.clientId},
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
      // 修正: 以前はどの callback も覚えていた。パスキー登録の callback は毎回
      // 同じ `raim://callback` なので、2回目の登録の callback が「重複」として
      // 捨てられ、結果が出なかった。重複を防ぎたいのは認可コードなので、
      // code が付いたものだけ覚える。
      if (uri.queryParameters.containsKey('code')) {
        _lastHandledCallbackUri = callbackUri;
      }
    } finally {
      _callbackInFlight = false;
    }
  }

  bool get _usesLoopbackRedirect =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  String get _redirectUri => (_usesLoopbackRedirect || kIsWeb)
      ? RaimConfig.webRedirectUri
      : RaimConfig.redirectUri;

  bool _isExpectedCallbackUri(Uri uri) {
    final expected = Uri.tryParse(_redirectUri);
    if (expected == null || expected.scheme.isEmpty || expected.host.isEmpty) {
      return false;
    }

    return uri.scheme == expected.scheme &&
        uri.host == expected.host &&
        uri.port == expected.port &&
        uri.path == expected.path;
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
