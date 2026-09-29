// lib/services/station/ride_foreground_service.dart
//
// 乗車モードの間、画面を消してもマイクを聞き続けるための
// Android のフォアグラウンドサービス。
//
// 【なぜ要るか】
// Android は、アプリが裏に回るとマイクを使えなくする（Android 11 以降）。
// 「マイク用のフォアグラウンドサービス」を動かしている間だけ、裏でも録音できる。
// サービスが動いている間は通知が出続け、ユーザーからも分かる。
//
// 【仕組み】
// サービス自体は何もしない（TaskHandler は空）。サービスがあることで
// アプリのプロセスが生き続け、今までどおり画面側（メインの isolate）の
// Vosk とマイクが動き続ける。CPU が眠らないよう WakeLock も取る。
//
// 【知らせ方】
// サービスの通知を「重要度: 高」の通道で出し、内容を書き換えるたびに
// 音とバイブで知らせる。通知のライブラリを別に足さずに済む
// （flutter_local_notifications は Gradle の追加設定が要るため）。
// 乗車中に書き換えるのは「もうすぐ」「着く」の2回だけ。

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:raim_prototype/services/raim_log.dart';

/// サービスが呼ぶ入口。トップレベル関数でなければならない。
@pragma('vm:entry-point')
void rideTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_RideTaskHandler());
}

class _RideTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  /// 通知を押したらアプリを前に出す。
  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}

class RideForegroundService {
  RideForegroundService._();

  static const int _serviceId = 7101;
  static bool _initialized = false;

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static void _init() {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'station_alarm',
        channelName: '駅アラーム',
        channelDescription: '乗車中の表示と、降りる駅が近づいたときの知らせ',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
        enableVibration: true,
        playSound: true,
        // 書き換えるたびに鳴らす（「もうすぐ」「着く」を知らせるため）
        onlyAlertOnce: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: true,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        // アプリを履歴から消したら止める（マイクを開いたまま残さない）
        stopWithTask: true,
      ),
    );
  }

  /// サービスを始める。始められなければ false。
  ///
  /// 通知の許可が無ければここで求める（Android 13 以降）。
  /// 許可されなくてもサービスは動くが、通知が出ないので知らせに気づけない。
  static Future<bool> start({
    required String title,
    required String text,
  }) async {
    if (!isSupported) return false;
    _init();

    final permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (await FlutterForegroundTask.isRunningService) {
      await update(title: title, text: text);
      return true;
    }

    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: const [ForegroundServiceTypes.microphone],
      notificationTitle: title,
      notificationText: text,
      callback: rideTaskCallback,
    );
    if (result is ServiceRequestFailure) {
      RaimLog.e('[Ride] フォアグラウンドサービスを始められませんでした', result.error);
      return false;
    }
    RaimLog.i('[Ride] フォアグラウンドサービスを開始しました');
    return true;
  }

  /// 通知の内容を書き換える（音とバイブが鳴る）。
  static Future<void> update({
    required String title,
    required String text,
  }) async {
    if (!isSupported || !await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  static Future<void> stop() async {
    if (!isSupported || !await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.stopService();
    RaimLog.i('[Ride] フォアグラウンドサービスを終了しました');
  }
}
