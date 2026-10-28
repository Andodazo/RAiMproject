// lib/services/station/station_alarm_repeater.dart
//
// 「着く」の知らせを、止めるまで繰り返す。
//
// 【なぜ要るか】
// 以前は「着く」で通知とライムの声を1回出すだけだった。寝ているとこの1回を
// 逃し、そのまま乗り過ごす。止める（アプリを開く・ボタンを押す）まで
// [interval] ごとに知らせ直す。鳴りっぱなしにならないよう [maxDuration] で
// 打ち切る。
//
// 何を鳴らすかは呼ぶ側（StationAlarmController）が [onRing] で決める。

import 'dart:async';

class StationAlarmRepeater {
  StationAlarmRepeater({
    required this.onRing,
    this.interval = const Duration(seconds: 15),
    this.maxDuration = const Duration(minutes: 2),
  });

  /// 知らせ直すたびに呼ぶ。最初の1回（start を呼んだとき）は呼ばない。
  final void Function() onRing;

  /// 知らせ直す間隔。
  final Duration interval;

  /// これだけたったら、止められていなくても打ち切る。
  final Duration maxDuration;

  Timer? _timer;
  DateTime? _startedAt;

  /// 繰り返している途中か。
  bool get isRinging => _timer != null;

  /// 繰り返しを始める。もう始めていれば何もしない。
  void start() {
    if (_timer != null) return;
    _startedAt = DateTime.now();
    _timer = Timer.periodic(interval, (_) {
      final started = _startedAt;
      if (started == null ||
          DateTime.now().difference(started) >= maxDuration) {
        stop();
        return;
      }
      onRing();
    });
  }

  /// 繰り返しを止める。
  void stop() {
    _timer?.cancel();
    _timer = null;
    _startedAt = null;
  }
}
