import 'package:url_launcher/url_launcher.dart';

/// Cognito認証用ブラウザを起動するサービス。
///
/// 認証URLは専用のChromeプロファイルやキオスクウィンドウを作らず、
/// すべてのプラットフォームでOSの通常ブラウザへ渡します。
class BrowserLoginLauncher {
  /// OSの通常ブラウザを開きます。
  ///
  /// WindowsでChromeが既定のブラウザなら通常のChromeプロファイルが使われ、
  /// Androidでもアプリ内の認証画面ではなく、ユーザーが選んだ外部ブラウザが
  /// 開きます。iOS・macOS・Linux・Webも同じ経路です。
  Future<bool> launch(Uri uri) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 認証専用ブラウザを起動しないため、終了対象はありません。
  Future<void> closeLaunchedBrowser() => Future<void>.value();
}
