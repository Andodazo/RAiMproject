import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// 振動（スマホ用）。
///
/// Flutter の HapticFeedback は「画面を触ったときの手応え」なので、
/// Android では次の理由でほとんど伝わらなかった。
/// - 端末の「タップ時の振動」が OFF だと震えない
/// - ON でも mediumImpact はキーボードを打つ程度のごく弱い振動
///
/// Android は本体のバイブを直接鳴らす（MainActivity の raim_haptics）。
/// iPhone は HapticFeedback のままでよい。ただし録音中は iOS が振動を
/// 止めるので、録音の設定で許可している（MicStreamService）。
class Haptics {
  Haptics._();

  static const MethodChannel _channel = MethodChannel('raim_haptics');

  /// 短く1回（「ねえライム」に反応した合図、降りる駅が近づいたとき）。
  ///
  /// [alarm] が true なら、画面が消えていても震えるようにする（駅アラーム用）。
  static Future<void> nudge({bool alarm = false}) async {
    if (Platform.isAndroid) {
      if (await _vibrate(const [0, 90], alarm: alarm)) return;
    }
    await HapticFeedback.heavyImpact();
  }

  /// 駅アラームで降りる駅に着いたとき。寝ていても気づくよう何度か震わせる。
  static Future<void> alarm() async {
    if (Platform.isAndroid) {
      if (await _vibrate(const [0, 500, 300, 500, 300, 500], alarm: true)) {
        return;
      }
    }
    for (var i = 0; i < 3; i++) {
      await HapticFeedback.vibrate();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// [pattern] は「待つ, 震える, 待つ, 震える, ...」のミリ秒。
  /// [alarm] が true なら目覚ましの扱いにする（画面が消えていても震える）。
  /// 鳴らせたら true。
  static Future<bool> _vibrate(List<int> pattern, {required bool alarm}) async {
    try {
      final ok = await _channel.invokeMethod<bool>('vibrate', {
        'pattern': pattern,
        'alarm': alarm,
      });
      return ok ?? false;
    } catch (e) {
      RaimLog.w('[Haptics] 振動させられませんでした: ${e.runtimeType}');
      return false;
    }
  }
}
