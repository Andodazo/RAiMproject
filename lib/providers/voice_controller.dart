// lib/providers/voice_controller.dart
//
// 音声呼び出しの状態をまとめて管理する。
//
// 【役割】
// ウェイクワード検知・マイク・ライムの発話（TTS）の3つは互いに影響する。
// それぞれのサービスが勝手に動くと、たとえば「ライムが喋っている最中に
// 自分の声でウェイクワードが発火する」ことが起きる。
// どの状態で何を動かすかの判断をここに集める。
//
// 【状態】
//   off       … 使わない（設定 OFF、未ログイン、非対応プラットフォーム）
//   starting  … モデル読み込み中。初回は zip の展開で数秒かかる
//   listening … 「ねえライム」を待っている
//   awake     … 呼ばれた直後。STT（タスク6）が入るまでは入力小窓を開くだけ
//   error     … 起動に失敗した（モデルが無い、マイクが使えない など）
//
// ライムが喋っている間は listening のまま検知だけ止める（suspend）。
// 状態を分けないのは、喋り終われば何もしなくても listening に戻るため。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'package:raim_prototype/providers/auth_provider.dart';
import 'package:raim_prototype/providers/voice_settings_provider.dart';
import 'package:raim_prototype/services/mic_stream_service.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/wake_word_service.dart';

enum VoiceState { off, starting, listening, awake, error }

class VoiceController extends ChangeNotifier {
  VoiceController({
    required VoiceSettingsProvider settings,
    required AuthProvider auth,
    required ValueListenable<bool> speaking,
    WakeWordService? wakeWord,
  })  : _settings = settings,
        _auth = auth,
        _speaking = speaking,
        _wake = wakeWord ?? WakeWordService.instance {
    _settings.addListener(_onInputsChanged);
    _auth.addListener(_onInputsChanged);
    _speaking.addListener(_onSpeakingChanged);
    _detectionSub = _wake.detections.listen(_onDetected);
    _onInputsChanged();
  }

  /// 呼ばれてから待機に戻るまでの時間。
  ///
  /// STT が入るまでは「入力小窓を開く」だけなので、その間は
  /// 検知を止めておく。開いた直後にもう一度「ねえライム」と
  /// 言われても二重に反応しないようにするため。
  static const Duration awakeDuration = Duration(seconds: 8);

  /// ライムが喋り終わってから検知を再開するまでの待ち時間。
  ///
  /// TTS は1文ずつ再生されるので、文と文の間に一瞬だけ
  /// 「再生していない」状態が挟まる。すぐ再開すると次の文の声を拾う。
  /// スピーカーの残響が消えるまでの余裕も含めている。
  static const Duration resumeDelay = Duration(milliseconds: 700);

  /// Vosk とマイクが使えるプラットフォームか。
  ///
  /// iOS は含めない。本家 vosk_flutter が Windows・Linux（FFI）と
  /// Android にしか対応しておらず、iOS では初期化で例外になる。
  /// iOS の対応はタスク8で別途検討する。
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isAndroid;
  }

  final VoiceSettingsProvider _settings;
  final AuthProvider _auth;
  final ValueListenable<bool> _speaking;
  final WakeWordService _wake;

  late final StreamSubscription<WakeWordDetection> _detectionSub;
  final StreamController<WakeWordDetection> _wakeEvents =
      StreamController<WakeWordDetection>.broadcast();

  VoiceState _state = VoiceState.off;
  String? _errorMessage;
  List<String> _activeWords = const [];

  Timer? _awakeTimer;
  Timer? _resumeTimer;

  /// start / stop を1本の列に並べる。設定の ON/OFF を連打されても
  /// 前の処理が終わる前に次が走らないようにするため。
  Future<void> _op = Future.value();

  bool _disposed = false;

  VoiceState get state => _state;
  String? get errorMessage => _errorMessage;

  /// ライムが喋っているか。
  bool get isSpeaking => _speaking.value;

  /// 「ねえライム」と呼ばれたときに流れる。
  ///
  /// Windows では入力小窓がこれを購読して窓を開く。
  Stream<WakeWordDetection> get wakeEvents => _wakeEvents.stream;

  // ─── 起動と停止 ───

  void _onInputsChanged() {
    _op = _op.then((_) => _sync()).catchError((Object e) {
      RaimLog.e('[Voice] 状態の切り替えに失敗しました', e);
    });
  }

  /// 今あるべき状態に合わせて起動・停止する。
  Future<void> _sync() async {
    if (_disposed) return;

    final shouldRun =
        isSupported && _auth.isAuthenticated && _settings.wakeWordEnabled;

    if (!shouldRun) {
      if (_state != VoiceState.off) await _stop();
      return;
    }

    final words = _settings.wakeWords;
    final wordsChanged = !listEquals(words, _activeWords);
    final running =
        _state == VoiceState.listening || _state == VoiceState.awake;

    if (running && !wordsChanged) return;
    await _start(words);
  }

  Future<void> _start(List<String> words) async {
    _cancelTimers();
    _setState(VoiceState.starting);

    try {
      await _wake.start(wakeWords: words);
      _activeWords = List.unmodifiable(words);
      _errorMessage = null;
      _setState(VoiceState.listening);

      // 起動した時点でライムが喋っていれば、すぐ止める
      if (isSpeaking) _wake.suspend();
    } catch (e) {
      RaimLog.e('[Voice] ウェイクワードを起動できませんでした', e);
      _errorMessage = _describe(e);
      await _releaseMic();
      _setState(VoiceState.error);
    }
  }

  Future<void> _stop() async {
    _cancelTimers();
    await _wake.stop();
    await _releaseMic();
    _activeWords = const [];
    _setState(VoiceState.off);
    RaimLog.i('[Voice] ウェイクワードを停止しました');
  }

  /// マイクを閉じる。
  ///
  /// 設定を OFF にしたのにマイクが開いたままだと、OS の表示では
  /// 「録音中」のままになる。ユーザーから見ると OFF にした意味がない。
  /// ただし録音テストの最中なら、そちらを優先して閉じない。
  Future<void> _releaseMic() async {
    final mic = MicStreamService.instance;
    if (mic.isDumping) return;
    await mic.stop();
  }

  // ─── 検知 ───

  void _onDetected(WakeWordDetection detection) {
    if (_state != VoiceState.listening) return;

    // 喋り終わり直後の再開待ちの間に届いたものも捨てる。
    // suspend 前にマイクへ入っていたライムの声の可能性があるため。
    if (isSpeaking || _resumeTimer != null) {
      RaimLog.d('[Voice] ライムの発話中だったため検知を無視しました');
      return;
    }

    RaimLog.i('[Voice] 呼ばれました');
    _wake.suspend();
    _setState(VoiceState.awake);
    if (!_wakeEvents.isClosed) _wakeEvents.add(detection);

    _awakeTimer?.cancel();
    _awakeTimer = Timer(awakeDuration, _endAwake);
  }

  /// 呼ばれた状態を終えて待機に戻る。
  ///
  /// 今は時間切れで戻るだけ。STT が入ったら「聞き取り終わり」で呼ぶ。
  void endAwake() => _endAwake();

  void _endAwake() {
    _awakeTimer?.cancel();
    _awakeTimer = null;
    if (_state != VoiceState.awake) return;

    _setState(VoiceState.listening);
    if (!isSpeaking) _wake.resume();
  }

  // ─── ライムの発話との調停 ───

  void _onSpeakingChanged() {
    if (_state != VoiceState.listening && _state != VoiceState.awake) return;

    if (isSpeaking) {
      _resumeTimer?.cancel();
      _resumeTimer = null;
      _wake.suspend();
      return;
    }

    // 呼ばれた状態の間は再開しない（_endAwake が再開する）
    if (_state == VoiceState.awake) return;

    _resumeTimer?.cancel();
    _resumeTimer = Timer(resumeDelay, () {
      _resumeTimer = null;
      if (_state == VoiceState.listening && !isSpeaking) {
        _wake.resume();
      }
    });
  }

  // ─── 後始末 ───

  void _cancelTimers() {
    _awakeTimer?.cancel();
    _awakeTimer = null;
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  void _setState(VoiceState next) {
    if (_state == next) return;
    RaimLog.d('[Voice] ${_state.name} → ${next.name}');
    _state = next;
    if (!_disposed) notifyListeners();
  }

  String _describe(Object e) {
    final text = e.toString();
    if (text.contains('Unable to load asset') || text.contains('vosk-model')) {
      return '音声モデルが見つかりません（assets/models/README.md 参照）';
    }
    if (text.contains('マイク')) {
      return 'マイクを使えません。OS の設定を確認してください';
    }
    return '起動できませんでした';
  }

  @override
  void dispose() {
    _disposed = true;
    _settings.removeListener(_onInputsChanged);
    _auth.removeListener(_onInputsChanged);
    _speaking.removeListener(_onSpeakingChanged);
    _cancelTimers();
    unawaited(_detectionSub.cancel());
    unawaited(_wakeEvents.close());
    unawaited(_wake.stop());
    super.dispose();
  }
}
