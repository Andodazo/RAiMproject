import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// ログアウト後のアプリ終了処理をプラットフォーム別に吸収するサービスです。
///
/// Android では `SystemNavigator.pop()` だけだと、直前に開いていた認証ブラウザへ戻ったり、
/// RAiM アプリのタスクが履歴に残ったりします。そのため Android ネイティブ側の
/// `finishAndRemoveTask()` とプロセス終了を MethodChannel 経由で呼びます。
///
/// Windows では Flutter desktop が `SystemNavigator.pop()` だけで終了しないことがあるため、
/// 既存どおり最後に `exit(0)` まで行います。
class AppExitService {
  static const MethodChannel _androidChannel = MethodChannel(
    'raim_app_control',
  );

  static Future<void> exitAfterLogout() async {
    if (kIsWeb) {
      await SystemNavigator.pop();
      return;
    }

    if (Platform.isAndroid) {
      try {
        await _androidChannel.invokeMethod<void>('exitToHomeAndRemoveTask');
        return;
      } on MissingPluginException {
        // 古いビルドや未対応プラットフォームでは通常の終了へフォールバックします。
      } on PlatformException catch (error) {
        debugPrint('[AppExitService] Android exit failed: ${error.message}');
      }
    }

    await SystemNavigator.pop();

    if (Platform.isWindows) {
      exit(0);
    }
  }
}
