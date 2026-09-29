// lib/services/station/station_listener.dart
//
// マイクの音を Vosk（駅名の文法）に流し、認識結果を判定に渡す。
//
// 「ねえライム」の WakeWordService とは別の認識器を使う。
// モデルは共有し（sharedModel）、マイクも同じ1本を共有する。
// そのため乗車中も「ねえライム」はそのまま使える。
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
import 'package:raim_prototype/services/vosk/vosk_engine.dart';
import 'package:raim_prototype/services/wake_word_service.dart';

class StationListener {
  StationListener({
    required this.plan,
    ValueListenable<bool>? speaking,
  })  : _speaking = speaking,
        _detector = StationAnnouncementDetector(plan);

  final StationAlarmPlan plan;
  final ValueListenable<bool>? _speaking;
  final StationAnnouncementDetector _detector;

  /// 一度に渡す量（200ms）。WakeWordService と同じ。
  static const int _feedBytes =
      MicStreamService.sampleRate * MicStreamService.bytesPerSample * 200 ~/ 1000;

  /// ライムが喋り終わってから聞き始めるまでの待ち時間。
  static const Duration resumeDelay = Duration(milliseconds: 700);

  final StreamController<StationAlarmEvent> _events =
      StreamController<StationAlarmEvent>.broadcast();
  final StreamController<String> _heard = StreamController<String>.broadcast();

  Recognizer? _recognizer;
  StreamSubscription<Uint8List>? _micSub;
  final BytesBuilder _pending = BytesBuilder(copy: false);
  Future<void> _feeding = Future.value();

  DateTime? _mutedUntil;

  /// 知らせるべきアナウンスを見つけたときに流れる。
  Stream<StationAlarmEvent> get events => _events.stream;

  /// 認識結果そのもの（画面の「聞こえた言葉」表示とログ用）。
  Stream<String> get heard => _heard.stream;

  bool get isListening => _micSub != null;

  Future<void> start() async {
    if (isListening) return;

    final model = await WakeWordService.instance.sharedModel();
    final recognizer = await VoskEngine.createRecognizer(
      model: model,
      sampleRate: MicStreamService.sampleRate,
      grammar: plan.grammar,
    );
    _recognizer = recognizer;

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
      _recognizer = null;
      await recognizer.dispose();
      rethrow;
    }

    _speaking?.addListener(_onSpeakingChanged);
    RaimLog.i(
      '[Station] 聞き取り開始 ${plan.destination.name} '
      '(文法 ${plan.grammar.length}語)',
    );
  }

  Future<void> stop() async {
    _speaking?.removeListener(_onSpeakingChanged);

    final sub = _micSub;
    _micSub = null;
    await sub?.cancel();

    // 投入中のものが終わってから認識器を捨てる（Windows は FFI なので、
    // 捨てたあとに触ると落ちる）
    final recognizer = _recognizer;
    _recognizer = null;
    await _feeding.catchError((Object _) {});
    await recognizer?.dispose();
    _pending.clear();

    final mic = MicStreamService.instance;
    mic.unhold(this);
    // 他に誰も使っていなければマイクを閉じる
    if (!mic.isHeld && !mic.hasListeners && !mic.isDumping) {
      await mic.stop();
    }
    RaimLog.i('[Station] 聞き取り終了');
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _heard.close();
  }

  void _onSpeakingChanged() {
    final speaking = _speaking?.value ?? false;
    if (speaking) {
      _mutedUntil = null;
      _pending.clear();
      unawaited(_recognizer?.reset());
    } else {
      _mutedUntil = DateTime.now().add(resumeDelay);
    }
  }

  /// しばらく聞かない。ライムの声（知らせのセリフ）を鳴らすときに使う。
  void muteFor(Duration duration) {
    final until = DateTime.now().add(duration);
    final current = _mutedUntil;
    if (current == null || until.isAfter(current)) _mutedUntil = until;
    _pending.clear();
    unawaited(_recognizer?.reset());
  }

  bool get _muted {
    if (_speaking?.value ?? false) return true;
    final until = _mutedUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _onChunk(Uint8List chunk) {
    if (_muted) return;
    _pending.add(chunk);
    if (_pending.length < _feedBytes) return;

    final buffer = _pending.takeBytes();
    final even = buffer.length - buffer.length % 2;
    final frame = Uint8List.sublistView(buffer, 0, even);
    if (even < buffer.length) _pending.add(Uint8List.sublistView(buffer, even));

    _feeding = _feeding.then((_) => _feed(frame));
  }

  Future<void> _feed(Uint8List frame) async {
    final recognizer = _recognizer;
    if (recognizer == null || _muted) return;
    try {
      final ready = await recognizer.acceptWaveformBytes(frame);
      if (!ready || !identical(recognizer, _recognizer)) return;

      final result = await recognizer.getResult();
      if (!identical(recognizer, _recognizer)) return;

      final text = _textOf(result);
      if (text.isEmpty) return;
      if (!_heard.isClosed) _heard.add(text);

      final event = _detector.onResult(text);
      if (event != null) {
        RaimLog.i('[Station] $event');
        if (!_events.isClosed) _events.add(event);
      }
    } catch (e) {
      RaimLog.e('[Station] 認識に失敗しました', e);
    }
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
