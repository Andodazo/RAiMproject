import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:raim_prototype/models/auth_tokens.dart';

/// Cognito Token を OS の安全な保存領域へ読み書きするクラスです。
///
/// Access Token / Refresh Token は通常の SharedPreferences や平文ファイルではなく、
/// Android Keystore、iOS Keychain、Windows の資格情報保管領域などを使う
/// `flutter_secure_storage` に保存します。
class TokenStorage {
  static const _storage = FlutterSecureStorage();

  static const _accessTokenKey = 'raim.access_token';
  static const _idTokenKey = 'raim.id_token';
  static const _refreshTokenKey = 'raim.refresh_token';
  static const _expiresAtKey = 'raim.expires_at';

  static const _pkceVerifierKey = 'raim.pkce.code_verifier';
  static const _pkceStateKey = 'raim.pkce.state';

  Future<AuthTokens?> readTokens() async {
    final accessToken = await _storage.read(key: _accessTokenKey);
    final expiresAtText = await _storage.read(key: _expiresAtKey);

    if (accessToken == null || expiresAtText == null) {
      return null;
    }

    final expiresAt = DateTime.tryParse(expiresAtText);
    if (expiresAt == null) {
      await clearTokens();
      return null;
    }

    return AuthTokens(
      accessToken: accessToken,
      idToken: await _storage.read(key: _idTokenKey),
      refreshToken: await _storage.read(key: _refreshTokenKey),
      expiresAt: expiresAt,
    );
  }

  Future<void> saveTokens(AuthTokens tokens) async {
    await _storage.write(key: _accessTokenKey, value: tokens.accessToken);
    await _storage.write(
      key: _expiresAtKey,
      value: tokens.expiresAt.toIso8601String(),
    );

    if (tokens.idToken != null) {
      await _storage.write(key: _idTokenKey, value: tokens.idToken);
    }

    // Refresh Token は refresh 結果に含まれないことがあります。
    // null で既存値を上書きしないように、値がある場合だけ保存します。
    if (tokens.refreshToken != null && tokens.refreshToken!.isNotEmpty) {
      await _storage.write(key: _refreshTokenKey, value: tokens.refreshToken);
    }
  }

  Future<void> clearTokens() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _idTokenKey);
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _expiresAtKey);
  }

  Future<void> savePkceState({
    required String codeVerifier,
    required String state,
  }) async {
    await _storage.write(key: _pkceVerifierKey, value: codeVerifier);
    await _storage.write(key: _pkceStateKey, value: state);
  }

  Future<String?> readCodeVerifier() {
    return _storage.read(key: _pkceVerifierKey);
  }

  Future<String?> readState() {
    return _storage.read(key: _pkceStateKey);
  }

  Future<void> clearPkceState() async {
    await _storage.delete(key: _pkceVerifierKey);
    await _storage.delete(key: _pkceStateKey);
  }
}
