// パスキー登録まわりの不具合の確認
//
//   flutter test test/passkey_registration_test.dart

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:raim_prototype/models/auth_tokens.dart';
import 'package:raim_prototype/services/auth_service.dart';
import 'package:raim_prototype/services/browser_login_launcher.dart';
import 'package:raim_prototype/services/local_callback_server.dart';
import 'package:raim_prototype/services/passkey_registration.dart';
import 'package:raim_prototype/services/token_storage.dart';

class _MemoryTokenStorage implements TokenStorage {
  AuthTokens? tokens;

  @override
  Future<AuthTokens?> readTokens() async => tokens;

  @override
  Future<void> saveTokens(AuthTokens value) async {
    tokens = value;
  }

  @override
  Future<void> clearTokens() async {
    tokens = null;
  }

  @override
  Future<void> clearPkceState() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// パスキーの状態の保存領域の代わり。broken にすると保存領域が壊れた端末になる。
class _MemoryPasskeyState implements PasskeyRegistrationStateStorage {
  bool pending = false;
  bool registered = false;
  bool broken = false;

  void _check() {
    if (broken) throw StateError('secure storage が使えない');
  }

  @override
  Future<void> markPending() async {
    _check();
    pending = true;
  }

  @override
  Future<bool> isPending() async {
    _check();
    return pending;
  }

  @override
  Future<void> clear() async {
    _check();
    pending = false;
  }

  @override
  Future<void> markRegistered() async {
    _check();
    registered = true;
  }

  @override
  Future<bool> isRegistered() async {
    _check();
    return registered;
  }

  @override
  Future<void> clearRegistered() async {
    _check();
    registered = false;
  }

  @override
  Future<void> clearAll() async {
    await clear();
    await clearRegistered();
  }
}

class _FakeLauncher implements BrowserLoginLauncher {
  @override
  Future<bool> launch(Uri uri) async => true;

  @override
  Future<void> closeLaunchedBrowser() async {}
}

class _FakeCallbackServer implements LocalCallbackServer {
  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAppLinks implements AppLinks {
  final controller = StreamController<Uri>.broadcast();

  @override
  Stream<Uri> get uriLinkStream => controller.stream;

  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AuthTokens _tokens() => AuthTokens(
  accessToken: 'access',
  idToken: 'id',
  refreshToken: 'refresh',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryTokenStorage storage;
  late _MemoryPasskeyState passkeyState;
  late _FakeAppLinks appLinks;
  late AuthService auth;

  setUp(() {
    storage = _MemoryTokenStorage();
    passkeyState = _MemoryPasskeyState();
    appLinks = _FakeAppLinks();
    auth = AuthService(
      storage: storage,
      appLinks: appLinks,
      localCallbackServer: _FakeCallbackServer(),
      browserLoginLauncher: _FakeLauncher(),
      passkeyState: passkeyState,
    );
  });

  test('パスキーの状態を消せない端末でも、ログアウトでトークンが消える', () async {
    final client = MockClient((_) async => http.Response('', 200));
    await http.runWithClient(() async {
      storage.tokens = _tokens();
      passkeyState.broken = true;

      await auth.logout();

      expect(storage.tokens, isNull);
    }, () => client);
  });

  test('保存済みトークンの破棄も、パスキーの状態が消せなくてもトークンを消す', () async {
    storage.tokens = _tokens();
    passkeyState.broken = true;

    await auth.clearStoredTokens();

    expect(storage.tokens, isNull);
  });

  test('2回目のパスキー登録の callback も受け取る', () async {
    await auth.startListening(
      onCallback: (uri) async {
        await auth.handlePasskeyCallback(uri);
      },
    );

    for (var i = 0; i < 2; i++) {
      final result = auth.startPasskeyRegistration();
      await pumpEventQueue();
      appLinks.controller.add(Uri.parse('raim://callback'));

      expect(
        await result.timeout(const Duration(seconds: 1)),
        PasskeyRegistrationResult.registered,
        reason: '${i + 1}回目の登録の結果が出ない',
      );
    }
  });

  test('前の登録の pending が残っていても、ログインの callback は横取りしない', () async {
    passkeyState.pending = true;

    // ログインを断ったときの callback（code はないが state はある）
    final loginError = Uri.parse(
      'raim://callback?error=access_denied&state=abc',
    );
    expect(await auth.shouldHandlePasskeyCallback(loginError), isFalse);

    // パスキー登録の callback は今までどおり拾う
    expect(
      await auth.shouldHandlePasskeyCallback(Uri.parse('raim://callback')),
      isTrue,
    );
  });
}
