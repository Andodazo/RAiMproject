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
// 【画面を消しても動く】
// Android はフォアグラウンドサービス（RideForegroundService）を動かして、
// 裏でもマイクを使えるようにする。サービスの通知が「乗車中」の表示になる。
// iOS は Info.plist の UIBackgroundModes（audio / location）により、
// 画面を点けている間に始めた録音と GPS は、画面を消しても続く。
//
// 【裏で始めようとしたとき】
// Android は、アプリが裏にいる間はマイク・位置情報を使うサービスを始められない。
// 始められなかったら「アプリを開いて」と通知し、開かれたら
// retryBackground() で始め直す（ClientActionListener が呼ぶ）。
//
// 【GPS】
// 位置情報の許可があれば、GPS も使う（StationProximity）。
//   - 降りる駅から遠いところで聞こえたアナウンスは無視する（聞き間違い対策）
//   - アナウンスを聞き逃しても、駅に近づいたら知らせる
//   - 地下などで位置が取れないときは、音声だけで判定する
//   - 駅の近くにいると分かっているときは、「次は」が聞き取れなくても
//     駅名の繰り返しで知らせる
// 許可が無くても、音声だけで動く。
//
// 【知らせ方】
//   - 通知（音とバイブ）… Android はサービスの通知を書き換えて鳴らす。
//                         iOS（とサービスが無い Android）は StationNotifications
//   - ライムの声      … assets/sounds の wav（VOICEVOX で作ったもの）。無ければ鳴らさない
//   - バイブ          … 画面を点けているときの補助（裏では鳴らない）

import 'dart:async';
import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:geolocator/geolocator.dart';

import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/station/ride_foreground_service.dart';
import 'package:raim_prototype/services/station/station_alarm.dart';
import 'package:raim_prototype/services/station/station_database.dart';
import 'package:raim_prototype/services/station/station_listener.dart';
import 'package:raim_prototype/services/station/station_lookup.dart';
import 'package:raim_prototype/services/station/station_notifications.dart';
import 'package:raim_prototype/services/station/station_proximity.dart';
import 'package:raim_prototype/services/vosk/vosk_engine.dart';

enum StationAlarmState { idle, starting, riding, arrived, error }

class StationAlarmController extends ChangeNotifier {
  StationAlarmController({
    ValueListenable<bool>? speaking,
    ValueListenable<String>? persona,
  })  : _speaking = speaking,
        _persona = persona;

  final ValueListenable<bool>? _speaking;

  /// サーバーの人格（'bright' | 'downer'）。声と通知の文を合わせる。
  final ValueListenable<String>? _persona;

  bool get _isDowner => _persona?.value == 'downer';

  /// 着いたあと、聞き続ける時間。「次は」「まもなく」の2回目のアナウンスで
  /// 何度も鳴らさないよう、少しだけ残してから終える。
  static const Duration afterArrival = Duration(minutes: 2);

  /// 乗車モードの上限。消し忘れでマイクが開きっぱなしになるのを防ぐ。
  static const Duration maxRide = Duration(hours: 3);

  /// 駅アラームを使えるか。
  ///
  /// スマホ（Android・iOS）で、Vosk が使えるとき。
  /// Windows は電車で使わないので出さない。
  static bool get isSupported =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS) &&
      VoskEngine.isAvailable;

  StationAlarmState _state = StationAlarmState.idle;
  Station? _destination;
  RailLine? _line;
  StationAlarmEvent? _lastEvent;
  String? _lastHeard;
  String? _error;
  DateTime? _startedAt;

  StationListener? _listener;
  AudioPlayer? _voice;
  StationProximity? _proximity;
  StreamSubscription<Position>? _gpsSub;
  bool _approachAlerted = false;

  /// フォアグラウンドサービスが動いているか（画面を消しても大丈夫か）。
  bool _background = false;
  bool get canRunInBackground => _background;
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

  /// GPS を使っているか（位置情報の許可があり、位置が取れているか）。
  bool get hasLocation =>
      _proximity?.hasFreshFix(DateTime.now()) ?? false;

  /// 降りる駅までの距離（m）。GPS が使えなければ null。
  double? get distanceToDestination =>
      hasLocation ? _proximity?.distance : null;

  /// 位置情報の許可をもらえたか（GPS を使おうとしているか）。
  bool _locationGranted = false;
  bool get locationGranted => _locationGranted;
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
    _approachAlerted = false;
    _setState(StationAlarmState.starting);

    try {
      final db = await StationDatabase.load();
      final plan = StationAlarmPlan.build(db, destination, line: line);
      final listener = StationListener(
        plan: plan,
        speaking: _speaking,
        // GPS で駅の近くにいると分かっているときは、「次は」が聞き取れなくても
        // 駅名の繰り返しで知らせる
        allowRepeated: () =>
            _proximity?.isNearByGps(DateTime.now()) ?? false,
      );
      _listener = listener;
      _proximity = StationProximity(plan);
      _eventSub = listener.events.listen(_onVoiceEvent);
      _heardSub = listener.heard.listen((text) {
        _lastHeard = text;
        _notify();
      });
      await listener.start();

      // 待っている間に止められていたら何もしない
      if (!identical(_listener, listener)) return;

      // 位置情報の許可をもらう（断られたら音声だけで動く）
      _locationGranted = await _prepareLocation();
      if (!identical(_listener, listener)) return;

      // iOS は知らせを通知で出すので、画面に出ている今のうちに許可をもらう
      // （Android はフォアグラウンドサービスを始めるときに聞く）
      if (Platform.isIOS) await StationNotifications.requestPermission();
      if (!identical(_listener, listener)) return;

      // マイクを開いてから（録音の許可をもらってから）サービスを始める。
      // Android 14 以降は、許可が無いとマイク用のサービスを始められない。
      _background = Platform.isIOS ||
          await RideForegroundService.start(
            title: '駅アラーム：${destination.name}',
            text: '車内アナウンスを聞いています',
            withLocation: _locationGranted,
          );
      if (!identical(_listener, listener)) {
        // 待っている間に止められた。始めてしまったサービスも止める
        if (_background) {
          _background = false;
          await RideForegroundService.stop();
        }
        return;
      }

      if (_locationGranted) _startGps();

      // Android で始められなかった（アプリが裏にいた）。画面を消すと
      // マイクに無音しか届かなくなるので、開いてもらって始め直す
      if (!_background) _askToOpenApp();

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

  /// 裏でも動くようにし直す。アプリが画面に戻ったときに呼ぶ。
  ///
  /// 乗車モードをアプリが裏にいる間に始めると、Android では
  /// フォアグラウンドサービスを始められない（[start] 参照）。
  Future<void> retryBackground() async {
    if (!Platform.isAndroid || _background) return;
    if (_state != StationAlarmState.riding &&
        _state != StationAlarmState.arrived) {
      return;
    }
    final dest = _destination;
    if (dest == null) return;

    final ok = await RideForegroundService.start(
      title: '駅アラーム：${dest.name}',
      text: '車内アナウンスを聞いています',
      withLocation: _locationGranted,
    );
    // 待っている間に止められていたら、始めたサービスも止める
    if (!isActive) {
      if (ok) await RideForegroundService.stop();
      return;
    }
    _background = ok;
    if (ok) {
      RaimLog.i('[StationAlarm] 画面に戻ったので、裏でも動くようにしました');
      unawaited(StationNotifications.cancel(StationNotifications.openAppId));
    }
    _notify();
  }

  void _askToOpenApp() {
    final dest = _destination?.name ?? '';
    RaimLog.w('[StationAlarm] フォアグラウンドサービスを始められませんでした');
    // 画面に出ているのに始められなかった（通知の許可が無い など）ときは、
    // 開いてと言っても意味が無いので出さない
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) return;
    unawaited(StationNotifications.askToOpenApp(
      title: '駅アラーム（$dest）',
      body: 'このままだと画面を消したときに聞けません。アプリを一度開いてね',
    ));
  }

  /// 駅名で乗車モードを始める。
  ///
  /// ライムに「新宿で起こして」と頼まれたとき（client_action）に使う。
  /// 届くのは駅名の文字だけなので、駅データから探す。同じ名前の駅が
  /// 複数あれば今いる場所に近い方を選ぶ（station_lookup.dart）。
  ///
  /// 始めた駅を返す。駅が見つからなければ null（乗車モードは始めない）。
  Future<Station?> startByName(
    String name, {
    String? kana,
    String? line,
  }) async {
    if (!isSupported) return null;

    final db = await StationDatabase.load();
    final here = await _lastKnownPosition();
    final station = findStationByName(
      db,
      name,
      kana: kana,
      lat: here?.latitude,
      lng: here?.longitude,
    );
    if (station == null) {
      RaimLog.i('[StationAlarm] 頼まれた駅が見つかりませんでした: $name');
      return null;
    }

    final railLine = findLineByName(db, station, line);
    RaimLog.i(
      '[StationAlarm] 頼まれて始めます: ${station.name}'
      '（${railLine?.name ?? 'すべての路線'}）',
    );
    await start(station, line: railLine);
    return station;
  }

  /// 最後に分かっている現在地。許可が無ければ聞かずに null を返す
  /// （許可を求めるのは、乗車モードを始めるとき）。
  Future<Position?> _lastKnownPosition() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        return null;
      }
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  /// 乗車モードを終える。
  Future<void> stop() async {
    if (_state == StationAlarmState.idle) return;
    await _teardown();
    _setState(StationAlarmState.idle);
  }

  Future<void> _teardown() async {
    unawaited(StationNotifications.cancel(StationNotifications.openAppId));
    _endTimer?.cancel();
    _endTimer = null;
    await _gpsSub?.cancel();
    _gpsSub = null;
    _proximity = null;
    _locationGranted = false;
    if (_background) {
      _background = false;
      await RideForegroundService.stop();
    }
    final voice = _voice;
    _voice = null;
    await voice?.dispose();
    final listener = _listener;
    _listener = null;
    await _eventSub?.cancel();
    await _heardSub?.cancel();
    _eventSub = null;
    _heardSub = null;
    await listener?.dispose();
  }

  // ─── GPS ───

  /// 位置情報の許可を確かめ、無ければ求める。使えるなら true。
  Future<bool> _prepareLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        RaimLog.i('[StationAlarm] 位置情報がオフなので、音声だけで判定します');
        return false;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      final ok = permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
      if (!ok) RaimLog.i('[StationAlarm] 位置情報の許可が無いので、音声だけで判定します');
      return ok;
    } catch (e) {
      RaimLog.w('[StationAlarm] 位置情報を確認できませんでした: ${e.runtimeType}');
      return false;
    }
  }

  void _startGps() {
    final LocationSettings settings = Platform.isIOS
        ? AppleSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            activityType: ActivityType.otherNavigation,
            // 駅で止まっている間に更新が止まらないように
            pauseLocationUpdatesAutomatically: false,
            // 画面を消しても受け取る（ステータスバーに青い表示が出る）
            allowBackgroundLocationUpdates: true,
            showBackgroundLocationIndicator: true,
          )
        : AndroidSettings(
            accuracy: LocationAccuracy.high,
            // 電車は速いので間隔で取る。距離で絞ると駅に止まっている間に来ない
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 5),
          );
    _gpsSub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onPosition,
      onError: (Object e) =>
          RaimLog.w('[StationAlarm] 位置を取れませんでした: ${e.runtimeType}'),
    );
  }

  void _onPosition(Position p) {
    final proximity = _proximity;
    final dest = _destination;
    if (proximity == null || dest == null) return;

    final stage = proximity.onPosition(
      p.latitude,
      p.longitude,
      accuracy: p.accuracy,
      at: DateTime.now(),
    );
    if (stage != null && _state != StationAlarmState.arrived) {
      RaimLog.i('[StationAlarm] GPS で知らせます: ${stage.name}');
      _alert(StationAlarmEvent(
        stage: stage,
        station: dest,
        heard: 'GPS',
        at: DateTime.now(),
      ));
      return;
    }
    _notify(); // 距離の表示を更新する
  }

  // ─── 知らせ ───

  /// 音声で見つけた知らせ。GPS で遠いと分かっていれば捨てる。
  void _onVoiceEvent(StationAlarmEvent event) {
    final proximity = _proximity;
    if (proximity != null && !proximity.allowsVoice(DateTime.now())) {
      RaimLog.i(
        '[StationAlarm] 駅から遠いので聞き間違いとみなしました '
        '(${proximity.distance?.round()}m / ${event.stage.name})',
      );
      return;
    }
    proximity?.markNotified(event.stage);
    _alert(event);
  }

  void _alert(StationAlarmEvent event) {
    if (_state == StationAlarmState.arrived) return;
    if (event.stage == StationAlarmStage.approaching) {
      if (_approachAlerted) return;
      _approachAlerted = true;
    }
    _lastEvent = event;
    final dest = _destination?.name ?? '';
    switch (event.stage) {
      case StationAlarmStage.approaching:
        unawaited(HapticFeedback.mediumImpact());
        unawaited(_notifyUser(
          title: 'もうすぐ $dest',
          text: _isDowner
              ? '次は ${event.station.name}。そろそろ準備しよ'
              : '次は ${event.station.name}。降りる準備をしておいてね',
        ));
        unawaited(_speakLine('station_approaching'));
        _notify();
      case StationAlarmStage.arriving:
        unawaited(_buzz());
        unawaited(_notifyUser(
          title: _isDowner ? 'まもなく $dest' : 'まもなく $dest！',
          text: _isDowner ? '着くよ。降りる準備して' : '降りる準備をして！',
        ));
        unawaited(_speakLine('station_arriving'));
        _setState(StationAlarmState.arrived);
        _endTimer?.cancel();
        _endTimer = Timer(afterArrival, () => unawaited(stop()));
    }
  }

  /// 通知で知らせる。
  ///
  /// Android はフォアグラウンドサービスの通知を書き換える（音とバイブが鳴る）。
  /// iOS と、サービスを始められなかった Android は別の通知を出す。
  /// 以前は iOS で通知を出しておらず、画面を消しているとバイブも鳴らないため、
  /// 声のファイルが無いと何も起きなかった。
  Future<void> _notifyUser({required String title, required String text}) {
    if (Platform.isAndroid && _background) {
      return RideForegroundService.update(title: title, text: text);
    }
    return StationNotifications.alert(title: title, body: text);
  }

  /// 人格に合ったライムの声で知らせる。
  ///
  /// ダウナー版は `<name>_downer.wav` を鳴らす。無ければ通常版を鳴らす。
  Future<void> _speakLine(String name) async {
    if (_isDowner && await _speak('sounds/${name}_downer.wav')) return;
    await _speak('sounds/$name.wav');
  }

  /// ライムの声で知らせる。ファイルが無ければ何もしない。
  ///
  /// 鳴らしている間は聞くのを止める。ライムの声に自分で反応しないため。
  /// 鳴らせたら true。
  Future<bool> _speak(String asset) async {
    _listener?.muteFor(voiceMute);
    try {
      final player = _voice ??= AudioPlayer();
      await player.stop();
      await player.play(AssetSource(asset));
      return true;
    } catch (e) {
      RaimLog.d('[StationAlarm] ライムの声を鳴らせませんでした（$asset が無い？）');
      return false;
    }
  }

  /// ライムの声を鳴らすときに、車内アナウンスを聞かない時間。
  /// セリフ（3〜4 秒）と、鳴り終わりの残響の分。
  static const Duration voiceMute = Duration(seconds: 5);

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
