import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/auth_tokens.dart';

/// 「そろそろ更新したい」と「本当に切れた」の区別を確かめる。
///
/// ここを混同すると、通信が一瞬失敗しただけで
/// 保存済みトークンを消して再ログインを強いることになる。
void main() {
  AuthTokens tokensExpiringIn(Duration duration) {
    return AuthTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      expiresAt: DateTime.now().add(duration),
    );
  }

  test('期限まで1時間あれば、更新も不要で失効もしていない', () {
    final tokens = tokensExpiringIn(const Duration(hours: 1));

    expect(tokens.isExpiringSoon, isFalse);
    expect(tokens.isExpired, isFalse);
  });

  test('期限まで1分なら、更新は要るがまだ使える', () {
    final tokens = tokensExpiringIn(const Duration(minutes: 1));

    expect(tokens.isExpiringSoon, isTrue);
    expect(tokens.isExpired, isFalse);
  });

  test('期限を過ぎていれば失効している', () {
    final tokens = tokensExpiringIn(const Duration(minutes: -1));

    expect(tokens.isExpiringSoon, isTrue);
    expect(tokens.isExpired, isTrue);
  });
}
