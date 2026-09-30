// lib/widgets/client_action_listener.dart
//
// ライムがアプリに頼んだ操作（client_action）を実行する。
//
// 「ねえライム、新宿で起こして」→ ライムが start_station_alarm を使う
// → client_action（station_alarm.start）が届く → ここで乗車モードを始めて、
// 駅アラームの画面を開く。ライムの返事（「新宿ね、起こすよ」）は
// いつもどおりチャットに出る。
//
// ChatProvider は画面を持たないので、実行は画面側のこのウィジェットで行う。
//
// 【アプリが裏にいるとき】
// 「新宿で起こして」と言ってすぐ画面を消すと、返事が届く頃にはアプリが裏にいる。
// 裏からは、マイク・位置情報を使うサービス（Android）や録音（iOS）を始められず、
// 位置情報の許可も聞けない。そのときは頼まれた内容を覚えておき、
// 「アプリを開いて」と通知して、画面に戻ったときに始める。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:raim_prototype/models/client_action.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/providers/station_alarm_controller.dart';
import 'package:raim_prototype/screens/station_alarm_screen.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/station/station_notifications.dart';

class ClientActionListener extends StatefulWidget {
  const ClientActionListener({super.key, required this.child});

  final Widget child;

  @override
  State<ClientActionListener> createState() => _ClientActionListenerState();
}

class _ClientActionListenerState extends State<ClientActionListener>
    with WidgetsBindingObserver {
  StreamSubscription<ClientAction>? _sub;

  /// アプリが裏にいる間に頼まれた「駅アラームを始める」。
  /// 画面に戻ったら始める。
  ClientAction? _pendingStart;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = context.read<ChatProvider>().clientActions.listen(
          (action) => unawaited(_run(action)),
        );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  /// アプリが画面に出ているか。まだ分からないときは出ている扱い。
  bool get _inForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;

    final pending = _pendingStart;
    _pendingStart = null;
    if (pending != null) {
      unawaited(StationNotifications.cancel(StationNotifications.openAppId));
      unawaited(_run(pending));
      return;
    }

    // 裏にいる間に始めたせいで、裏で動けない状態なら直す（Android）
    if (StationAlarmController.isSupported) {
      unawaited(context.read<StationAlarmController>().retryBackground());
    }
  }

  Future<void> _run(ClientAction action) async {
    try {
      switch (action.action) {
        case ClientAction.stationAlarmStart:
          await _startStationAlarm(action);
        case ClientAction.stationAlarmStop:
          await _stopStationAlarm();
        default:
          RaimLog.w('[ClientAction] 知らない操作です: ${action.action}');
      }
    } catch (e) {
      RaimLog.e('[ClientAction] 実行できませんでした: ${action.action}', e);
      _toast('うまく実行できませんでした');
    }
  }

  Future<void> _startStationAlarm(ClientAction action) async {
    final name = action.param('station');
    if (name == null) return;

    if (!StationAlarmController.isSupported) {
      _toast('この端末では駅アラームを使えません');
      return;
    }

    if (!_inForeground) {
      // 画面に戻ったときに始める。何度頼まれても最後のものだけ
      _pendingStart = action;
      RaimLog.i('[ClientAction] アプリが裏にいるので、開かれたら駅アラームを始めます');
      unawaited(StationNotifications.askToOpenApp(
        title: '駅アラーム（$name）',
        body: 'アプリを開くと始めるよ',
      ));
      return;
    }

    final alarm = context.read<StationAlarmController>();
    final station = await alarm.startByName(
      name,
      kana: action.param('kana'),
      line: action.param('line'),
    );
    if (!mounted) return;

    if (station == null) {
      // 見つからなければ、その名前で検索した画面を開いて選んでもらう
      _toast('「$name」という駅が見つかりませんでした。一覧から選んでください');
      if (!StationAlarmScreen.isOpen) {
        unawaited(StationAlarmScreen.open(context, query: name));
      }
      return;
    }

    // 乗車中の表示（状態・GPS・聞こえた言葉）が見えるよう画面を開く
    if (!StationAlarmScreen.isOpen) {
      unawaited(StationAlarmScreen.open(context));
    }
  }

  Future<void> _stopStationAlarm() async {
    // 始める前に「やっぱりいい」と言われたら、始めない
    if (_pendingStart != null) {
      _pendingStart = null;
      unawaited(StationNotifications.cancel(StationNotifications.openAppId));
    }
    final alarm = context.read<StationAlarmController>();
    if (!alarm.isActive) return;
    await alarm.stop();
    if (!mounted) return;
    _toast('駅アラームを止めました');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
