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
//   awake     … 呼ばれた直後。続けて話された内容を Transcribe で聞き取る
//   error     … 起動に失敗した（モデルが無い、マイクが使えない など）
//
// ライムが喋っている間は listening のまま検知だけ止める（suspend）。
// 状態を分けないのは、喋り終われば何もしなくても listening に戻るため。
//
// 【呼ばれたあと】
//   「ねえライム」→ 入力小窓が開く（wakeEvents）
//   → 続けて話した内容を Transcribe で文字にする（heardText に途中経過）
//   → 聞き取れたら utterances に流す。送信するかは画面側が決める
//   → listening に戻る
// 聞き取り中はウェイクワードの検知を止めている。自分の話の中の
// 「ライム」で呼び直されないようにするため。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'package:raim_prototype/providers/auth_provider.dart';
import 'package:raim_prototype/providers/voice_settings_provider.dart';
import 'package:raim_prototype/services/mic_stream_service.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/transcribe_stt_service.dart';
import 'package:raim_prototype/services/wake_word_service.dart';

enum VoiceState { off, starting, listening, awake, error }

class VoiceController extends ChangeNotifier {
  VoiceController({
    required VoiceSettingsProvider settings,
    required AuthProvider auth,
    required ValueListenable<bool> speaking,
    WakeWordService? wakeWord,
    TranscribeSttService? stt,
  })  : _settings = settings,
        _auth = auth,
        _speaking = speaking,
        _wake = wakeWord ?? WakeWordService.instance,
        _stt = stt {
    _settings.addListener(_onInputsChanged);
    _auth.addListener(_onInputsChanged);
    _speaking.addListener(_onSpeakingChanged);
    _detectionSub = _wake.detections.listen(_onDetected);
    _onInputsChanged();
  }

  /// 聞き取りを使わない場合に、呼ばれてから待機に戻るまでの時間。
  ///
  /// その間は検知を止めておく。窓が開いた直後にもう一度
  /// 「ねえライム」と言われても二重に反応しないようにするため。
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

  /// 呼ばれたあとの聞き取り。null なら窓を開くだけ。
  final TranscribeSttService? _stt;
  SttSession? _session;
  final ValueNotifier<String> _heard = ValueNotifier<String>('');
  final StreamController<String> _utterances =
      StreamController<String>.broadcast();
  String? _sttError;

  late final StreamSubscription<WakeWordDetection> _detectionSub;
  final StreamController<WakeWordDetection> _wakeEvents =
      StreamController<WakeWordDetection>.broadcast();

  VoiceState _state = VoiceState.off;
  String? _errorMessage;
  List<String> _activeWords = const [];

  Timer? _awakeTimer;
  Timer? _resumeTimer;

  /// 認証情報を切らさないための定期的な取り直し。
  Timer? _warmTimer;

  /// Cognito の一時認証情報は約1時間で切れる。切れた状態で呼ばれると
  /// 取り直しで接続が数秒遅れるので、それより短い間隔で取っておく。
  static const Duration _warmInterval = Duration(minutes: 20);

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

  /// 聞き取り中か。
  bool get isTranscribing => _session != null;

  /// 聞き取り中の途中経過。聞き取り中でなければ空。
  ///
  /// 話している間は1秒に数回変わる。ChangeNotifier で流すと
  /// 購読している画面すべてが作り直されるので、別にしてある。
  ValueListenable<String> get heardText => _heard;

  /// 聞き取れた一言。
  ///
  /// 送信するかどうかは画面側で決める。入力欄に書きかけの文があるときや
  /// 応答の生成中は、送らずに入力欄へ入れる方がよいため。
  Stream<String> get utterances => _utterances.stream;

  /// 直前の聞き取りが失敗したときの説明。成功すれば null に戻る。
  String? get sttError => _sttError;

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
      _startWarmUp();

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
    _cancelSession();
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

    final stt = _stt;
    if (stt == null) {
      _awakeTimer?.cancel();
      _awakeTimer = Timer(awakeDuration, _endAwake);
      return;
    }
    unawaited(_listen(stt));
  }

  /// 呼ばれたあとの一言を聞き取る。
  Future<void> _listen(TranscribeSttService stt) async {
    _cancelSession();

    late final SttSession session;
    session = stt.listen(
      onPartial: (text) {
        if (identical(_session, session)) _heard.value = text;
      },
    );
    _session = session;
    _heard.value = '';
    notifyListeners();

    final outcome = await session.outcome;

    // 途中で OFF にされた、またはもう次の聞き取りが始まっている
    if (!identical(_session, session)) return;
    _session = null;
    _heard.value = '';

    switch (outcome.reason) {
      case SttEndReason.completed:
      case SttEndReason.maxDuration:
        _sttError = null;
      case SttEndReason.noSpeech:
        _sttError = null;
        RaimLog.d('[Voice] 何も話されませんでした');
      case SttEndReason.failed:
        _sttError = outcome.error ?? '聞き取りに失敗しました';
      case SttEndReason.cancelled:
        break;
    }

    if (outcome.text.isNotEmpty && !_utterances.isClosed) {
      RaimLog.i('[Voice] 聞き取りました ${outcome.text.length}文字');
      _utterances.add(outcome.text);
    }

    _endAwake();
    // 状態が変わらなかった場合（既に listening 等）も、
    // isTranscribing と sttError の変化を画面に伝える
    if (!_disposed) notifyListeners();
  }

  /// 聞き取りを取り消す。聞き取った分は捨てる。
  void _cancelSession() {
    final session = _session;
    _session = null;
    _heard.value = '';
    session?.cancel();
  }

  /// 呼ばれた状態を終えて待機に戻る。
  ///
  /// 聞き取り中なら、そこまでで話し終わったことにする
  /// （聞き取れた分は utterances に流れる）。
  void endAwake() {
    final session = _session;
    if (session != null) {
      session.finish();
      return;
    }
    _endAwake();
  }

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

  void _startWarmUp() {
    final stt = _stt;
    if (stt == null) return;
    _warmTimer?.cancel();
    unawaited(stt.warmUp());
    _warmTimer = Timer.periodic(_warmInterval, (_) => unawaited(stt.warmUp()));
  }

  void _cancelTimers() {
    _awakeTimer?.cancel();
    _awakeTimer = null;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _warmTimer?.cancel();
    _warmTimer = null;
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
    _cancelSession();
    _heard.dispose();
    unawaited(_detectionSub.cancel());
    unawaited(_wakeEvents.close());
    unawaited(_utterances.close());
    unawaited(_wake.stop());
    super.dispose();
  }
}
