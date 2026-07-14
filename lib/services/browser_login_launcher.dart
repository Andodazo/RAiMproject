import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Cognito認証用ブラウザを起動するサービス。
///
/// Webクライアントは対象外のため、ネイティブ環境向けの実装をこの
/// ファイルに集約しています。WindowsではChromeをkioskモードで起動し、
/// AndroidではCustom Tabs、iOSでは外部ブラウザへ認証URLを渡します。
class BrowserLoginLauncher {
  Process? _launchedProcess;

  Future<bool> launch(Uri uri) async {
    if (!kIsWeb && Platform.isWindows) {
      final chromePath = _findChromePath();
      if (chromePath != null) {
        final userDataDir = _prepareChromeUserDataDir();
        _launchedProcess = await Process.start(
          chromePath,
          [
            '--kiosk',
            uri.toString(),
            '--user-data-dir=$userDataDir',
            '--lang=ja-JP',
            '--accept-lang=ja-JP,ja',
            '--no-first-run',
            '--disable-translate',
            '--disable-features=Translate',
          ],
          mode: ProcessStartMode.detachedWithStdio,
        );
        return true;
      }
    }

    if (!kIsWeb && Platform.isIOS) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }

    if (!kIsWeb && Platform.isAndroid) {
      // AndroidのCustom Tabsを使用する。認証完了時はraim://callbackで戻る。
      return launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }

    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> closeLaunchedBrowser() async {
    final process = _launchedProcess;
    _launchedProcess = null;
    process?.kill();
  }

  String? _findChromePath() {
    const candidates = <String>[
      r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    ];

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    return null;
  }

  String _prepareChromeUserDataDir() {
    final baseDir =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    final profileDir = Directory('$baseDir\\RAiM\\auth_chrome_profile');
    if (!profileDir.existsSync()) {
      profileDir.createSync(recursive: true);
    }
    return profileDir.path;
  }
}
