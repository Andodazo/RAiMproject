import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Cognito / Google 認証用ブラウザを起動するサービスです。
///
/// Windows 検証ではアプリ本体と同じく没入感を出すため、Google Chrome を
/// kiosk モードで起動します。通常の `url_launcher` だと既定ブラウザに任せるだけで、
/// 枠なしフルスクリーンや終了制御ができないためです。
class BrowserLoginLauncher {
  Process? _launchedProcess;

  Future<bool> launch(Uri uri) async {
    if (!kIsWeb && Platform.isWindows) {
      final chromePath = _findChromePath();
      if (chromePath != null) {
        final userDataDir = _prepareChromeUserDataDir();
        _launchedProcess = await Process.start(chromePath, [
          '--kiosk',
          uri.toString(),
          '--user-data-dir=$userDataDir',
          '--lang=ja-JP',
          '--accept-lang=ja-JP,ja',
          '--no-first-run',
          '--disable-translate',
          '--disable-features=Translate',
        ], mode: ProcessStartMode.detachedWithStdio);
        return true;
      }
    }

    if (!kIsWeb && Platform.isAndroid) {
      // Android で通常の外部ブラウザとして開くと、認証後の `raim://callback`
      // 遷移タブが Chrome 側にローディング状態で残ることがあります。
      // Custom Tabs 相当の inAppBrowserView を使うと、Google OAuth の外部ユーザー
      // エージェント要件を満たしつつ、通常タブとして残りにくくなります。
      return launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }

    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> closeLaunchedBrowser() async {
    final process = _launchedProcess;
    _launchedProcess = null;

    if (process != null) {
      process.kill();
    }
  }

  String? _findChromePath() {
    final candidates = <String>[
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
