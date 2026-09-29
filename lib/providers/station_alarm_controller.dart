// lib/providers/station_alarm_controller.dart
//
// 駅アラーム（乗車モード）の状態を持つ。
//
//   idle     … 使っていない
//   starting … 駅データ・音声モデルの読み込み中
//   riding   … 乗車中。車内アナウンスを聞いている
//   arrived  … 目的の駅のアナウンスを聞いた。少ししたら自動で終わる
//   error    … 始められなかった
//
// 知らせ方（通知・バイブ・ライムの声）は今は最小限（バイブのみ）。
// 画面を消した状態での動作と通知は、別の段階で足す。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/station/station_alarm.dart';
import 'package:raim_prototype/services/station/station_database.dart';
import 'package:raim_prototype/services/station/station_listener.dart';

enum StationAlarmState { idle, starting, riding, arrived, error }

class StationAlarmController extends ChangeNotifier {
  StationAlarmController({ValueListenable<bool>? speaking})
      : _speaking = speaking;

  final ValueListenable<bool>? _speaking;

  /// 着いたあと、聞き続ける時間。「次は」「まもなく」の2回目のアナウンスで
  /// 何度も鳴らさないよう、少しだけ残してから終える。
  static const Duration afterArrival = Duration(minutes: 2);

  /// 乗車モードの上限。消し忘れでマイクが開きっぱなしになるのを防ぐ。
  static const Duration maxRide = Duration(hours: 3);

  /// Vosk が使えるプラットフォームか。
  ///
  /// 本家 vosk_flutter は iOS に対応していないので、iOS はまだ使えない。
  /// Windows は電車で使わないので出さない。
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  StationAlarmState _state = StationAlarmState.idle;
  Station? _destination;
  RailLine? _line;
  StationAlarmEvent? _lastEvent;
  String? _lastHeard;
  String? _error;
  DateTime? _startedAt;

  StationListener? _listener;
  StreamSubscription<StationAlarmEvent>? _eventSub;
  StreamSubscription<String>? _heardSub;
  Timer? _endTimer;
  bool _disposed = false;

  StationAlarmState get state => _state;
  Station? get destination => _destination;

  /// 乗っている路線。null ならその駅を通るすべての路線を待っている。
  RailLine? get line => _line;

  StationAlarmEvent? get lastEvent => _lastEvent;

  /// 最後に聞こえた言葉（Vosk の認識結果）。動作確認用に画面に出す。
  String? get lastHeard => _lastHeard;

  String? get errorMessage => _error;
  DateTime? get startedAt => _startedAt;

  bool get isActive =>
      _state == StationAlarmState.starting ||
      _state == StationAlarmState.riding ||
      _state == StationAlarmState.arrived;

  /// 乗車モードを始める。
  Future<void> start(Station destination, {RailLine? line}) async {
    if (!isSupported) {
      _fail('この端末ではまだ駅アラームを使えません');
      return;
    }
    await stop();

    _destination = destination;
    _line = line;
    _lastEvent = null;
    _lastHeard = null;
    _error = null;
    _setState(StationAlarmState.starting);

    try {
      final db = await StationDatabase.load();
      final plan = StationAlarmPlan.build(db, destination, line: line);
      final listener = StationListener(plan: plan, speaking: _speaking);
      _listener = listener;
      _eventSub = listener.events.listen(_onEvent);
      _heardSub = listener.heard.listen((text) {
        _lastHeard = text;
        _notify();
      });
      await listener.start();

      // 待っている間に止められていたら何もしない
      if (!identical(_listener, listener)) return;

      _startedAt = DateTime.now();
      _endTimer = Timer(maxRide, () {
        RaimLog.i('[StationAlarm] 上限時間に達したので終了します');
        unawaited(stop());
      });
      _setState(StationAlarmState.riding);
    } catch (e) {
      RaimLog.e('[StationAlarm] 開始できませんでした', e);
      await _teardown();
      _fail(_describe(e));
    }
  }

  /// 乗車モードを終える。
  Future<void> stop() async {
    if (_state == StationAlarmState.idle) return;
    await _teardown();
    _setState(StationAlarmState.idle);
  }

  Future<void> _teardown() async {
    _endTimer?.cancel();
    _endTimer = null;
    final listener = _listener;
    _listener = null;
    await _eventSub?.cancel();
    await _heardSub?.cancel();
    _eventSub = null;
    _heardSub = null;
    await listener?.dispose();
  }

  void _onEvent(StationAlarmEvent event) {
    _lastEvent = event;
    switch (event.stage) {
      case StationAlarmStage.approaching:
        unawaited(HapticFeedback.mediumImpact());
        _notify();
      case StationAlarmStage.arriving:
        unawaited(_buzz());
        _setState(StationAlarmState.arrived);
        _endTimer?.cancel();
        _endTimer = Timer(afterArrival, () => unawaited(stop()));
    }
  }

  /// 着いたときは何度か震わせる（1回だと寝ていて気づかない）。
  Future<void> _buzz() async {
    for (var i = 0; i < 3; i++) {
      await HapticFeedback.vibrate();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  void _fail(String message) {
    _error = message;
    _setState(StationAlarmState.error);
  }

  String _describe(Object e) {
    final text = e.toString();
    if (text.contains('マイク')) return 'マイクを使えません。権限を確認してください';
    if (text.contains('Unable to load asset')) return '駅データか音声モデルが見つかりません';
    return '始められませんでした';
  }

  void _setState(StationAlarmState next) {
    _state = next;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardown());
    super.dispose();
  }
}
