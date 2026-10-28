import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/station/station_alarm_repeater.dart';

void main() {
  test('止めるまで間隔ごとに知らせ直す', () async {
    var rings = 0;
    final r = StationAlarmRepeater(
      onRing: () => rings++,
      interval: const Duration(milliseconds: 20),
      maxDuration: const Duration(seconds: 10),
    );
    r.start();
    expect(r.isRinging, isTrue);
    expect(rings, 0); // 最初の1回は呼ぶ側が鳴らす

    await Future<void>.delayed(const Duration(milliseconds: 110));
    expect(rings, greaterThanOrEqualTo(2));

    r.stop();
    expect(r.isRinging, isFalse);
    final stopped = rings;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(rings, stopped);
  });

  test('上限の時間がたったら打ち切る', () async {
    var rings = 0;
    final r = StationAlarmRepeater(
      onRing: () => rings++,
      interval: const Duration(milliseconds: 20),
      maxDuration: const Duration(milliseconds: 70),
    );
    r.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(r.isRinging, isFalse);
    expect(rings, inInclusiveRange(1, 3));
  });

  test('2回 start しても二重に鳴らない', () async {
    var rings = 0;
    final r = StationAlarmRepeater(
      onRing: () => rings++,
      interval: const Duration(milliseconds: 30),
      maxDuration: const Duration(seconds: 10),
    );
    r.start();
    r.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    r.stop();
    expect(rings, inInclusiveRange(2, 3));
  });
}
