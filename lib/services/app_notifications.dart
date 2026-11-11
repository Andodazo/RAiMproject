// lib/services/app_notifications.dart
//
// 端末の通知（flutter_local_notifications）の準備を1か所にまとめる。
//
// 【なぜ要るか】
// 駅アラーム（station_notifications.dart）と予定の知らせ（planner_notifications.dart）が
// 同じプラグインを使う。プラグインの initialize は最後に呼んだものが勝つので、
// 別々に呼ぶと、片方の「通知を押したとき」の受け取りが消えてしまう。
// ここで1回だけ準備して、押された通知の中身を [taps] に流す。
//
// 【通知のボタン】（タイマーの「止める」「5分後にもう一回」）
// ボタンが押されたら [actions] に流す（[taps] には流さない）。
//   - 「止める」は通知を消すだけ。アプリを開かない（裏で何もしない受け口を置く）
//   - 「5分後にもう一回」はアプリを開いてから、5分後の通知を予約する
// Windows はボタンの arguments が payload として戻ってくるので、
// 「payload#ボタンの ID」の形にしておいて、ここで分ける。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:raim_prototype/services/raim_log.dart';

/// 通知のボタンが押された
class AppNotificationAction {
  const AppNotificationAction({required this.payload, required this.actionId});

  final String payload;
  final String actionId;
}

/// 「止める」など、アプリを開かないボタンが押されたとき（裏で動く）。
/// 通知はプラグインが消すので、ここでは何もしない。
@pragma('vm:entry-point')
void appNotificationBackgroundResponse(NotificationResponse response) {}

class AppNotifications {
  AppNotifications._();

  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();

  static Future<bool>? _initializing;

  static final StreamController<String> _taps =
      StreamController<String>.broadcast();

  static final StreamController<AppNotificationAction> _actions =
      StreamController<AppNotificationAction>.broadcast();

  /// 押された通知の payload。アプリが動いている間に押されたもの
  static Stream<String> get taps => _taps.stream;

  /// 押された通知のボタン。アプリが動いている間に押されたもの
  static Stream<AppNotificationAction> get actions => _actions.stream;

  /// 通知を押してアプリが起動したときの payload（1回読んだら消える）
  static String? _launchPayload;

  /// 通知のボタンを押してアプリが起動したとき（1回読んだら消える）
  static AppNotificationAction? _launchAction;

  /// タイマーの通知（iPhone はボタンの組を先に登録しておく）
  static const String timerCategoryId = 'planner_timer';
  static const String stopActionId = 'stop';
  static const String snoozeActionId = 'snooze';

  /// 通知の返事を、本文が押されたのか、ボタンが押されたのかに分ける
  @visibleForTesting
  static ({String payload, String? actionId})? parseResponse(
    String? payload,
    String? actionId,
  ) {
    if (payload == null || payload.isEmpty) return null;
    // Windows: ボタンの arguments「payload#ボタン」が payload と actionId の両方に入る
    final hash = payload.lastIndexOf('#');
    if (hash > 0) {
      final id = payload.substring(hash + 1);
      return (payload: payload.substring(0, hash), actionId: id.isEmpty ? null : id);
    }
    final hasAction = actionId != null && actionId.isNotEmpty && actionId != payload;
    return (payload: payload, actionId: hasAction ? actionId : null);
  }

  /// Windows のボタンに入れる arguments
  static String windowsActionArguments(String payload, String actionId) =>
      '$payload#$actionId';

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
        settings: InitializationSettings(
          android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
          // 許可は使う場面で聞く（起動直後にいきなり聞かない）
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestSoundPermission: false,
            requestBadgePermission: false,
            notificationCategories: [
              DarwinNotificationCategory(
                timerCategoryId,
                actions: [
                  DarwinNotificationAction.plain(stopActionId, '止める'),
                  DarwinNotificationAction.plain(
                    snoozeActionId,
                    '5分後にもう一回',
                    options: {DarwinNotificationActionOption.foreground},
                  ),
                ],
              ),
            ],
          ),
          windows: const WindowsInitializationSettings(
            appName: 'RAiM',
            appUserModelId: windowsAppUserModelId,
            guid: windowsGuid,
          ),
        ),
        onDidReceiveNotificationResponse: (response) {
          final parsed = parseResponse(response.payload, response.actionId);
          if (parsed == null) return;
          final actionId = parsed.actionId;
          if (actionId != null) {
            if (!_actions.isClosed) {
              _actions.add(AppNotificationAction(payload: parsed.payload, actionId: actionId));
            }
          } else if (!_taps.isClosed) {
            _taps.add(parsed.payload);
          }
        },
        onDidReceiveBackgroundNotificationResponse: appNotificationBackgroundResponse,
      );
      final launch = await plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        final response = launch?.notificationResponse;
        final parsed = parseResponse(response?.payload, response?.actionId);
        final actionId = parsed?.actionId;
        if (parsed != null && actionId != null) {
          _launchAction = AppNotificationAction(payload: parsed.payload, actionId: actionId);
        } else {
          _launchPayload = parsed?.payload;
        }
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

  /// 通知のボタンを押して起動したときのボタンを受け取る（2回目からは null）
  static AppNotificationAction? takeLaunchAction() {
    final action = _launchAction;
    _launchAction = null;
    return action;
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
