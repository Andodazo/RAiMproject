import 'dart:async';
import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// 「ねえライム」に反応したことを知らせる合図（スマホ用）。
///
/// 「ねえライム」のすぐ後に続けて話すと呼ばれていないとみなすので、
/// 話し始めてよいタイミングを短い音と振動で知らせる。
/// Windows は入力小窓が開くのが合図になるので使わない。
class WakeCue {
  WakeCue._();

  static const String _asset = 'sounds/wake_chime.wav';

  static AudioPlayer? _player;

  /// 振動させ、[sound] が true なら音も鳴らす。
  ///
  /// ライムの声を消しているときは音を鳴らさず、振動だけにする。
  static Future<void> play({required bool sound}) async {
    unawaited(HapticFeedback.mediumImpact());
    if (!sound) return;

    try {
      final player = _player ??= await _createPlayer();
      await player.stop();
      await player.play(AssetSource(_asset));
    } catch (e) {
      RaimLog.w('[WakeCue] 合図の音を鳴らせませんでした: ${e.runtimeType}');
    }
  }

  static Future<AudioPlayer> _createPlayer() async {
    final player = AudioPlayer();
    await player.setReleaseMode(ReleaseMode.stop);
    // Android: 合図の音のために音楽アプリを止めない（音声フォーカスを取らない）。
    // iOS は音声の設定がアプリ全体で1つなので、ここでは触らない（main.dart の設定のまま）。
    if (Platform.isAndroid) {
      await player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            usageType: AndroidUsageType.assistanceSonification,
            contentType: AndroidContentType.sonification,
            audioFocus: AndroidAudioFocus.none,
          ),
        ),
      );
    }
    return player;
  }
}
