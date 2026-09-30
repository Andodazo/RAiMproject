import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/station/station_alarm.dart';
import 'package:raim_prototype/services/station/station_database.dart';

/// 中央線快速と中央・総武線（各駅停車）だけを抜き出した実データ。
/// tools/build_station_data.py の出力から作ったもの。
StationDatabase _db() => StationDatabase.fromJson(
      File('test/fixtures/stations_chuo.json').readAsStringSync(),
    );

Station _find(StationDatabase db, String name) =>
    db.search(name).firstWhere((s) => s.name == name || s.name.startsWith('$name('));

void main() {
  late StationDatabase db;
  setUp(() => db = _db());

  group('StationDatabase', () {
    test('読み込める', () {
      expect(db.stationCount, greaterThan(40));
      expect(db.lineCount, 2);
    });

    test('駅名・よみ・カタカナで探せる', () {
      expect(db.search('新宿').first.name, '新宿');
      expect(db.search('しんじゅく').first.name, '新宿');
      expect(db.search('シンジュク').first.name, '新宿');
    });

    test('前方一致が部分一致より先に来る', () {
      final names = db.search('なか').map((s) => s.name).toList();
      expect(names.first, startsWith('中野'));
      expect(names, contains('東中野'));
      expect(names.indexOf('東中野'), greaterThan(0));
    });

    test('隣の駅は路線ごとに違う', () {
      final shinjuku = _find(db, '新宿');
      final rapid = db.linesOf(shinjuku).firstWhere((l) => l.name.contains('快速'));
      final local = db.linesOf(shinjuku).firstWhere((l) => !l.name.contains('快速'));
      expect(db.neighbors(shinjuku, rapid).map((s) => s.name),
          containsAll(['四ツ谷(四ッ谷)', '中野(東京)']));
      expect(db.neighbors(shinjuku, local).map((s) => s.name),
          containsAll(['大久保(東京)', '代々木']));
    });

    test('終点の隣は1駅だけ', () {
      final takao = _find(db, '高尾');
      expect(db.neighbors(takao, db.linesOf(takao).single), hasLength(1));
    });

    test('距離（東京〜新宿はおよそ6km）', () {
      final a = _find(db, '東京');
      final b = _find(db, '新宿');
      final d = distanceMeters(a.lat, a.lng, b.lat, b.lng);
      expect(d, inInclusiveRange(5500, 7000));
    });

    test('近い駅', () {
      final s = _find(db, '新宿');
      expect(db.nearest(s.lat, s.lng, limit: 1).single, s);
    });
  });

  group('StationAlarmPlan', () {
    test('路線を指定しなければ、通る路線すべての隣の駅を待つ', () {
      final plan = StationAlarmPlan.build(db, _find(db, '新宿'));
      expect(
        plan.approach.map((s) => s.name),
        containsAll(['四ツ谷(四ッ谷)', '中野(東京)', '大久保(東京)', '代々木']),
      );
      expect(plan.decoys, isNot(contains(plan.destination)));
      expect(plan.decoys.toSet().intersection(plan.approach.toSet()), isEmpty);
    });

    test('文法に決まり文句と「つぎ は ◯◯」が入る', () {
      final plan = StationAlarmPlan.build(db, _find(db, '新宿'));
      final g = plan.grammar;
      expect(g, containsAll(['つぎ は', 'まもなく', 'しん じゅく', 'つぎ は しん じゅく', '[unk]']));
      expect(g.toSet().length, g.length); // 重複なし
    });

    test('デコイは近い駅から', () {
      final shinjuku = _find(db, '新宿');
      final rapid = db.linesOf(shinjuku).firstWhere((l) => l.name.contains('快速'));
      final plan = StationAlarmPlan.build(db, shinjuku, line: rapid);
      // 隣（四ツ谷・中野）の次に近いのは御茶ノ水と高円寺
      expect(plan.decoys.take(2).map((s) => s.name),
          containsAll(['御茶ノ水', '高円寺']));
    });
  });

  group('StationAnnouncementDetector', () {
    late StationAnnouncementDetector detector;
    final t0 = DateTime(2026, 9, 29, 8);

    setUp(() {
      detector = StationAnnouncementDetector(
        StationAlarmPlan.build(db, _find(db, '新宿')),
      );
    });

    test('「次は新宿」で着く知らせ', () {
      final e = detector.onResult('つぎ は しん じゅく', at: t0);
      expect(e?.stage, StationAlarmStage.arriving);
      expect(e?.station.name, '新宿');
      expect(detector.arrived, isTrue);
    });

    test('「まもなく新宿」でも着く知らせ', () {
      final e = detector.onResult('まもなく しん じゅく', at: t0);
      expect(e?.stage, StationAlarmStage.arriving);
    });

    test('「新宿、新宿」と2回言われたら着く知らせ', () {
      final e = detector.onResult('[unk] しん じゅく しん じゅく [unk]', at: t0);
      expect(e?.stage, StationAlarmStage.arriving);
    });

    test('間に余計な音が挟まっても判定できる', () {
      final e = detector.onResult('つぎ は [unk] しん じゅく', at: t0);
      expect(e?.stage, StationAlarmStage.arriving);
    });

    test('駅名だけ（「新宿行き」など）では知らせない', () {
      expect(detector.onResult('[unk] しん じゅく [unk]', at: t0), isNull);
      expect(detector.arrived, isFalse);
    });

    test('「次は」と駅名が別の結果に分かれても、すぐ後ならつなげる', () {
      expect(detector.onResult('[unk] つぎ は', at: t0), isNull);
      final e = detector.onResult('しん じゅく [unk]',
          at: t0.add(const Duration(seconds: 2)));
      expect(e?.stage, StationAlarmStage.arriving);
    });

    test('「次は」から時間が空いたらつなげない', () {
      detector.onResult('つぎ は', at: t0);
      expect(
        detector.onResult('しん じゅく', at: t0.add(const Duration(seconds: 10))),
        isNull,
      );
    });

    test('隣の駅のアナウンスで「もうすぐ」の知らせ', () {
      final e = detector.onResult('つぎ は なかの', at: t0);
      expect(e?.stage, StationAlarmStage.approaching);
      expect(e?.station.name, '中野(東京)');
    });

    test('遠い駅（デコイ）のアナウンスでは知らせない', () {
      expect(detector.onResult('つぎ は こう えんじ', at: t0), isNull);
      expect(detector.onResult('つぎ は おちゃ の みず', at: t0), isNull);
    });

    test('「東中野」を「中野」と取り違えない', () {
      // 中野で降りる場合。東中野（ひがし なかの）の後ろ半分に反応しないこと
      final nakano = StationAnnouncementDetector(
        StationAlarmPlan.build(db, _find(db, '中野')),
      );
      // 東中野は中野の隣なので「もうすぐ」になる。「着く」にはならない
      final e = nakano.onResult('ひがし なかの ひがし なかの', at: t0);
      expect(e?.stage, StationAlarmStage.approaching);
      expect(e?.station.name, '東中野');
      expect(nakano.arrived, isFalse);

      expect(
        nakano
            .onResult('つぎ は なかの', at: t0.add(const Duration(minutes: 2)))
            ?.stage,
        StationAlarmStage.arriving,
      );
    });

    test('同じ知らせは繰り返さない（日本語と英語で2回流れるため）', () {
      expect(detector.onResult('つぎ は しん じゅく', at: t0), isNotNull);
      expect(
        detector.onResult('まもなく しん じゅく',
            at: t0.add(const Duration(seconds: 30))),
        isNull,
      );
    });

    test('着いた後は隣の駅を知らせない', () {
      detector.onResult('つぎ は しん じゅく', at: t0);
      expect(
        detector.onResult('つぎ は よ よぎ',
            at: t0.add(const Duration(minutes: 3))),
        isNull,
      );
    });

    group('駅名の繰り返し（GPS で近いとき）', () {
      test('「次は」が聞き取れなくても、2回聞こえたら知らせる', () {
        expect(
          detector.onResult('[unk] しん じゅく', at: t0, allowRepeated: true),
          isNull,
        );
        final e = detector.onResult(
          'しん じゅく [unk]',
          at: t0.add(const Duration(seconds: 20)),
          allowRepeated: true,
        );
        expect(e?.stage, StationAlarmStage.arriving);
        expect(e?.station.name, '新宿');
      });

      test('隣の駅の繰り返しで「もうすぐ」', () {
        detector.onResult('よ つや', at: t0, allowRepeated: true);
        final e = detector.onResult(
          '[unk] よ つや',
          at: t0.add(const Duration(seconds: 10)),
          allowRepeated: true,
        );
        expect(e?.stage, StationAlarmStage.approaching);
        expect(e?.station.name, startsWith('四ツ谷'));
      });

      test('GPS の裏付けが無ければ、繰り返しだけでは知らせない', () {
        // 「この電車は新宿行きです」が何度も流れる場合
        detector.onResult('[unk] しん じゅく [unk]', at: t0);
        expect(
          detector.onResult('[unk] しん じゅく [unk]',
              at: t0.add(const Duration(seconds: 20))),
          isNull,
        );
      });

      test('間が空いた2回は数えない', () {
        detector.onResult('しん じゅく', at: t0, allowRepeated: true);
        expect(
          detector.onResult(
            'しん じゅく',
            at: t0.add(const Duration(seconds: 60)),
            allowRepeated: true,
          ),
          isNull,
        );
      });
    });

    test('reset で次の乗車に使える', () {
      detector.onResult('つぎ は しん じゅく', at: t0);
      detector.reset();
      expect(detector.arrived, isFalse);
      expect(detector.onResult('つぎ は しん じゅく', at: t0), isNotNull);
    });
  });
}
