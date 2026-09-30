// lib/services/station/station_database.dart
//
// 駅アラーム用の駅データ（assets/stations/stations.json）を読む。
//
// データは tools/build_station_data.py で作る。元は station_database
// （Seo-4d696b75、CC BY 4.0）。クレジット表記に出典を載せている。
//
// 【Vosk 用の形（vosk）】
// 駅名のよみを、Vosk の辞書にある語に分けて空白でつないだもの
// （新宿 → "しん じゅく"）。そのまま Vosk の文法に入れられる。
// 漢字のままだと辞書側の読みになり、特殊な読みの駅でずれる（放出 → ほうしゅつ）。

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

const String kStationDataAsset = 'assets/stations/stations.json';

class Station {
  const Station({
    required this.code,
    required this.name,
    required this.kana,
    required this.vosk,
    required this.lat,
    required this.lng,
  });

  final int code;

  /// 表示用の駅名（同名の駅は「府中(東京都)」のように区別されている）
  final String name;

  /// よみがな
  final String kana;

  /// Vosk の文法に入れる形（辞書の語を空白でつないだもの）
  final String vosk;

  final double lat;
  final double lng;

  @override
  bool operator ==(Object other) => other is Station && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'Station($code $name)';
}

class RailLine {
  const RailLine({
    required this.code,
    required this.name,
    required this.kana,
    required this.stationCodes,
  });

  final int code;
  final String name;
  final String kana;

  /// 路線上の並び順の駅コード
  final List<int> stationCodes;

  @override
  String toString() => 'RailLine($code $name)';
}

class StationDatabase {
  StationDatabase._(this._stations, this._lines) {
    for (final line in _lines.values) {
      for (final code in line.stationCodes) {
        (_linesOfStation[code] ??= []).add(line);
      }
    }
  }

  final Map<int, Station> _stations;
  final Map<int, RailLine> _lines;
  final Map<int, List<RailLine>> _linesOfStation = {};

  static StationDatabase? _cache;

  /// アセットから読む。2回目以降は読み込み済みのものを返す。
  static Future<StationDatabase> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final json = await rootBundle.loadString(kStationDataAsset);
    return _cache = StationDatabase.fromJson(json);
  }

  /// JSON 文字列から作る（テスト用にも使う）。
  ///
  /// 形式は tools/build_station_data.py の出力:
  ///   stations: [[コード, 駅名, よみ, vosk, 緯度, 経度], ...]
  ///   lines:    [[コード, 路線名, よみ, [駅コード...]], ...]
  factory StationDatabase.fromJson(String json) {
    final data = jsonDecode(json) as Map<String, dynamic>;

    final stations = <int, Station>{};
    for (final row in data['stations'] as List) {
      final r = row as List;
      final s = Station(
        code: r[0] as int,
        name: r[1] as String,
        kana: r[2] as String,
        vosk: r[3] as String,
        lat: (r[4] as num).toDouble(),
        lng: (r[5] as num).toDouble(),
      );
      stations[s.code] = s;
    }

    final lines = <int, RailLine>{};
    for (final row in data['lines'] as List) {
      final r = row as List;
      final codes = [
        for (final c in r[3] as List)
          if (stations.containsKey(c)) c as int,
      ];
      if (codes.isEmpty) continue;
      final l = RailLine(
        code: r[0] as int,
        name: r[1] as String,
        kana: r[2] as String,
        stationCodes: List.unmodifiable(codes),
      );
      lines[l.code] = l;
    }

    return StationDatabase._(stations, lines);
  }

  int get stationCount => _stations.length;
  int get lineCount => _lines.length;

  /// すべての駅（並びは決まっていない）。
  Iterable<Station> get stations => _stations.values;

  Station? station(int code) => _stations[code];
  RailLine? line(int code) => _lines[code];

  /// その駅を通る路線。
  List<RailLine> linesOf(Station station) =>
      List.unmodifiable(_linesOfStation[station.code] ?? const []);

  /// 路線の駅を並び順で。
  List<Station> stationsOf(RailLine line) => [
        for (final c in line.stationCodes) ?_stations[c],
      ];

  /// 路線上で隣の駅（前後）。
  List<Station> neighbors(Station station, RailLine line) {
    final i = line.stationCodes.indexOf(station.code);
    if (i < 0) return const [];
    return [
      if (i > 0) _stations[line.stationCodes[i - 1]]!,
      if (i < line.stationCodes.length - 1) _stations[line.stationCodes[i + 1]]!,
    ];
  }

  /// 駅名・よみで探す。前方一致を先に、部分一致を後に並べる。
  ///
  /// ひらがな・カタカナのどちらで打っても探せるよう、カタカナは
  /// ひらがなに直して比べる。
  List<Station> search(String query, {int limit = 30}) {
    final q = _toHiragana(query.trim());
    if (q.isEmpty) return const [];

    final prefix = <Station>[];
    final contains = <Station>[];
    for (final s in _stations.values) {
      final name = _toHiragana(s.name);
      if (name.startsWith(q) || s.kana.startsWith(q)) {
        prefix.add(s);
      } else if (name.contains(q) || s.kana.contains(q)) {
        contains.add(s);
      }
    }
    int byName(Station a, Station b) {
      final l = a.name.length.compareTo(b.name.length);
      return l != 0 ? l : a.kana.compareTo(b.kana);
    }

    prefix.sort(byName);
    contains.sort(byName);
    return [...prefix, ...contains].take(limit).toList();
  }

  /// 近い順に駅を返す。
  List<Station> nearest(double lat, double lng, {int limit = 5}) {
    final all = _stations.values.toList()
      ..sort((a, b) => distanceMeters(lat, lng, a.lat, a.lng)
          .compareTo(distanceMeters(lat, lng, b.lat, b.lng)));
    return all.take(limit).toList();
  }
}

/// 2点間の距離（メートル）。球面の近似で十分な精度（駅の判定用）。
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

String _toHiragana(String s) => String.fromCharCodes(
      s.runes.map((c) => (c >= 0x30A1 && c <= 0x30F6) ? c - 0x60 : c),
    );
