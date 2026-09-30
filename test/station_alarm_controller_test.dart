import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/providers/station_alarm_controller.dart';
import 'package:raim_prototype/services/station/station_database.dart';

void main() {
  const shinjuku = Station(
    code: 1130208,
    name: '新宿',
    kana: 'しんじゅく',
    vosk: 'しん じゅく',
    lat: 35.690,
    lng: 139.700,
  );

  test('対応していない端末では始めずにエラーを出す', () async {
    // テストは Windows / Linux / macOS で動くので、Android 以外として扱われる
    final c = StationAlarmController();
    expect(StationAlarmController.isSupported, isFalse);

    await c.start(shinjuku);
    expect(c.state, StationAlarmState.error);
    expect(c.errorMessage, contains('まだ'));
    expect(c.isActive, isFalse);

    // 止めると元に戻る
    await c.stop();
    expect(c.state, StationAlarmState.idle);
    c.dispose();
  });

  test('対応していない端末では駅名で始めようとしても始めない', () async {
    final c = StationAlarmController();
    expect(await c.startByName('新宿'), isNull);
    expect(c.isActive, isFalse);
    c.dispose();
  });
}
