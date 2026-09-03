import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// アプリのウィンドウ操作をまとめる小さなサービスです。
///
/// Windows では認証後に既定ブラウザが前面に残るため、ネイティブ側の MethodChannel を呼び、
/// RAiM アプリのウィンドウを前面に戻します。未対応プラットフォームでは何もしません。
class AppWindowService {
  static const MethodChannel _channel = MethodChannel('raim_window');

  static Future<void> activateAfterLogin() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('activate');
    } on MissingPluginException {
      // Windows ランナー以外ではチャンネルが存在しないため、そのまま無視します。
    } on PlatformException catch (error) {
      RaimLog.d('[AppWindowService] activate failed: ${error.message}');
    }
  }
}
