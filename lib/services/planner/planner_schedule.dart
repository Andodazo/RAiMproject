// lib/services/planner/planner_schedule.dart
//
// 予定を「いつ・何と」知らせるかを決める（端末の通知を予約する前の計算だけ）。
//
// 【決めたこと】（安藤さんと決めた）
//   時刻のある予定 … 前の日の 21:00 と、1時間前
//   日付だけの予定 … 当日の朝 8:00 だけ（8:00 は仮）
//
// 日付と時刻は日本時間で決まっているので、日本時間として時刻を出す。
// 通知の文は、サーバーの LLM が作った文（lines）を基本にして、無ければ決まり文句。
// LLM の文には「明日」などを入れさせていないので、日時はここで足す。

import 'package:raim_prototype/models/planner_item.dart';

/// 知らせる時刻の種類
class PlannerSlot {
  static const eve = 'eve';
  static const before = 'before';
  static const morning = 'morning';
}

/// 1回分の知らせ
class PlannerReminder {
  const PlannerReminder({
    required this.id,
    required this.itemId,
    required this.slot,
    required this.at,
    required this.title,
    required this.body,
  });

  /// 端末の通知の ID（予定と時刻の種類から決まる。予約し直しても同じ）
  final int id;
  final String itemId;
  final String slot;

  /// 知らせる時刻（UTC）
  final DateTime at;

  /// 通知のタイトル（「ライム」）
  final String title;

  /// 通知の本文（保存しておいた文 + 日時）
  final String body;

  /// 通知を押したときに戻ってくる中身
  String get payload => 'planner:$itemId:$slot';

  /// [payload] を読む。予定の通知でなければ null
  static ({String itemId, String slot})? parsePayload(String? payload) {
    if (payload == null || !payload.startsWith('planner:')) return null;
    final parts = payload.split(':');
    if (parts.length != 3) return null;
    if (!const [PlannerSlot.eve, PlannerSlot.before, PlannerSlot.morning]
        .contains(parts[2])) {
      return null;
    }
    return (itemId: parts[1], slot: parts[2]);
  }
}

class PlannerSchedule {
  PlannerSchedule._();

  /// 前の日の夜に知らせる時刻（日本時間）
  static const int eveHour = 21;

  /// 日付だけの予定を知らせる時刻（日本時間）
  static const int morningHour = 8;

  /// 何分前に知らせるか
  static const Duration beforeLead = Duration(hours: 1);

  /// 予約しておく数の上限。iOS は1つのアプリで64件までしか予約できない
  /// （駅アラームの分を残しておく）。
  static const int maxPending = 48;

  static const Duration _jstOffset = Duration(hours: 9);

  /// 通知のタイトル
  static const String notificationTitle = 'ライム';

  /// 日本時間の日付・時刻を UTC の時刻に
  static DateTime jstToUtc(String date, int hour, int minute) {
    final d = parsePlannerDate(date)!;
    return DateTime.utc(d.year, d.month, d.day, hour, minute).subtract(_jstOffset);
  }

  /// 予定1件の知らせ（[now] より後のものだけ）
  static List<PlannerReminder> remindersFor(PlannerItem item, DateTime now) {
    if (!item.isEvent || parsePlannerDate(item.date) == null) return const [];
    final out = <PlannerReminder>[];
    void add(String slot, DateTime at) {
      if (!at.isAfter(now)) return;
      out.add(PlannerReminder(
        id: notificationId(item.itemId, slot),
        itemId: item.itemId,
        slot: slot,
        at: at,
        title: notificationTitle,
        body: bodyFor(item, slot),
      ));
    }

    final time = normalizePlannerTime(item.time);
    if (time != null && time.isNotEmpty) {
      final hm = time.split(':').map(int.parse).toList();
      final start = jstToUtc(item.date, hm[0], hm[1]);
      final dayBefore = parsePlannerDate(item.date)!.subtract(const Duration(days: 1));
      add(PlannerSlot.eve, jstToUtc(plannerDateString(dayBefore), eveHour, 0));
      add(PlannerSlot.before, start.subtract(beforeLead));
    } else {
      add(PlannerSlot.morning, jstToUtc(item.date, morningHour, 0));
    }
    return out;
  }

  /// 全部の予定の知らせ（早い順、[maxPending] 件まで）
  static List<PlannerReminder> remindersForAll(
    Iterable<PlannerItem> items,
    DateTime now,
  ) {
    final all = [for (final item in items) ...remindersFor(item, now)]
      ..sort((a, b) => a.at.compareTo(b.at));
    return all.length > maxPending ? all.sublist(0, maxPending) : all;
  }

  /// 保存しておいた文（無ければ決まり文句）に、日時を足した本文
  static String bodyFor(PlannerItem item, String slot) {
    final line = lineFor(item, slot);
    final when = switch (slot) {
      PlannerSlot.eve => '明日${item.hasTime ? ' ${item.time}' : ''}',
      PlannerSlot.before => item.time,
      _ => '今日',
    };
    return '$line（$when ${item.title}）';
  }

  /// 保存しておいた文。無ければ決まり文句（サーバーの planner-writer.js と同じ）
  static String lineFor(PlannerItem item, String slot) {
    final stored = item.lines[slot];
    if (stored != null && stored.isNotEmpty) return stored;
    return templateLine(slot, item.title);
  }

  static String templateLine(String slot, String title) => switch (slot) {
        PlannerSlot.eve => '$titleの準備、できてる？',
        PlannerSlot.before => 'そろそろ$titleだよ。いってらっしゃい',
        _ => '$titleの日だよ。忘れないでね',
      };

  /// 予定と時刻の種類から、端末の通知の ID を決める。
  ///
  /// 駅アラームの通知（7201, 7202）と重ならないよう、0x10000000 から上を使う。
  static int notificationId(String itemId, String slot) {
    // FNV-1a（32bit）。同じ入力なら、どの端末・いつ計算しても同じになる
    var hash = 0x811c9dc5;
    for (final unit in '$itemId|$slot'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return 0x10000000 + (hash & 0x0FFFFFFF);
  }

  /// 通知の ID が予定のものか（予約し直すときに、予定の分だけ消すため）
  static bool isPlannerId(int id) => id >= 0x10000000 && id < 0x20000000;
}
