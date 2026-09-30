import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/station/station_database.dart';
import 'package:raim_prototype/services/station/station_lookup.dart';

/// 中央線快速と中央・総武線の実データ。
StationDatabase _chuo() => StationDatabase.fromJson(
      File('test/fixtures/stations_chuo.json').readAsStringSync(),
    );

/// 同じ名前の駅がある場合を確かめるための小さなデータ。
///   神田(東京) … 路線2本・東京
///   神田(長崎) … 路線1本・長崎
StationDatabase _sameName() => StationDatabase.fromJson(jsonEncode({
      'stations': [
        [1, '神田(東京)', 'かんだ', 'か んだ', 35.69117, 139.77064],
        [2, '神田(長崎)', 'こうだ', 'こう だ', 33.2612, 129.67106],
        [3, '東京', 'とうきょう', 'とう きょう', 35.68139, 139.7661],
        [4, '江迎鹿町', 'えむかえしかまち', 'えむかえ しか まち', 33.25, 129.68],
      ],
      'lines': [
        [10, 'JR中央線(快速)', 'ちゅうおうせん', [3, 1]],
        [11, 'JR山手線', 'やまのてせん', [3, 1]],
        [20, '松浦鉄道西九州線', 'にしきゅうしゅうせん', [4, 2]],
      ],
    }));

void main() {
  group('findStationByName', () {
    final db = _chuo();

    test('駅名がそのまま一致する駅を選ぶ', () {
      expect(findStationByName(db, '新宿')?.name, '新宿');
    });

    test('区別用の括弧書きを付けずに言われても選べる', () {
      expect(findStationByName(db, '神田')?.name, '神田(東京)');
      expect(findStationByName(db, '中野')?.name, '中野(東京)');
    });

    test('表記ゆれと「駅」付きを同じとみなす', () {
      expect(findStationByName(db, '四ッ谷')?.name, '四ツ谷(四ッ谷)');
      expect(findStationByName(db, '阿佐ヶ谷')?.name, '阿佐ケ谷');
      expect(findStationByName(db, '新宿駅')?.name, '新宿');
    });

    test('よみがなでも選べる', () {
      expect(findStationByName(db, 'しんじゅく')?.name, '新宿');
      expect(findStationByName(db, 'シンジュク')?.name, '新宿');
    });

    test('漢字の表記が違っても、よみがなで選べる', () {
      expect(
        findStationByName(db, 'お茶の水', kana: 'おちゃのみず')?.name,
        '御茶ノ水',
      );
      expect(findStationByName(db, '四谷', kana: 'よつや')?.name, '四ツ谷(四ッ谷)');
      // よみがなに漢字が混ざっていたら使わない
      expect(findStationByName(db, 'お茶の水', kana: 'お茶のみず'), isNull);
    });

    test('前方一致では選ばない（「中」で中野にしない）', () {
      expect(findStationByName(db, '中'), isNull);
      expect(findStationByName(db, '存在しない駅'), isNull);
      expect(findStationByName(db, ''), isNull);
    });
  });

  group('同じ名前の駅', () {
    final db = _sameName();

    test('場所が分かれば近い方', () {
      // 長崎の近く
      expect(
        findStationByName(db, '神田', lat: 33.26, lng: 129.67)?.name,
        '神田(長崎)',
      );
      // 東京の近く
      expect(
        findStationByName(db, '神田', lat: 35.68, lng: 139.76)?.name,
        '神田(東京)',
      );
    });

    test('場所が分からなければ路線の多い方', () {
      expect(findStationByName(db, '神田')?.name, '神田(東京)');
    });

    test('よみがなが分かれば、よみの合う方', () {
      // 場所が東京の近くでも、よみが「こうだ」なら長崎の神田
      expect(
        findStationByName(db, '神田', kana: 'こうだ', lat: 35.68, lng: 139.76)
            ?.name,
        '神田(長崎)',
      );
    });
  });

  group('findLineByName', () {
    final db = _chuo();
    final shinjuku = findStationByName(db, '新宿')!;

    test('言われた路線を選ぶ', () {
      expect(findLineByName(db, shinjuku, '中央線')?.name, 'JR中央線(快速)');
      expect(findLineByName(db, shinjuku, '総武線')?.name, 'JR中央・総武線');
    });

    test('言われていない・当てはまらないときは決めない（すべての路線）', () {
      expect(findLineByName(db, shinjuku, null), isNull);
      expect(findLineByName(db, shinjuku, ''), isNull);
      expect(findLineByName(db, shinjuku, '山手線'), isNull);
      // 「中央」だけだと2本とも当てはまるので決めない
      expect(findLineByName(db, shinjuku, '中央'), isNull);
    });
  });
}
