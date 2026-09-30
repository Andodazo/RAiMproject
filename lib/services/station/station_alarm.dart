// lib/services/station/station_alarm.dart
//
// 車内アナウンスから「降りる駅に着く」ことを見つける。
//
// 音声認識（Vosk）には依存しない。認識結果の文字列を onResult() に渡すと、
// 知らせるべきことがあればイベントを返す。Vosk とのつなぎは別に持つ。
//
// 【文法】
// 目的の駅と、その隣の駅を「つぎ は ◯◯」「まもなく ◯◯」の形でも入れる。
// 同じ路線の他の駅はデコイ（取り違え防止）として駅名だけ入れる。
// デコイが無いと、Vosk は他の駅名を聞いても一番近い目的の駅に寄せてしまう
// （ウェイクワードで「スライム」が「ライム」になったのと同じ）。
//
// 【判定】
// 駅名が聞こえただけでは知らせない。「この電車は高尾行きです」のように、
// 行き先として毎駅アナウンスされるため。次のどれかのときだけ知らせる。
//   - 直前に「次は」「まもなく」がある
//   - 同じ駅名が続けて2回聞こえた（「次は新宿、新宿」の言い方）
//   - 「次は」だけが前の結果で聞こえていて、すぐ後に駅名が来た
//   - GPS で駅の近くにいると分かっているときは、別々の結果で
//     同じ駅名が短い間に2回聞こえた（allowRepeated）
//
// 最後の条件は、実機で「次は」がほとんど聞き取れなかったため。
// 車内アナウンスは同じ駅名を何度も言う（「次は◯◯」「The next station is ◯◯」
// 「まもなく◯◯」）ので、駅名が繰り返し聞こえること自体が手がかりになる。
// ただし「◯◯行き」も繰り返し流れるので、位置で裏付けが取れるときに限る。

import 'package:raim_prototype/services/station/station_database.dart';

/// 何を知らせるか。
enum StationAlarmStage {
  /// 隣の駅のアナウンス。もうすぐ（1つ手前か、乗り過ごした直後）
  approaching,

  /// 目的の駅のアナウンス。降りる準備を
  arriving,
}

class StationAlarmEvent {
  const StationAlarmEvent({
    required this.stage,
    required this.station,
    required this.heard,
    required this.at,
  });

  final StationAlarmStage stage;

  /// アナウンスされた駅（arriving なら目的の駅、approaching なら隣の駅）
  final Station station;

  /// 認識結果（デバッグ・ログ用）
  final String heard;
  final DateTime at;

  @override
  String toString() => 'StationAlarmEvent(${stage.name}, ${station.name})';
}

/// 1回の乗車で待つ駅の組み合わせ。
class StationAlarmPlan {
  StationAlarmPlan({
    required this.destination,
    required List<Station> approach,
    required List<Station> decoys,
  })  : approach = List.unmodifiable(approach),
        decoys = List.unmodifiable(decoys);

  /// デコイの上限。多すぎると文法が大きくなり、認識が遅くなる。
  static const int maxDecoys = 120;

  /// 目的の駅から作る。
  ///
  /// [line] を指定しなければ、目的の駅を通るすべての路線を使う
  /// （乗換駅でどの路線に乗っているか分からないとき）。
  factory StationAlarmPlan.build(
    StationDatabase db,
    Station destination, {
    RailLine? line,
  }) {
    final lines = line != null ? [line] : db.linesOf(destination);

    final approach = <Station>{};
    for (final l in lines) {
      approach.addAll(db.neighbors(destination, l));
    }
    approach.remove(destination);

    // デコイは目的の駅に近い順に選ぶ（遠い駅はまず聞こえない）
    final byDistance = <Station, int>{};
    for (final l in lines) {
      final stations = db.stationsOf(l);
      final center = stations.indexOf(destination);
      for (var i = 0; i < stations.length; i++) {
        final s = stations[i];
        if (s == destination || approach.contains(s)) continue;
        final d = (i - center).abs();
        final prev = byDistance[s];
        if (prev == null || d < prev) byDistance[s] = d;
      }
    }
    final decoys = byDistance.keys.toList()
      ..sort((a, b) => byDistance[a]!.compareTo(byDistance[b]!));

    return StationAlarmPlan(
      destination: destination,
      approach: approach.toList(),
      decoys: decoys.take(maxDecoys).toList(),
    );
  }

  final Station destination;
  final List<Station> approach;
  final List<Station> decoys;

  /// アナウンスの決まり文句。駅名の前に来る。
  static const List<String> cues = ['つぎ は', 'まもなく'];

  /// Vosk に渡す文法。
  ///
  /// 目的の駅と隣の駅は「つぎ は ◯◯」の形でも入れておく。続けて言われる
  /// 並びを文法に入れておくと、その並びで認識されやすくなる。
  List<String> get grammar {
    final phrases = <String>{...cues};
    for (final s in [destination, ...approach]) {
      phrases.add(s.vosk);
      for (final cue in cues) {
        phrases.add('$cue ${s.vosk}');
      }
    }
    for (final s in decoys) {
      phrases.add(s.vosk);
    }
    phrases.add('[unk]');
    return phrases.toList();
  }
}

/// 認識結果から、知らせるべきアナウンスを見つける。
class StationAnnouncementDetector {
  StationAnnouncementDetector(
    this.plan, {
    this.cueWindow = const Duration(seconds: 4),
    this.repeatGuard = const Duration(seconds: 90),
    this.repeatWindow = const Duration(seconds: 45),
  });

  final StationAlarmPlan plan;

  /// 「次は」と駅名が別々の結果に分かれたときに、つなげてよい間隔。
  final Duration cueWindow;

  /// 同じ知らせを繰り返さない間隔。アナウンスは同じ内容が2回流れる
  /// （日本語と英語、または停車前と停車直前）ことが多い。
  final Duration repeatGuard;

  /// 同じ駅名が別々の結果で2回聞こえたら知らせる、その間隔
  /// （allowRepeated のときだけ）。
  final Duration repeatWindow;

  /// 駅コード → その駅名が聞こえた時刻（repeatWindow の間だけ持つ）。
  final Map<int, List<DateTime>> _heardAt = {};

  DateTime? _cueAt;
  final Map<String, DateTime> _lastNotified = {};
  bool _arrived = false;

  /// 目的の駅に着いたと判定したか。
  bool get arrived => _arrived;

  /// Vosk の認識結果（空白区切りの語）を1件渡す。
  /// 知らせることがあればイベントを返す。
  ///
  /// [allowRepeated] は、GPS で降りる駅の近くにいると分かっているときに
  /// true にする。「次は」が無くても、駅名の繰り返しで知らせるようになる。
  StationAlarmEvent? onResult(
    String text, {
    DateTime? at,
    bool allowRepeated = false,
  }) {
    final now = at ?? DateTime.now();
    final tokens = _tokens(text);
    if (tokens.isEmpty) return null;

    final cueBefore = _cueAt != null && now.difference(_cueAt!) <= cueWindow;
    // 結果の最後が「次は」なら、続きは次の結果に来る
    _cueAt = _endsWithCue(tokens) ? now : null;

    final claims = _claim(tokens);
    _rememberHeard(claims, now);

    // 目的の駅を優先して調べる
    final dest = plan.destination;
    if (_announced(tokens, claims, dest, cueBefore)) {
      return _notify(StationAlarmStage.arriving, dest, text, now);
    }
    if (!_arrived) {
      for (final s in plan.approach) {
        if (_announced(tokens, claims, s, cueBefore)) {
          return _notify(StationAlarmStage.approaching, s, text, now);
        }
      }
    }

    if (!allowRepeated) return null;
    if (_heardRepeatedly(dest)) {
      return _notify(StationAlarmStage.arriving, dest, text, now);
    }
    if (_arrived) return null; // 着いた後の隣の駅は知らせない
    for (final s in plan.approach) {
      if (_heardRepeatedly(s)) {
        return _notify(StationAlarmStage.approaching, s, text, now);
      }
    }
    return null;
  }

  /// 目的の駅と隣の駅について、聞こえた時刻を覚える。古いものは捨てる。
  void _rememberHeard(Map<int, List<int>> claims, DateTime now) {
    for (final s in [plan.destination, ...plan.approach]) {
      final list = _heardAt[s.code];
      if (list != null) {
        list.removeWhere((t) => now.difference(t) > repeatWindow);
      }
      final hits = claims[s.code];
      if (hits == null) continue;
      (_heardAt[s.code] ??= []).addAll(List.filled(hits.length, now));
    }
  }

  bool _heardRepeatedly(Station station) =>
      (_heardAt[station.code]?.length ?? 0) >= 2;

  /// 文法のすべての駅名について、どこに現れたかを決める。
  ///
  /// 長い駅名から先に場所を取る。目的の駅が「なかの」のとき、
  /// 「ひがし なかの」（東中野）の後ろ半分を中野と数えないようにするため。
  /// 戻り値は 駅コード → 現れた位置 のリスト。
  Map<int, List<int>> _claim(List<String> tokens) {
    final taken = List<bool>.filled(tokens.length, false);
    final out = <int, List<int>>{};
    for (final (station, name) in _allNames) {
      for (final i in _positions(tokens, name)) {
        var free = true;
        for (var j = i; j < i + name.length; j++) {
          if (taken[j]) {
            free = false;
            break;
          }
        }
        if (!free) continue;
        for (var j = i; j < i + name.length; j++) {
          taken[j] = true;
        }
        (out[station.code] ??= []).add(i);
      }
    }
    return out;
  }

  /// 文法の駅名を、語数の多い順に並べたもの。
  late final List<(Station, List<String>)> _allNames = [
    for (final s in {plan.destination, ...plan.approach, ...plan.decoys})
      (s, _tokens(s.vosk)),
  ]..sort((a, b) => b.$2.length.compareTo(a.$2.length));

  /// 次の乗車に向けて状態を戻す。
  void reset() {
    _cueAt = null;
    _lastNotified.clear();
    _heardAt.clear();
    _arrived = false;
  }

  StationAlarmEvent? _notify(
    StationAlarmStage stage,
    Station station,
    String heard,
    DateTime now,
  ) {
    final key = '${stage.name}:${station.code}';
    final last = _lastNotified[key];
    if (last != null && now.difference(last) < repeatGuard) return null;
    _lastNotified[key] = now;
    if (stage == StationAlarmStage.arriving) _arrived = true;
    return StationAlarmEvent(
      stage: stage,
      station: station,
      heard: heard,
      at: now,
    );
  }

  /// 駅名が「アナウンスとして」言われたか。
  bool _announced(
    List<String> tokens,
    Map<int, List<int>> claims,
    Station station,
    bool cueBefore,
  ) {
    final hits = claims[station.code] ?? const <int>[];
    if (hits.isEmpty) return false;

    // 「新宿、新宿」と2回
    if (hits.length >= 2) return true;

    for (final i in hits) {
      // 直前に「次は」「まもなく」
      if (_cueEndsAt(tokens, i)) return true;
      // 前の結果が「次は」で終わっていて、この結果の頭が駅名
      if (i == 0 && cueBefore) return true;
    }
    return false;
  }

  /// tokens[end] の直前が決まり文句で終わっているか。
  bool _cueEndsAt(List<String> tokens, int end) {
    for (final cue in StationAlarmPlan.cues) {
      final c = _tokens(cue);
      final start = end - c.length;
      if (start < 0) continue;
      var ok = true;
      for (var j = 0; j < c.length; j++) {
        if (tokens[start + j] != c[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }

  bool _endsWithCue(List<String> tokens) => _cueEndsAt(tokens, tokens.length);
}

/// 語に分ける。[unk]（文法に無い言葉）は除く。
///
/// 「次は、えー、新宿」のように間に余計な音が入ると [unk] が挟まるが、
/// 除いておけば「つぎ は しん じゅく」として判定できる。
List<String> _tokens(String text) => text
    .split(RegExp(r'\s+'))
    .where((t) => t.isNotEmpty && t != '[unk]')
    .toList();

/// [tokens] の中で [want] が続けて現れる位置。
List<int> _positions(List<String> tokens, List<String> want) {
  final out = <int>[];
  if (want.isEmpty) return out;
  for (var i = 0; i + want.length <= tokens.length; i++) {
    var ok = true;
    for (var j = 0; j < want.length; j++) {
      if (tokens[i + j] != want[j]) {
        ok = false;
        break;
      }
    }
    if (ok) {
      out.add(i);
      i += want.length - 1; // 重なりは数えない
    }
  }
  return out;
}
