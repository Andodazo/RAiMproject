// lib/services/station/station_lookup.dart
//
// 声やチャットで言われた駅名（「新宿」「神田」）から駅と路線を選ぶ。
//
// ライムが「新宿で起こして」を受けて駅アラームを頼んでくる（client_action）。
// そのとき届くのは駅名の文字だけなので、ここで駅データの中から探す。
//
// 【選び方】
//   - 駅名がそのまま一致するものだけを候補にする。
//     「四谷」で「四谷三丁目」のような別の駅を選ばないため、前方一致では選ばない
//   - 同じ名前の駅が複数あるとき（神田(東京) と 神田(長崎) など）は、
//     今いる場所が分かれば一番近い駅、分からなければ路線の多い駅
//   - 表記ゆれ（ヶ／ケ、ッ／ツ、「駅」付き）は同じとみなす
//   - よみがな（ライムが kana として添える）でも探す。「お茶の水」と
//     「御茶ノ水」、「四谷」と「四ツ谷」のように漢字の表記が違うときに効く。
//     同じ名前の駅（神田＝かんだ／こうだ）の区別にも使う
//
// 見つからなければ null。呼び出し側は駅アラームの画面を開いて選んでもらう。

import 'package:raim_prototype/services/station/station_database.dart';

/// 言われた駅名から駅を選ぶ。見つからなければ null。
///
/// [kana] は駅名のよみがな（分かるときだけ）。
/// [lat] / [lng] は今いる場所（分かるときだけ）。
Station? findStationByName(
  StationDatabase db,
  String name, {
  String? kana,
  double? lat,
  double? lng,
}) {
  final want = normalizeStationName(name);
  // よみがなで言われたとき用。表記ゆれを揃える前の形で比べる
  // （「ヨッツヤ」の「ッ」を「ツ」にすると、よみと合わなくなる）
  final raw = name.replaceAll(RegExp(r'\s+'), '');
  final nameKana = _isKana(raw) ? _toHiragana(raw) : null;
  final givenKana = _cleanKana(kana);
  if (want.isEmpty && givenKana == null) return null;

  var candidates = <Station>[
    for (final s in db.stations)
      if ((want.isNotEmpty && normalizeStationName(s.name) == want) ||
          (nameKana != null && s.kana == nameKana))
        s,
  ];

  if (givenKana != null) {
    final byKana = [
      for (final s in db.stations)
        if (s.kana == givenKana) s,
    ];
    if (candidates.isEmpty) {
      // 漢字の表記が違う（お茶の水／御茶ノ水）ときは、よみで探す
      candidates = byKana;
    } else if (candidates.length > 1) {
      // 同じ名前が複数あれば、よみの合う方に絞る（神田＝かんだ／こうだ）
      final narrowed = [
        for (final s in candidates)
          if (s.kana == givenKana) s,
      ];
      if (narrowed.isNotEmpty) candidates = narrowed;
    }
  }
  if (candidates.isEmpty) return null;
  if (candidates.length == 1) return candidates.single;

  if (lat != null && lng != null) {
    candidates.sort((a, b) => distanceMeters(lat, lng, a.lat, a.lng)
        .compareTo(distanceMeters(lat, lng, b.lat, b.lng)));
    return candidates.first;
  }

  // 場所が分からなければ、路線の多い（大きい）駅を選ぶ
  candidates.sort((a, b) {
    final byLines = db.linesOf(b).length.compareTo(db.linesOf(a).length);
    return byLines != 0 ? byLines : a.code.compareTo(b.code);
  });
  return candidates.first;
}

/// 言われた路線名から、その駅を通る路線を選ぶ。
///
/// 1つに決まらないとき（言われていない・見つからない・複数当てはまる）は null
/// を返す。null は「その駅を通るすべての路線を待つ」の意味になる。
RailLine? findLineByName(
  StationDatabase db,
  Station station,
  String? lineName,
) {
  final want = _normalizeLineName(lineName ?? '');
  if (want.isEmpty) return null;

  final lines = db.linesOf(station);
  final hits = [
    for (final l in lines)
      if (_normalizeLineName(l.name).contains(want)) l,
  ];
  if (hits.length == 1) return hits.single;

  // 「中央線」と言われて「中央線(快速)」と「中央線(各停)」の両方に当たるなど。
  // 名前が完全に一致するものがあればそれ、無ければ決めない
  for (final l in hits) {
    if (_normalizeLineName(l.name) == want) return l;
  }
  return null;
}

/// 駅名を比べやすい形にする。
///
///   - 「(東京)」のような区別用の括弧書きを外す（神田(東京) → 神田）
///   - 末尾の「駅」を外す
///   - ヶ・ヵ・ケ と ッ・ツ の表記ゆれを揃える
String normalizeStationName(String name) {
  var s = name.replaceAll(RegExp(r'\s+'), '');
  s = s.replaceAll(RegExp(r'[（(][^）)]*[）)]$'), '');
  if (s.endsWith('駅')) s = s.substring(0, s.length - 1);
  s = s
      .replaceAll(RegExp('[ヶヵケ]'), 'ケ')
      .replaceAll(RegExp('[ッツ]'), 'ツ');
  return s;
}

/// 路線名を比べやすい形にする（空白と先頭の「JR」を外す）。
///
/// 「線」は外さない。外すと「中央線」が「中央・総武線」や「中央本線」にも
/// 当たってしまい、1つに決まらなくなる。
String _normalizeLineName(String name) {
  var s = name.replaceAll(RegExp(r'\s+'), '');
  s = s.replaceFirst(RegExp(r'^JR'), '');
  return s;
}

/// よみがなを揃える。ひらがな・カタカナ以外が混ざっていれば null。
String? _cleanKana(String? kana) {
  if (kana == null) return null;
  var s = kana.replaceAll(RegExp(r'\s+'), '');
  if (s.endsWith('えき')) s = s.substring(0, s.length - 2);
  if (s.isEmpty || !_isKana(s)) return null;
  return _toHiragana(s);
}

bool _isKana(String s) => s.runes.every(
      (c) => (c >= 0x3041 && c <= 0x3096) || (c >= 0x30A1 && c <= 0x30FC),
    );

String _toHiragana(String s) => String.fromCharCodes(
      s.runes.map((c) => (c >= 0x30A1 && c <= 0x30F6) ? c - 0x60 : c),
    );
