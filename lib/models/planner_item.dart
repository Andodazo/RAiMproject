// lib/models/planner_item.dart
//
// 予定とメモの1件（サーバーの RAiM-Planner-dev の項目）。
//
// 予定はサーバーに保存して、Windows とスマホで同じものを見る。
// 知らせる文（lines）は、予定を入れたときにサーバーの LLM が作ったもの。
// まだ作られていない（enriched=false）ときは、アプリの決まり文句を使う。
//
// 日付と時刻は日本時間の「YYYY-MM-DD」「HH:mm」の文字列のまま持つ。
// サーバーも日本時間で決めているので、端末の時間帯に合わせて変えない。

const List<String> _weekdays = ['月', '火', '水', '木', '金', '土', '日'];

class PlannerItem {
  const PlannerItem({
    required this.itemId,
    required this.kind,
    required this.title,
    required this.date,
    this.time = '',
    this.note = '',
    this.importance = 'normal',
    this.lines = const {},
    this.enriched = false,
    this.source = 'manual',
    this.updatedAt = '',
    this.endsAt,
    this.durationSec = 0,
  });

  /// 'ev_…' のような ID
  final String itemId;

  /// 'event'（予定）| 'timer'（タイマー）。メモはあとで足す
  final String kind;

  final String title;

  /// 日本時間の日付 YYYY-MM-DD（タイマーは空）
  final String date;

  /// 日本時間の時刻 HH:mm。決まっていなければ空
  final String time;

  final String note;

  /// 'important' | 'normal' | 'chore'
  final String importance;

  /// 知らせる文（'eve' 前の日の夜 / 'before' 1時間前 / 'morning' 当日の朝）
  final Map<String, String> lines;

  /// 知らせる文を LLM が作り終えたか
  final bool enriched;

  /// 'raim'（ライムに頼んだ）| 'manual'（手で足した）| 'suggest'（「予定に入れる？」）
  final String source;

  final String updatedAt;

  /// タイマーが鳴る時刻（UTC）。予定は null
  final DateTime? endsAt;

  /// タイマーの長さ（秒）
  final int durationSec;

  bool get isEvent => kind == 'event';
  bool get isTimer => kind == 'timer';
  bool get hasTime => time.isNotEmpty;

  /// タイマーがまだ鳴っていないか
  bool isRunningAt(DateTime now) => isTimer && endsAt != null && endsAt!.isAfter(now);

  /// 「11/14(土)」
  String get dateLabel => formatPlannerDate(date);

  /// 「11/14(土) 10:00」。タイマーは「15:03 に鳴る」
  String get whenLabel {
    if (isTimer) return endsAt == null ? 'タイマー' : '${formatJstClock(endsAt!)} に鳴る';
    return hasTime ? '$dateLabel $time' : dateLabel;
  }

  /// タイマーの長さ「3分」「1時間30分」「45秒」
  String get durationLabel => formatTimerDuration(durationSec);

  factory PlannerItem.fromJson(Map<String, dynamic> json) {
    String str(Object? v) => v is String ? v : (v == null ? '' : v.toString());
    final rawLines = json['lines'];
    final lines = <String, String>{};
    if (rawLines is Map) {
      for (final key in const ['eve', 'before', 'morning']) {
        final value = rawLines[key];
        if (value is String && value.trim().isNotEmpty) lines[key] = value.trim();
      }
    }
    return PlannerItem(
      itemId: str(json['itemId']),
      kind: str(json['kind']).isEmpty ? 'event' : str(json['kind']),
      title: str(json['title']),
      date: str(json['date']),
      time: str(json['time']),
      note: str(json['note']),
      importance: str(json['importance']).isEmpty ? 'normal' : str(json['importance']),
      lines: lines,
      enriched: json['enriched'] == true,
      source: str(json['source']).isEmpty ? 'manual' : str(json['source']),
      updatedAt: str(json['updatedAt']),
      endsAt: DateTime.tryParse(str(json['endsAt']))?.toUtc(),
      durationSec: json['durationSec'] is num ? (json['durationSec'] as num).toInt() : 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'kind': kind,
        'title': title,
        'date': date,
        'time': time,
        'note': note,
        'importance': importance,
        'lines': lines,
        'enriched': enriched,
        'source': source,
        'updatedAt': updatedAt,
        if (endsAt != null) 'endsAt': endsAt!.toUtc().toIso8601String(),
        if (durationSec > 0) 'durationSec': durationSec,
      };

  /// 並べる順（タイマーが先で鳴る順 → 予定は日付 → 時刻。時刻なしはその日の先頭）
  static int compare(PlannerItem a, PlannerItem b) {
    if (a.isTimer != b.isTimer) return a.isTimer ? -1 : 1;
    if (a.isTimer) {
      final ae = a.endsAt, be = b.endsAt;
      if (ae != null && be != null) return ae.compareTo(be);
      return a.itemId.compareTo(b.itemId);
    }
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    return a.time.compareTo(b.time);
  }
}

/// 「予定に入れる？」の中身（話に出ただけの予定）
class PlannerCandidate {
  const PlannerCandidate({required this.title, required this.date, this.time = ''});

  final String title;
  final String date;
  final String time;

  String get whenLabel {
    final d = formatPlannerDate(date);
    return time.isEmpty ? d : '$d $time';
  }

  static PlannerCandidate? fromJson(Object? json) {
    if (json is! Map) return null;
    final title = json['title'];
    final date = json['date'];
    if (title is! String || title.trim().isEmpty) return null;
    if (date is! String || !isPlannerDate(date)) return null;
    final time = json['time'];
    return PlannerCandidate(
      title: title.trim(),
      date: date,
      time: time is String ? time : '',
    );
  }
}

/// YYYY-MM-DD として正しいか
bool isPlannerDate(String value) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (m == null) return false;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  final dt = DateTime.utc(y, mo, d);
  return dt.year == y && dt.month == mo && dt.day == d;
}

/// 「YYYY-MM-DD」を DateTime（UTC の0時。曜日と日数の計算用）に
DateTime? parsePlannerDate(String value) {
  if (!isPlannerDate(value)) return null;
  final parts = value.split('-').map(int.parse).toList();
  return DateTime.utc(parts[0], parts[1], parts[2]);
}

/// DateTime（年月日だけ見る）を「YYYY-MM-DD」に
String plannerDateString(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// 「11/14(土)」
String formatPlannerDate(String value) {
  final d = parsePlannerDate(value);
  if (d == null) return value;
  return '${d.month}/${d.day}(${_weekdays[d.weekday - 1]})';
}

/// UTC の時刻を日本時間の「HH:mm」に
String formatJstClock(DateTime utc) {
  final jst = utc.toUtc().add(const Duration(hours: 9));
  return '${jst.hour.toString().padLeft(2, '0')}:${jst.minute.toString().padLeft(2, '0')}';
}

/// タイマーの長さ「3分」「1時間30分」「45秒」「1分30秒」
String formatTimerDuration(int seconds) {
  if (seconds <= 0) return '';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final parts = <String>[
    if (h > 0) '$h時間',
    if (m > 0) '$m分',
    if (s > 0 && h == 0) '$s秒',
  ];
  return parts.join();
}

/// 「10時」「9:5」なども受けて「HH:mm」に。空なら ''、読めなければ null。
String? normalizePlannerTime(String value) {
  final text = value.trim().replaceAllMapped(
        RegExp('[０-９：]'),
        (m) => m[0] == '：'
            ? ':'
            : String.fromCharCode(m[0]!.codeUnitAt(0) - 0xFEE0),
      );
  if (text.isEmpty) return '';
  final m = RegExp(r'^(\d{1,2})(?::(\d{1,2})|時(?:(\d{1,2})分?)?)?$').firstMatch(text);
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final min = int.tryParse(m.group(2) ?? m.group(3) ?? '0') ?? 0;
  if (h > 23 || min > 59) return null;
  return '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
}

/// 予定を読んだり変えたりできるサービス。どれも、変えたあとの一覧を返す。
///
/// 画面と PlannerController のテストで偽物に差し替えられるよう、RaimServerService と分けている。
abstract class PlannerService {
  Future<List<PlannerItem>> fetchPlanner();

  Future<List<PlannerItem>> addPlannerEvent({
    required String title,
    required String date,
    String time = '',
    String note = '',
    String source = 'manual',
  });

  Future<List<PlannerItem>> updatePlannerEvent(
    String itemId,
    Map<String, String> changes,
  );

  Future<List<PlannerItem>> deletePlannerItem(String itemId);
}
