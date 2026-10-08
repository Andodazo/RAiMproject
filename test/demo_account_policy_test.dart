import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/auth_tokens.dart';
import 'package:raim_prototype/services/demo_account_policy.dart';

String jwtWithClaims(Map<String, dynamic> claims) {
  String part(Object value) => base64Url
      .encode(utf8.encode(jsonEncode(value)))
      .replaceAll('=', '');

  return '${part({'alg': 'none'})}.${part(claims)}.signature';
}

AuthTokens tokens({String? idToken, String? accessToken}) => AuthTokens(
      accessToken: accessToken ?? 'not-a-jwt',
      idToken: idToken,
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );

void main() {
  const policy = DemoAccountPolicy(group: 'raim-demo');

  test('ID tokenのraim-demoグループだけを展示アカウントとして許可する', () {
    final idToken = jwtWithClaims({
      'cognito:groups': ['raim-demo', 'other-group'],
    });

    expect(policy.isDemoAccount(tokens(idToken: idToken)), isTrue);
  });

  test('別グループ・壊れたJWT・期限切れは許可しない', () {
    expect(
      policy.isDemoAccount(
        tokens(idToken: jwtWithClaims({'cognito:groups': ['other-group']})),
      ),
      isFalse,
    );
    expect(policy.isDemoAccount(tokens(idToken: 'broken')), isFalse);
    expect(
      policy.isDemoAccount(
        AuthTokens(
          accessToken: 'not-a-jwt',
          idToken: jwtWithClaims({'cognito:groups': ['raim-demo']}),
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
      ),
      isFalse,
    );
  });

  test('groups文字列形式にも対応する', () {
    final accessToken = jwtWithClaims({'groups': 'other-group raim-demo'});
    expect(policy.isDemoAccount(tokens(accessToken: accessToken)), isTrue);
  });
}
