import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/station/station_alarm.dart';
import 'package:raim_prototype/services/station/station_database.dart';
import 'package:raim_prototype/services/station/station_proximity.dart';

/// 中央線快速の新宿で降りる場合で確かめる（実データ）。
///   新宿からの距離: 代々木 755m / 大久保 1.3km / 四ツ谷 2.8km /
///   中野 3.6km / 高円寺 4.9km / 東京 6.0km / 阿佐ケ谷 6.1km / 高尾 38km
void main() {
  late StationDatabase db;
  late StationProximity p;
  final t0 = DateTime(2026, 9, 29, 8);

  Station at(String name) => db
      .search(name)
      .firstWhere((s) => s.name == name || s.name.startsWith('$name('));

  StationAlarmStage? move(String name, {Duration after = Duration.zero}) {
    final s = at(name);
    return p.onPosition(s.lat, s.lng, accuracy: 20, at: t0.add(after));
  }

  setUp(() {
    db = StationDatabase.fromJson(
      File('test/fixtures/stations_chuo.json').readAsStringSync(),
    );
    final shinjuku = at('新宿');
    final rapid =
        db.linesOf(shinjuku).firstWhere((l) => l.name.contains('快速'));
    p = StationProximity(StationAlarmPlan.build(db, shinjuku, line: rapid));
  });

  test('距離の目安は隣の駅までの距離から決まる', () {
    // 近い方の隣（四ツ谷 2.8km）の 1.1 倍
    expect(p.approachRadius, closeTo(3030, 50));
    // 遠い方の隣（中野 3.6km）の 2.5 倍
    expect(p.gateRadius, closeTo(9000, 50));
  });

  group('音声の絞り込み', () {
    test('位置が分からなければ受け入れる', () {
      expect(p.allowsVoice(t0), isTrue);
    });

    test('遠く（高尾）で聞こえたアナウンスは受け入れない', () {
      move('高尾');
      expect(p.allowsVoice(t0), isFalse);
    });

    test('近く（東京）なら受け入れる', () {
      move('東京');
      expect(p.allowsVoice(t0), isTrue);
    });

    test('位置が古くなったら（地下など）受け入れる', () {
      move('高尾');
      expect(p.allowsVoice(t0.add(const Duration(minutes: 2))), isTrue);
    });

    test('精度が悪い位置は使わない', () {
      final s = at('高尾');
      p.onPosition(s.lat, s.lng, accuracy: 500, at: t0);
      expect(p.distance, isNull);
      expect(p.allowsVoice(t0), isTrue);
    });
  });

  group('GPS だけで知らせる（アナウンスを聞き逃したとき）', () {
    test('近づくと「もうすぐ」、着くと「着く」を1回ずつ', () {
      expect(move('阿佐ケ谷'), isNull);
      expect(move('中野'), isNull);
      expect(move('大久保'), StationAlarmStage.approaching);
      expect(move('代々木'), isNull);
      expect(move('新宿'), StationAlarmStage.arriving);
      expect(move('新宿'), isNull);
    });

    test('始めた場所がもう近くても、始めた瞬間には鳴らない', () {
      expect(move('大久保'), isNull);
      expect(move('新宿'), StationAlarmStage.arriving);
    });

    test('音声で知らせた後は、同じ知らせを GPS で重ねない', () {
      move('中野');
      p.markNotified(StationAlarmStage.approaching);
      expect(move('大久保'), isNull);
      expect(move('新宿'), StationAlarmStage.arriving);
    });
  });
}
