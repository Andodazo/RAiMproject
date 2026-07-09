import 'package:url_launcher/url_launcher.dart';

/// Web / 非 dart:io 環境向けのブラウザ起動処理です。
class BrowserLoginLauncher {
  Future<bool> launch(Uri uri) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> closeLaunchedBrowser() async {}
}
