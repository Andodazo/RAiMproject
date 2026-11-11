// lib/services/app_notifications.dart
//
// 端末の通知（flutter_local_notifications）の準備を1か所にまとめる。
//
// 【なぜ要るか】
// 駅アラーム（station_notifications.dart）と予定の知らせ（planner_notifications.dart）が
// 同じプラグインを使う。プラグインの initialize は最後に呼んだものが勝つので、
// 別々に呼ぶと、片方の「通知を押したとき」の受け取りが消えてしまう。
// ここで1回だけ準備して、押された通知の中身を [taps] に流す。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:raim_prototype/services/raim_log.dart';

class AppNotifications {
  AppNotifications._();

  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();

  static Future<bool>? _initializing;

  static final StreamController<String> _taps =
      StreamController<String>.broadcast();

  /// 押された通知の payload。アプリが動いている間に押されたもの
  static Stream<String> get taps => _taps.stream;

  /// 通知を押してアプリが起動したときの payload（1回読んだら消える）
  static String? _launchPayload;

  /// 通知を出せる端末か（Windows・iPhone・Android）
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isWindows);

  /// Windows の通知に使う ID。変えると、前に予約した通知を消せなくなる
  static const String windowsAppUserModelId = 'RAiM.RAiM.Desktop';
  static const String windowsGuid = '6b0d1d5e-3c8f-4f0a-9d7e-2a6f2c41b7a3';

  /// 1回だけ準備する。準備できなければ false（通知は出せないが、アプリは続ける）
  static Future<bool> ensureInitialized() {
    if (!isSupported) return Future.value(false);
    return _initializing ??= _init();
  }

  static Future<bool> _init() async {
    try {
      await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          // 許可は使う場面で聞く（起動直後にいきなり聞かない）
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestSoundPermission: false,
            requestBadgePermission: false,
          ),
          windows: WindowsInitializationSettings(
            appName: 'RAiM',
            appUserModelId: windowsAppUserModelId,
            guid: windowsGuid,
          ),
        ),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload != null && payload.isNotEmpty && !_taps.isClosed) {
            _taps.add(payload);
          }
        },
      );
      final launch = await plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        _launchPayload = launch?.notificationResponse?.payload;
      }
      return true;
    } catch (e) {
      RaimLog.w('[Notify] 通知の準備ができませんでした: ${e.runtimeType}');
      return false;
    }
  }

  /// 通知を押して起動したときの payload を受け取る（2回目からは null）
  static String? takeLaunchPayload() {
    final payload = _launchPayload;
    _launchPayload = null;
    return payload;
  }

  /// 通知の許可を求める。画面に出ている間に呼ぶ。Windows は聞かなくても出せる
  static Future<void> requestPermission() async {
    if (!await ensureInitialized()) return;
    try {
      if (Platform.isIOS) {
        await plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, sound: true);
      } else if (Platform.isAndroid) {
        await plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
    } catch (e) {
      RaimLog.w('[Notify] 通知の許可を確認できませんでした: ${e.runtimeType}');
    }
  }
}
