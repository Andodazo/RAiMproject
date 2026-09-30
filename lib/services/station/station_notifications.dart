// lib/services/station/station_notifications.dart
//
// 駅アラームの通知（フォアグラウンドサービスの通知とは別のもの）。
//
// 【なぜ要るか】
// Android はフォアグラウンドサービスの通知を書き換えて、音とバイブで知らせる。
// iOS にはその仕組みが無い。画面を消していると、バイブ（HapticFeedback）も
// 鳴らないので、通知を出さないと何も起きない。
//
// Android でも、アプリが裏にいる間はフォアグラウンドサービスを始められない
// （マイク・位置情報を使うサービスは、画面に出ている間に始める決まり）。
// そのときは「アプリを開いて」と知らせるのに使う。
//
// 【使う場面】
//   - iOS で、隣の駅・降りる駅のアナウンスを聞いたとき
//   - Android で、フォアグラウンドサービスが無いまま知らせるとき
//   - 乗車モードを始められないので、アプリを開いてほしいとき

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:raim_prototype/services/raim_log.dart';

class StationNotifications {
  StationNotifications._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  /// 駅に近づいた・着いたときの知らせ。
  static const int alertId = 7201;

  /// 「アプリを開いて」の知らせ。
  static const int openAppId = 7202;

  /// フォアグラウンドサービスの通知（ride_foreground_service.dart）とは
  /// チャンネルを分ける。あちらは「乗車中」の表示が主で、こちらは知らせが主。
  static const AndroidNotificationDetails _android = AndroidNotificationDetails(
    'station_alarm_alert',
    '駅アラームの知らせ',
    channelDescription: '降りる駅が近づいたとき・アプリを開いてほしいときの知らせ',
    importance: Importance.max,
    priority: Priority.high,
    playSound: true,
    enableVibration: true,
    category: AndroidNotificationCategory.alarm,
  );

  static const DarwinNotificationDetails _ios = DarwinNotificationDetails(
    presentAlert: true,
    presentBanner: true,
    presentList: true,
    presentSound: true,
  );

  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Future<void> _init() async {
    if (_initialized) return;
    _initialized = true;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // 許可は乗車モードを始めるときに聞く（requestPermission）。
        // 起動直後にいきなり聞かないようにするため。
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
      ),
    );
  }

  /// 通知の許可を求める。画面に出ている間（乗車モードを始めるとき）に呼ぶ。
  static Future<void> requestPermission() async {
    if (!isSupported) return;
    try {
      await _init();
      if (Platform.isIOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, sound: true);
      } else {
        await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
    } catch (e) {
      RaimLog.w('[StationNotify] 通知の許可を確認できませんでした: ${e.runtimeType}');
    }
  }

  /// 駅に近づいた・着いたことを知らせる。
  static Future<void> alert({required String title, required String body}) =>
      _show(alertId, title, body);

  /// アプリを開いてほしいことを知らせる。
  static Future<void> askToOpenApp({
    required String title,
    required String body,
  }) =>
      _show(openAppId, title, body);

  /// 出している知らせを消す。
  static Future<void> cancel(int id) async {
    if (!isSupported || !_initialized) return;
    try {
      await _plugin.cancel(id: id);
    } catch (_) {
      // 消せなくても困らない
    }
  }

  static Future<void> _show(int id, String title, String body) async {
    if (!isSupported) return;
    try {
      await _init();
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails:
            const NotificationDetails(android: _android, iOS: _ios),
      );
    } catch (e) {
      RaimLog.e('[StationNotify] 通知を出せませんでした', e.runtimeType);
    }
  }
}
