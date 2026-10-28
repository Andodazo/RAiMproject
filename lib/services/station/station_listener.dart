// lib/services/station/station_listener.dart
//
// マイクの音を Vosk（駅名の文法）に流し、認識結果を判定に渡す。
//
// 「ねえライム」の WakeWordService とは別の認識器を使う。
// モデルは共有し（sharedModel）、マイクも同じ1本を共有する。
// そのため乗車中も「ねえライム」はそのまま使える。
//
// 【雑音を消した音と、そのままの音の両方を聞く】
// 走行音などの雑音を StationDenoiser で消すと、聞き取れる駅名が増えることもあれば、
// 逆に「次は」を消してしまうこともある（2026-10 の実車の録音）:
//   iPhone（西八王子）: そのままなら 33 秒で「つぎ は にし はち おうじ」を聞き取れた。
//                       雑音を消すと「次は」が消え、知らせたのは 1 分 46 秒
//   Android（豊田）   : そのままだと駅名をほとんど聞き取れず、雑音を消すと「とよ だ」が聞こえた
// そこで認識器を2つ動かし、片方にはそのままの音、もう片方には雑音を消した音を渡す。
// 判定（StationAnnouncementDetector）も別々に持ち、どちらかが見つけたら知らせる。
// 判定を共有しないのは、同じアナウンスを2つが聞いて「駅名を2回聞いた」と
// 数えてしまわないため。雑音除去が使えなければ、そのままの音だけを聞く。
// 録音（StationRecorder）には消す前の音を残す。
//
// 【ライムの声を拾わない】
// ライムが「次は新宿だよ」と喋ると、その声で自分が反応してしまう。
// ライムが喋っている間と喋り終わって少しの間は、音を渡さない。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

import 'package:raim_prototype/services/mic_stream_service.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/station/station_alarm.dart';
import 'package:raim_prototype/services/station/station_denoiser.dart';
import 'package:raim_prototype/services/station/station_recorder.dart';
import 'package:raim_prototype/services/vosk/vosk_engine.dart';
import 'package:raim_prototype/services/wake_word_service.dart';

class StationListener {
  StationListener({
    required this.plan,
    ValueListenable<bool>? speaking,
    bool Function()? allowRepeated,
  })  : _speaking = speaking,
        _allowRepeated = allowRepeated;

  final StationAlarmPlan plan;
  final ValueListenable<bool>? _speaking;

  /// 駅名の繰り返しだけで知らせてよいか（GPS で駅の近くにいるか）。
  final bool Function()? _allowRepeated;

  /// 一度に渡す量（200ms）。WakeWordService と同じ。
  static const int _feedBytes =
      MicStreamService.sampleRate * MicStreamService.bytesPerSample * 200 ~/ 1000;

  /// ライムが喋り終わってから聞き始めるまでの待ち時間。
  static const Duration resumeDelay = Duration(milliseconds: 700);

  /// 同じ知らせを、もう一方の認識器から重ねて出さない間隔
  /// （StationAnnouncementDetector の repeatGuard と同じ）。
  static const Duration duplicateGuard = Duration(seconds: 90);

  final StreamController<StationAlarmEvent> _events =
      StreamController<StationAlarmEvent>.broadcast();
  final StreamController<String> _heard = StreamController<String>.broadcast();

  /// そのままの音を聞く認識器。
  _Lane? _raw;

  /// 雑音を消した音を聞く認識器。雑音除去が使えなければ null。
  _Lane? _clean;

  StationDenoiser? _denoiser;
  StreamSubscription<Uint8List>? _micSub;

  /// 知らせた内容（段階:駅コード）と時刻。2つの認識器で重ねて出さないため。
  final Map<String, DateTime> _emitted = {};

  DateTime? _mutedUntil;

  /// 知らせるべきアナウンスを見つけたときに流れる。
  Stream<StationAlarmEvent> get events => _events.stream;

  /// 認識結果そのもの（画面の「聞こえた言葉」表示とログ用）。
  Stream<String> get heard => _heard.stream;

  bool get isListening => _micSub != null;

  List<_Lane> get _lanes => [?_raw, ?_clean];

  Future<void> start() async {
    if (isListening) return;

    final model = await WakeWordService.instance.sharedModel();
    Future<Recognizer> create() => VoskEngine.createRecognizer(
          model: model,
          sampleRate: MicStreamService.sampleRate,
          grammar: plan.grammar,
        );

    _raw = _Lane('そのまま', await create(), plan);
    // 走行音などの雑音を消した音も聞く。使えなければそのままの音だけ
    _denoiser = await StationDenoiser.create();
    if (_denoiser != null) {
      try {
        _clean = _Lane('雑音除去', await create(), plan);
      } catch (e) {
        RaimLog.w('[Station] 雑音を消した音用の認識器を作れませんでした: ${e.runtimeType}');
        _denoiser?.dispose();
        _denoiser = null;
      }
    }

    final mic = MicStreamService.instance;
    mic.hold(this);
    try {
      final stream = await mic.start();
      _micSub = stream.listen(
        _onChunk,
        onError: (Object e) => RaimLog.e('[Station] マイクでエラー', e),
        onDone: () {
          if (_micSub != null) {
            RaimLog.w('[Station] マイクが閉じられました');
            _micSub = null;
          }
        },
      );
    } catch (e) {
      mic.unhold(this);
      await _closeLanes();
      rethrow;
    }

    _speaking?.addListener(_onSpeakingChanged);
    // 【確認用・後で消す】設定が ON なら、聞いている音を wav に残す
    await StationRecorder.startIfEnabled(destination: plan.destination.name);
    RaimLog.i(
      '[Station] 聞き取り開始 ${plan.destination.name} '
      '(文法 ${plan.grammar.length}語 / '
      '${_clean == null ? "そのままの音だけ" : "そのままの音と雑音を消した音"})',
    );
  }

  Future<void> stop() async {
    _speaking?.removeListener(_onSpeakingChanged);
    await StationRecorder.stop(); // 【確認用・後で消す】

    final sub = _micSub;
    _micSub = null;
    await sub?.cancel();

    await _closeLanes();
    _emitted.clear();

    final mic = MicStreamService.instance;
    mic.unhold(this);
    // 他に誰も使っていなければマイクを閉じる
    if (!mic.isHeld && !mic.hasListeners && !mic.isDumping) {
      await mic.stop();
    }
    RaimLog.i('[Station] 聞き取り終了');
  }

  /// 認識器と雑音除去を捨てる。
  Future<void> _closeLanes() async {
    final lanes = _lanes;
    _raw = null;
    _clean = null;
    for (final lane in lanes) {
      await lane.close();
    }
    _denoiser?.dispose();
    _denoiser = null;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _heard.close();
  }

  void _onSpeakingChanged() {
    final speaking = _speaking?.value ?? false;
    StationRecorder.note(speaking ? 'ライムが喋り始めた（聞かない）' : 'ライムが喋り終えた'); // 【確認用・後で消す】
    if (speaking) {
      _mutedUntil = null;
      for (final lane in _lanes) {
        lane.clear();
      }
    } else {
      _mutedUntil = DateTime.now().add(resumeDelay);
    }
  }

  /// しばらく聞かない。ライムの声（知らせのセリフ）を鳴らすときに使う。
  void muteFor(Duration duration) {
    StationRecorder.note('ライムの声を鳴らすので ${duration.inSeconds}秒 聞かない'); // 【確認用・後で消す】
    final until = DateTime.now().add(duration);
    final current = _mutedUntil;
    if (current == null || until.isAfter(current)) _mutedUntil = until;
    for (final lane in _lanes) {
      lane.clear();
    }
  }

  bool get _muted {
    if (_speaking?.value ?? false) return true;
    final until = _mutedUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _onChunk(Uint8List chunk) {
    StationRecorder.add(chunk); // 【確認用・後で消す】聞かない間の音も残す
    // 雑音を消す。聞かない間も渡し続ける（途中で途切れると消し方が乱れる）
    final clean = _denoiser?.process(chunk);
    if (_muted) return;

    final raw = _raw;
    if (raw != null) _push(raw, chunk);
    final cleanLane = _clean;
    if (cleanLane != null && clean != null) _push(cleanLane, clean);
  }

  /// [lane] に音を溜め、200ms 溜まったら認識器に渡す。
  void _push(_Lane lane, Uint8List bytes) {
    lane.pending.add(bytes);
    if (lane.pending.length < _feedBytes) return;

    final buffer = lane.pending.takeBytes();
    final even = buffer.length - buffer.length % 2;
    final frame = Uint8List.sublistView(buffer, 0, even);
    if (even < buffer.length) {
      lane.pending.add(Uint8List.sublistView(buffer, even));
    }

    lane.feeding = lane.feeding.then((_) => _feed(lane, frame));
  }

  Future<void> _feed(_Lane lane, Uint8List frame) async {
    final recognizer = lane.recognizer;
    if (recognizer == null || _muted) return;
    try {
      final ready = await recognizer.acceptWaveformBytes(frame);
      if (!ready || !identical(recognizer, lane.recognizer)) return;

      final result = await recognizer.getResult();
      if (!identical(recognizer, lane.recognizer)) return;

      final text = _textOf(result);
      if (text.isEmpty) return;
      RaimLog.d('[Station] 聞こえた（${lane.label}）: $text');
      if (!_heard.isClosed) _heard.add(text);

      final allowRepeated = _allowRepeated?.call() ?? false;
      // 【確認用・後で消す】
      StationRecorder.note(
        '聞こえた（${lane.label}）: $text${allowRepeated ? '（GPSで駅の近く）' : ''}',
      );
      final event = lane.detector.onResult(
        text,
        allowRepeated: allowRepeated,
      );
      if (event != null) _emit(event, lane);
    } catch (e) {
      RaimLog.e('[Station] 認識に失敗しました', e);
    }
  }

  /// 知らせる。もう一方の認識器が少し前に同じ知らせを出していれば出さない。
  void _emit(StationAlarmEvent event, _Lane lane) {
    final key = '${event.stage.name}:${event.station.code}';
    final last = _emitted[key];
    if (last != null && event.at.difference(last) < duplicateGuard) {
      RaimLog.d('[Station] もう一方で知らせ済み（${lane.label}）: $event');
      return;
    }
    _emitted[key] = event.at;
    StationRecorder.note('検知（${lane.label}）: $event'); // 【確認用・後で消す】
    RaimLog.i('[Station] $event（${lane.label}）');
    if (!_events.isClosed) _events.add(event);
  }

  String _textOf(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return (map['text'] as String? ?? '').trim();
    } catch (_) {
      return '';
    }
  }
}

/// 1つの認識器と、その判定・溜めている音。
class _Lane {
  _Lane(this.label, this.recognizer, StationAlarmPlan plan)
      : detector = StationAnnouncementDetector(plan);

  /// ログに出す名前（「そのまま」「雑音除去」）。
  final String label;
  Recognizer? recognizer;
  final StationAnnouncementDetector detector;
  final BytesBuilder pending = BytesBuilder(copy: false);
  Future<void> feeding = Future.value();

  /// 溜めている音と、認識器の途中の状態を捨てる（ライムが喋るとき）。
  void clear() {
    pending.clear();
    unawaited(recognizer?.reset());
  }

  /// 投入中のものが終わってから認識器を捨てる（Windows は FFI なので、
  /// 捨てたあとに触ると落ちる）。
  Future<void> close() async {
    final r = recognizer;
    recognizer = null;
    await feeding.catchError((Object _) {});
    await r?.dispose();
    pending.clear();
  }
}
