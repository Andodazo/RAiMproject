// lib/services/planner/device_calendar.dart
//
// スマホの「カレンダーにも入れる」（2026-11-13）。
//
// OS のカレンダーの追加画面を、予定の名前・日時・メモを入れた状態で開く。
// 入れるかどうかは、その画面でユーザーが決める。
// 一度写すだけで、あとで RAiM の予定を直しても消してもカレンダーには反映しない。
//
// Windows には出さない（OS のカレンダーに追加画面を開く決まった方法が無いため）。

import 'dart:io' show Platform;

import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:flutter/foundation.dart';

import 'package:raim_prototype/models/planner_item.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// 時刻のある予定の長さ（終わりの時刻は持っていないので1時間にしておく）
const Duration deviceCalendarEventLength = Duration(hours: 1);

/// このスマホで「カレンダーにも入れる」を出すか
bool get canAddToDeviceCalendar => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// カレンダーに渡す中身。OS の画面を開く前の形（テストで見るため分けている）
class DeviceCalendarEntry {
  const DeviceCalendarEntry({
    required this.title,
    required this.description,
    required this.start,
    required this.end,
    required this.allDay,
  });

  final String title;
  final String description;
  final DateTime start;
  final DateTime end;
  final bool allDay;
}

/// 予定からカレンダーの中身を作る。日付が読めなければ null。
///
/// 予定の日付・時刻は日本時間。時刻のある予定は日本時間の時刻として渡し、
/// 日付だけの予定はその日の終日にする。
DeviceCalendarEntry? deviceCalendarEntryFor(PlannerItem item) {
  final day = parsePlannerDate(item.date);
  if (day == null) return null;
  if (!item.hasTime) {
    final start = DateTime(day.year, day.month, day.day);
    return DeviceCalendarEntry(
      title: item.title,
      description: item.note,
      start: start,
      end: start,
      allDay: true,
    );
  }
  final parts = item.time.split(':');
  final hour = int.tryParse(parts.first);
  final minute = parts.length > 1 ? int.tryParse(parts[1]) : 0;
  if (hour == null || minute == null) return null;
  // 日本時間の時刻 → 世界の同じ瞬間
  final start = DateTime.utc(day.year, day.month, day.day, hour, minute)
      .subtract(const Duration(hours: 9));
  return DeviceCalendarEntry(
    title: item.title,
    description: item.note,
    start: start,
    end: start.add(deviceCalendarEventLength),
    allDay: false,
  );
}

/// OS のカレンダーの追加画面を開く。開けなかったら false。
Future<bool> openDeviceCalendarFor(PlannerItem item) async {
  final entry = deviceCalendarEntryFor(item);
  if (entry == null) return false;
  try {
    return await Add2Calendar.addEvent2Cal(Event(
      title: entry.title,
      description: entry.description.isEmpty ? null : entry.description,
      startDate: entry.start,
      endDate: entry.end,
      allDay: entry.allDay,
      timeZone: entry.allDay ? null : 'Asia/Tokyo',
    ));
  } catch (e) {
    RaimLog.d('[DeviceCalendar] 開けませんでした: ${e.runtimeType}');
    return false;
  }
}
