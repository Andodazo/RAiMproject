// lib/services/planner/planner_notifications.dart
//
// 予定の知らせを、端末の通知として予約する（スマホ・Windows）。
//
// 【なぜ端末で予約するか】
// サーバーから知らせると Lambda を増やすことになる。iPhone はアプリを決まった時刻に
// 起こせないので、どのみち通知は端末に予約しておく必要がある（安藤さんと決めた）。
// 予定が変わるたび（一覧を読み直すたび）に、全部消して入れ直す。
//
// 【Windows】
// アプリが動いていれば、時刻の少し前に planner_reminder_runner.dart が予約を取り消して、
// ライムがその場で一言話す。アプリを閉じていれば、予約した通知がそのまま出る。

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:raim_prototype/services/app_notifications.dart';
import 'package:raim_prototype/services/planner/planner_schedule.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// 通知の予約を差し替えられるようにする（テストでは偽物を使う）
abstract class PlannerNotifier {
  /// 前に予約した分を消して、[reminders] を予約し直す
  Future<void> replaceAll(List<PlannerReminder> reminders);

  /// 1件だけ取り消す（Windows でライムがその場で話すとき）
  Future<void> cancel(PlannerReminder reminder);

  /// すぐに出す（Windows でライムの一言が作れなかったとき）
  Future<void> showNow(PlannerReminder reminder);

  /// 全部消す（ログアウトしたとき）
  Future<void> clear();
}

class PlannerNotifications implements PlannerNotifier {
  PlannerNotifications();

  static const String _prefsKey = 'planner.scheduledIds';

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'planner_reminder',
      '予定の知らせ',
      channelDescription: 'ライムが予定の前の日の夜や1時間前に知らせる',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
    ),
    windows: WindowsNotificationDetails(),
  );

  FlutterLocalNotificationsPlugin get _plugin => AppNotifications.plugin;

  @override
  Future<void> replaceAll(List<PlannerReminder> reminders) async {
    if (!await AppNotifications.ensureInitialized()) return;
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getStringList(_prefsKey) ?? const [];
    for (final raw in previous) {
      final id = int.tryParse(raw);
      if (id == null || !PlannerSchedule.isPlannerId(id)) continue;
      await _cancelId(id);
    }

    final scheduled = <String>[];
    for (final reminder in reminders) {
      try {
        await _plugin.zonedSchedule(
          id: reminder.id,
          title: reminder.title,
          body: reminder.body,
          payload: reminder.payload,
          scheduledDate: tz.TZDateTime.from(reminder.at, tz.UTC),
          notificationDetails: _details,
          // 正確な時刻のアラームは許可が要るので使わない（数分ずれてもよい）
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
        scheduled.add('${reminder.id}');
      } catch (e) {
        // 1件だめでも、ほかは予約する（過ぎた時刻など）
        RaimLog.w('[PlannerNotify] 予約できませんでした: ${e.runtimeType}');
      }
    }
    await prefs.setStringList(_prefsKey, scheduled);
    RaimLog.d('[PlannerNotify] 予約し直しました: ${scheduled.length}件');
  }

  @override
  Future<void> cancel(PlannerReminder reminder) async {
    if (!await AppNotifications.ensureInitialized()) return;
    await _cancelId(reminder.id);
  }

  @override
  Future<void> showNow(PlannerReminder reminder) async {
    if (!await AppNotifications.ensureInitialized()) return;
    try {
      await _plugin.show(
        id: reminder.id,
        title: reminder.title,
        body: reminder.body,
        payload: reminder.payload,
        notificationDetails: _details,
      );
    } catch (e) {
      RaimLog.w('[PlannerNotify] 通知を出せませんでした: ${e.runtimeType}');
    }
  }

  @override
  Future<void> clear() => replaceAll(const []);

  Future<void> _cancelId(int id) async {
    try {
      await _plugin.cancel(id: id);
    } catch (_) {
      // 消せなくても困らない（Windows は出したあとの通知を消せないことがある）
    }
  }
}
