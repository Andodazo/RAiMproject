import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Cognito認証用ブラウザを起動するサービス。
///
/// Webクライアントは対象外のため、ネイティブ環境向けの実装をこの
/// ファイルに集約しています。WindowsではChromeをkioskモードで起動し、
/// Android/iOSではOSまたはアプリ内ブラウザへ認証URLを渡します。
class BrowserLoginLauncher {
  static const _iosBrowserChannel = MethodChannel('raim_ios_auth_browser');

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
      try {
        final opened = await _iosBrowserChannel.invokeMethod<bool>(
          'openAuthBrowser',
          {'url': uri.toString()},
        );
        if (opened == true) return true;
      } on MissingPluginException {
        // iOSネイティブ側が未更新の場合はurl_launcherへフォールバックする。
      } on PlatformException catch (error) {
        debugPrint('[BrowserLoginLauncher] iOS browser failed: ${error.message}');
      }
      return launchUrl(uri, mode: LaunchMode.inAppBrowserView);
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

    if (!kIsWeb && Platform.isIOS) {
      try {
        await _iosBrowserChannel.invokeMethod<void>('closeAuthBrowser');
      } on MissingPluginException {
        // フォールバック起動時など、閉じる対象がない場合は何もしない。
      } on PlatformException catch (error) {
        debugPrint('[BrowserLoginLauncher] iOS browser close failed: ${error.message}');
      }
    }
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
