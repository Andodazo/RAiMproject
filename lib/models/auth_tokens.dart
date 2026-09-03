/// Cognito から受け取った Token 一式です。
///
/// `expiresAt` は Cognito が返す `expires_in` からクライアント側で計算します。
/// 起動時や WebSocket 接続前は、この時刻を見て Refresh が必要か判断します。
class AuthTokens {
  final String accessToken;
  final String? idToken;
  final String? refreshToken;
  final DateTime expiresAt;

  const AuthTokens({
    required this.accessToken,
    required this.expiresAt,
    this.idToken,
    this.refreshToken,
  });

  /// 有効期限ぎりぎりで使うと WebSocket 接続直後に期限切れになる可能性があるため、
  /// 余裕を持って期限切れ扱いにします。
  /// 実際に失効しているか。
  ///
  /// [isExpiringSoon] は「そろそろ更新したい」の判定なので、
  /// 更新に失敗しても失効前ならまだ使える。両者を区別するために足した。
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  bool get isExpiringSoon {
    return DateTime.now().isAfter(
      expiresAt.subtract(const Duration(minutes: 5)),
    );
  }

  AuthTokens copyWith({
    String? accessToken,
    String? idToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) {
    return AuthTokens(
      accessToken: accessToken ?? this.accessToken,
      idToken: idToken ?? this.idToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }
}
