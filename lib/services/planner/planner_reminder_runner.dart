// lib/services/planner/planner_reminder_runner.dart
//
// Windows で、予定を知らせる時刻にライムがその場で一言話す。
//
// 【流れ】（安藤さんと決めた）
//   アプリが動いている → 時刻の少し前に、予約した通知を取り消して、
//                        サーバーで一言作ってもらい、吹き出しと声で話す。
//                        作れなかったら、保存しておいた文で通知を出す。
//   ロック中・スリープ中 → 喋らない。予約した通知がそのまま出る。
//   アプリを閉じている  → 予約した通知がそのまま出る（ここは動いていない）。
//
// スリープから戻ったときなど、時刻を大きく過ぎてから動いたときは喋らない
// （古い知らせをいきなり話し出さないように）。

import 'dart:async';

import 'package:raim_prototype/services/planner/planner_notifications.dart';
import 'package:raim_prototype/services/planner/planner_schedule.dart';
import 'package:raim_prototype/services/raim_log.dart';

class PlannerReminderRunner {
  PlannerReminderRunner({
    required this.notifier,
    required this.speak,
    required this.isLocked,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PlannerNotifier notifier;

  /// ライムに一言話してもらう。話せたら true
  final Future<bool> Function(PlannerReminder reminder) speak;

  /// 画面がロックされているか
  final bool Function() isLocked;

  final DateTime Function() _clock;

  /// 時刻のどれだけ前に動くか（予約した通知が先に出ないように）
  static const Duration lead = Duration(seconds: 20);

  /// これより遅れて動いたら喋らない
  static const Duration tooLate = Duration(minutes: 2);

  List<PlannerReminder> _reminders = const [];
  Timer? _timer;
  final Set<int> _done = {};

  /// 知らせの一覧が変わったら呼ぶ
  void update(List<PlannerReminder> reminders) {
    _reminders = reminders;
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    final now = _clock().toUtc();
    PlannerReminder? next;
    for (final r in _reminders) {
      if (_done.contains(r.id)) continue;
      if (r.at.isBefore(now.subtract(tooLate))) continue;
      next = r;
      break;
    }
    if (next == null) return;
    var wait = next.at.subtract(lead).difference(now);
    if (wait.isNegative) wait = Duration.zero;
    final target = next;
    _timer = Timer(wait, () => unawaited(fire(target)));
  }

  /// 時刻が来た（テストからも呼ぶ）
  Future<void> fire(PlannerReminder reminder) async {
    _done.add(reminder.id);
    try {
      final late = _clock().toUtc().difference(reminder.at);
      if (late > tooLate) {
        RaimLog.d('[PlannerRunner] 時刻を過ぎていたので喋りません');
        return;
      }
      if (isLocked()) {
        RaimLog.d('[PlannerRunner] ロック中なので通知だけにします');
        return;
      }
      await notifier.cancel(reminder);
      var spoke = false;
      try {
        spoke = await speak(reminder);
      } catch (e) {
        RaimLog.w('[PlannerRunner] 一言を作れませんでした: ${e.runtimeType}');
      }
      if (!spoke) await notifier.showNow(reminder);
    } finally {
      _arm();
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
