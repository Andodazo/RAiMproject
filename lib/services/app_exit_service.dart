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
///
/// iOSではAppleの制約により、Debugビルドに限って
/// ネイティブMethodChannel経由のプロセス終了を試行します。
/// ただし、iPhone実機では `flutter run --debug -d ...` で実行しても
/// 強制終了できないことを確認済みです。ログアウト時のToken削除は成功するため、
/// 現状はアプリを終了できなくても開発を継続します。
class AppExitService {
  static const MethodChannel _appControlChannel = MethodChannel(
    'raim_app_control',
  );

  static Future<void> exitAfterLogout() async {
    if (kIsWeb) {
      await SystemNavigator.pop();
      return;
    }

    if (Platform.isAndroid) {
      try {
        await _appControlChannel.invokeMethod<void>('exitToHomeAndRemoveTask');
        return;
      } on MissingPluginException {
        // 古いビルドや未対応プラットフォームでは通常の終了へフォールバックします。
      } on PlatformException catch (error) {
        debugPrint('[AppExitService] Android exit failed: ${error.message}');
      }
    }

    if (Platform.isIOS && kDebugMode) {
      // iPhone実機ではDebugビルドでも終了できない既知の制限があります。
      // Token削除は完了しているため、終了できなくても処理を継続します。
      try {
        await _appControlChannel.invokeMethod<void>('debugExitProcess');
        return;
      } on MissingPluginException {
        debugPrint('[AppExitService] iOS debug exit is unavailable');
      } on PlatformException catch (error) {
        debugPrint('[AppExitService] iOS debug exit failed: ${error.message}');
      }
    }

    await SystemNavigator.pop();

    if (Platform.isWindows) {
      exit(0);
    }
  }
}
