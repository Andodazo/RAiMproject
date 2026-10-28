import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Cognito Managed Login のパスキー登録結果です。
enum PasskeyRegistrationResult {
  registered,
  cancelled,
  noAuthenticator,
  redirectUriMismatch,
  networkError,
  failed,
}

extension PasskeyRegistrationResultMessage on PasskeyRegistrationResult {
  String get userMessage => switch (this) {
    PasskeyRegistrationResult.registered => 'パスキーの登録が完了しました',
    PasskeyRegistrationResult.cancelled => 'パスキーの登録をキャンセルしました。',
    PasskeyRegistrationResult.noAuthenticator =>
      'この端末では利用できる認証器がありません。端末の PIN・生体認証、またはスマートフォンを確認してください。',
    PasskeyRegistrationResult.redirectUriMismatch => '認証設定を確認してください。',
    PasskeyRegistrationResult.networkError => '通信に失敗しました。時間をおいて再試行してください。',
    PasskeyRegistrationResult.failed => 'パスキーを登録できませんでした。時間をおいて再試行してください。',
  };
}

/// Web callback でアプリが再起動しても、登録フローを識別するための状態です。
/// 認証情報や callback の値は保存しません。
class PasskeyRegistrationStateStorage {
  static const _storage = FlutterSecureStorage();
  static const _pendingKey = 'raim.passkey_registration.pending';
  static const _registeredKey = 'raim.passkey_registration.registered';

  Future<void> markPending() => _storage.write(key: _pendingKey, value: '1');

  Future<bool> isPending() async =>
      (await _storage.read(key: _pendingKey)) == '1';

  Future<void> clear() => _storage.delete(key: _pendingKey);

  Future<void> markRegistered() =>
      _storage.write(key: _registeredKey, value: '1');

  Future<bool> isRegistered() async =>
      (await _storage.read(key: _registeredKey)) == '1';

  Future<void> clearRegistered() => _storage.delete(key: _registeredKey);

  Future<void> clearAll() async {
    await clear();
    await clearRegistered();
  }
}
