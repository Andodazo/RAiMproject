import 'dart:async';

/// Web / 非 dart:io 環境向けのダミー実装です。
///
/// Windows デスクトップでは `local_callback_server_io.dart` が使われます。
/// Web など `dart:io` が使えない環境ではローカルHTTPサーバーを立てられないため、
/// 呼ばれた場合は明示的に失敗させます。
class LocalCallbackServer {
  Future<Uri> waitForCallback({Duration? timeout}) {
    throw UnsupportedError('この環境ではローカルcallbackサーバーを起動できません。');
  }

  Future<void> close() async {}
}
