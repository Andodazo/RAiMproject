// 課題2: トークンの更新中にログアウトすると、前の人のトークンが保存し直される
//
//   flutter test test/review/item2_token_logout_test.dart
//
// Cognito への通信は MockClient で止めておき、好きな順番で返事を返す。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:raim_prototype/models/auth_tokens.dart';
import 'package:raim_prototype/services/auth_service.dart';
import 'package:raim_prototype/services/browser_login_launcher.dart';
import 'package:raim_prototype/services/local_callback_server.dart';
import 'package:raim_prototype/services/token_storage.dart';

import 'support/fakes.dart' show settle;

/// 端末の保存領域の代わり
class MemoryTokenStorage implements TokenStorage {
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

class _FakeLauncher implements BrowserLoginLauncher {
  @override
  Future<void> closeLaunchedBrowser() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCallbackServer implements LocalCallbackServer {
  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 期限が近い（更新が要る）トークン
AuthTokens expiringTokens(String who) => AuthTokens(
      accessToken: 'access-$who',
      idToken: 'id-$who',
      refreshToken: 'refresh-$who',
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    );

http.Response tokenResponse(String who) => http.Response(
      jsonEncode({
        'access_token': 'access-$who',
        'id_token': 'id-$who',
        'expires_in': 3600,
      }),
      200,
    );

void main() {
  late MemoryTokenStorage storage;
  late AuthService auth;

  /// 届いた /oauth2/token と /oauth2/revoke に、どう返すか
  late Future<http.Response> Function() onToken;
  late Future<http.Response> Function() onRevoke;

  setUp(() {
    storage = MemoryTokenStorage();
    auth = AuthService(
      storage: storage,
      localCallbackServer: _FakeCallbackServer(),
      browserLoginLauncher: _FakeLauncher(),
    );
    onToken = () async => http.Response('{}', 500);
    onRevoke = () async => http.Response('', 200);
  });

  Future<void> withCognito(Future<void> Function() body) {
    final client = MockClient((request) {
      if (request.url.path.endsWith('/oauth2/token')) return onToken();
      if (request.url.path.endsWith('/oauth2/revoke')) return onRevoke();
      return Future.value(http.Response('', 404));
    });
    return http.runWithClient(body, () => client);
  }

  test('更新の返事がログアウトの後に届いても、そのトークンを保存しない', () async {
    await withCognito(() async {
      final refreshReply = Completer<http.Response>();
      onToken = () => refreshReply.future;
      storage.tokens = expiringTokens('A');

      // A のトークンの更新が始まる（Cognito の返事待ち）
      final pending = auth.getValidAccessToken();
      await settle();

      // 返事を待っている間にログアウト
      await auth.logout();
      expect(storage.tokens, isNull, reason: 'ログアウトしたのにトークンが残っている');

      // ログアウトの後に、更新の返事が届く
      refreshReply.complete(tokenResponse('A-new'));
      final token = await pending;

      expect(storage.tokens, isNull, reason: 'ログアウトの後に前の人のトークンが保存し直された');
      expect(token, isNot('access-A-new'), reason: 'ログアウトの後に前の人のトークンを返した');
    });
  });

  test('ログアウトの revoke を待っている間に更新が始まっても、トークンが戻らない', () async {
    await withCognito(() async {
      final revokeReply = Completer<http.Response>();
      final refreshReply = Completer<http.Response>();
      onRevoke = () => revokeReply.future;
      onToken = () => refreshReply.future;
      storage.tokens = expiringTokens('A');

      // ログアウトが Cognito の revoke の返事を待っている間に…
      final loggingOut = auth.logout();
      await settle();

      // 別の画面がトークンを取りに来る
      final pending = auth.getValidAccessToken();
      await settle();

      revokeReply.complete(http.Response('', 200));
      await loggingOut;

      // ログアウトが終わってから、更新の返事が届く
      refreshReply.complete(tokenResponse('A-new'));
      await pending;

      expect(storage.tokens, isNull, reason: 'ログアウトの後に前の人のトークンが保存し直された');
    });
  });

  test('前の人の更新が断られても、次の人のトークンを消さない', () async {
    await withCognito(() async {
      final refreshReply = Completer<http.Response>();
      onToken = () => refreshReply.future;
      storage.tokens = expiringTokens('A');

      // A の更新が始まる
      final pending = auth.getValidAccessToken();
      await settle();

      // A がログアウトし、B がログインした
      await auth.logout();
      final tokensOfB = AuthTokens(
        accessToken: 'access-B',
        refreshToken: 'refresh-B',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
      storage.tokens = tokensOfB;

      // A の更新は revoke 済みなので断られる
      refreshReply.complete(http.Response('{"error":"invalid_grant"}', 400));
      await pending;

      expect(storage.tokens?.accessToken, 'access-B', reason: '前の人の更新の失敗で、次の人のトークンが消えた');
    });
  });
}
