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
//
// 【マイクボタン】
// toggleTalk() で、呼ばずに聞き取りだけを始められる。Vosk を使わないので
// ウェイクワードが OFF でも、iOS でも使える。

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
    VoidCallback? stopSpeaking,
    WakeWordService? wakeWord,
    TranscribeSttService? stt,
  })  : _settings = settings,
        _auth = auth,
        _speaking = speaking,
        _stopSpeaking = stopSpeaking,
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

  /// マイクを替えるときに、閉じてから開き直すまで待つ時間。
  static const Duration micReopenDelay = Duration(milliseconds: 300);

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

  /// ライムの声を止める。聞き取りを始めるときに呼ぶ。
  final VoidCallback? _stopSpeaking;

  final WakeWordService _wake;

  /// 呼ばれたあとの聞き取り。null なら窓を開くだけ。
  final TranscribeSttService? _stt;
  SttSession? _session;
  final ValueNotifier<String> _heard = ValueNotifier<String>('');
  final StreamController<String> _utterances =
      StreamController<String>.broadcast();
  String? _sttError;
  Timer? _sttErrorTimer;

  /// 聞き取りの失敗を表示しておく時間。
  static const Duration sttErrorDuration = Duration(seconds: 6);

  late final StreamSubscription<WakeWordDetection> _detectionSub;
  final StreamController<WakeWordDetection> _wakeEvents =
      StreamController<WakeWordDetection>.broadcast();

  VoiceState _state = VoiceState.off;
  String? _errorMessage;
  List<String> _activeWords = const [];
  String? _activeMicId;
  String? _micWarning;

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

  /// 動いてはいるが知らせておきたいこと（選んだマイクが無い など）。
  String? get micWarning => _micWarning;

  /// 聞き取り（Transcribe）を組み込んであるか。
  bool get hasStt => _stt != null;

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

  /// 直前の聞き取りが失敗したときの説明。しばらくすると null に戻る。
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
    final micChanged = _settings.micDeviceId != _activeMicId;
    final running =
        _state == VoiceState.listening || _state == VoiceState.awake;

    if (running && !wordsChanged && !micChanged) {
      // 聞き取りを後から ON にされたときのため
      if (_settings.sttEnabled && _warmTimer == null) _startWarmUp();
      return;
    }

    // マイクを替えるには一度閉じる（開いたままだと前のマイクのまま）
    if (running && micChanged) {
      await _wake.stop();
      await _releaseMic();
      // 閉じた直後に開き直すと、Windows のオーディオ側の後片付けが
      // 終わる前に次を開くことになる。少しだけ待つ。
      await Future<void>.delayed(micReopenDelay);
      if (_disposed) return;
    }
    await _start(words);
  }

  Future<void> _start(List<String> words) async {
    _cancelTimers();
    _cancelSession();
    _setState(VoiceState.starting);

    final micId = _settings.micDeviceId;
    String? warning;
    try {
      await _startWake(words, micId);
    } catch (e) {
      if (micId == null) {
        await _fail(e);
        return;
      }
      // 選んだマイクが抜かれているなど。既定のマイクで試し直す
      RaimLog.w('[Voice] 選んだマイクを開けなかったので、既定のマイクで試します');
      try {
        await _wake.stop();
        await _releaseMic();
        await _startWake(words, null);
        warning = '選んだマイクが見つからないため、既定のマイクを使っています';
      } catch (e2) {
        await _fail(e2);
        return;
      }
    }

    _activeWords = List.unmodifiable(words);
    // 既定に切り替えた場合も「選ばれた方」を覚えておく。
    // 覚えないと、設定が変わるたびに開けないマイクを試し直すことになる。
    _activeMicId = micId;
    _micWarning = warning;
    _errorMessage = null;
    _setState(VoiceState.listening);
    _startWarmUp();

    // 起動した時点でライムが喋っていれば、すぐ止める
    if (isSpeaking) _wake.suspend();
  }

  Future<void> _startWake(List<String> words, String? micId) async {
    MicStreamService.instance.deviceId = micId;
    await _wake.start(wakeWords: words);
  }

  Future<void> _fail(Object e) async {
    RaimLog.e('[Voice] ウェイクワードを起動できませんでした', e);
    _errorMessage = _describe(e);
    await _releaseMic();
    _setState(VoiceState.error);
  }

  Future<void> _stop() async {
    _cancelTimers();
    _cancelSession();
    await _wake.stop();
    await _releaseMic();
    _activeWords = const [];
    _activeMicId = null;
    _micWarning = null;
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

    final stt = _settings.sttEnabled ? _stt : null;
    if (stt == null) {
      _awakeTimer?.cancel();
      _awakeTimer = Timer(awakeDuration, _endAwake);
      return;
    }
    // 「ねえライム、今日の天気は」と続けて言われていたら、その音から始める
    unawaited(_listen(stt, initialAudio: detection.utterance));
  }

  // ─── マイクボタン ───

  /// マイクボタンで話しかけられるか。
  ///
  /// ウェイクワードと違い iOS でも使える（Vosk を使わないため）。
  bool get canTalk =>
      !kIsWeb &&
      _stt != null &&
      _settings.manualMicEnabled &&
      _auth.isAuthenticated &&
      _state != VoiceState.starting;

  /// マイクボタンが押された。聞き取り中なら話し終わりにし、そうでなければ始める。
  Future<void> toggleTalk() async {
    final session = _session;
    if (session != null) {
      session.finish();
      return;
    }
    final stt = _stt;
    if (stt == null || !canTalk) return;

    _awakeTimer?.cancel();
    _awakeTimer = null;
    if (_state == VoiceState.listening) {
      // 聞き取りの間はウェイクワードを止める（呼ばれたときと同じ扱い）
      _resumeTimer?.cancel();
      _resumeTimer = null;
      _wake.suspend();
      _setState(VoiceState.awake);
    }
    // ウェイクワードを使っていなければマイクはまだ開いていない。
    // 開くときは設定で選んだマイクを使う。
    final mic = MicStreamService.instance;
    if (!mic.isRunning) mic.deviceId = _settings.micDeviceId;

    RaimLog.i('[Voice] マイクボタンで聞き取りを始めます');
    await _listen(stt);
  }

  /// 呼ばれたあと（またはマイクボタンのあと）の一言を聞き取る。
  Future<void> _listen(
    TranscribeSttService stt, {
    Uint8List? initialAudio,
  }) async {
    _cancelSession();

    // ライムが喋っている（またはこれから返答の続きを喋る）と、
    // その声をマイクが拾って、ユーザーの発言として文字にしてしまう。
    // 話しかけられたら黙る。
    _stopSpeaking?.call();

    late final SttSession session;
    session = stt.listen(
      onPartial: (text) {
        if (identical(_session, session)) _heard.value = text;
      },
      initialAudio: initialAudio,
      stripWakePhrase: initialAudio != null,
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
        _setSttError(null);
      case SttEndReason.noSpeech:
        _setSttError(null);
        RaimLog.d('[Voice] 何も話されませんでした');
      case SttEndReason.failed:
        _setSttError(outcome.error ?? '聞き取りに失敗しました');
      case SttEndReason.cancelled:
        break;
    }

    // ウェイクワードを使っていないときにマイクボタンで開いたマイクは閉じる。
    // 起動・停止と同じ列に並べる。並べないと、ちょうど ON にされて
    // ウェイクワードが開いたマイクをここで閉じてしまうことがある。
    _op = _op.then((_) async {
      // 列で待っている間に次のマイクボタン聞き取りが始まっていたら閉じない
      if (_session == null &&
          (_state == VoiceState.off || _state == VoiceState.error)) {
        await _releaseMic();
      }
    }).catchError((Object e) {
      RaimLog.e('[Voice] マイクを閉じられませんでした', e);
    });

    if (outcome.text.isNotEmpty && !_utterances.isClosed) {
      RaimLog.i('[Voice] 聞き取りました ${outcome.text.length}文字');
      _utterances.add(outcome.text);
    }

    _endAwake();
    // 状態が変わらなかった場合（既に listening 等）も、
    // isTranscribing と sttError の変化を画面に伝える
    if (!_disposed) notifyListeners();
  }

  /// 聞き取りの失敗を少しの間だけ見せる。
  ///
  /// 出しっぱなしだと、次に成功するまで入力欄に失敗の表示が残る。
  void _setSttError(String? message) {
    _sttErrorTimer?.cancel();
    _sttErrorTimer = null;
    _sttError = message;
    if (message == null) return;
    _sttErrorTimer = Timer(sttErrorDuration, () {
      _sttErrorTimer = null;
      _sttError = null;
      if (!_disposed) notifyListeners();
    });
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
    if (stt == null || !_settings.sttEnabled) return;
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
    _sttErrorTimer?.cancel();
    _heard.dispose();
    unawaited(_detectionSub.cancel());
    unawaited(_wakeEvents.close());
    unawaited(_utterances.close());
    unawaited(_wake.stop());
    super.dispose();
  }
}

/// 聞き取った文を入力欄へどう入れるかを決める。
///
/// 入力欄が空で、ライムが返事を作っていなければそのまま送る（[send] が true）。
/// 書きかけの文があるときや返事の生成中は、送らずに入力欄の末尾へ足す。
/// 書きかけを消したり、送れずに聞き取った内容が消えたりしないようにするため。
///
/// Windows の入力小窓とスマホの入力欄の両方で同じ動きにするため、ここに置く。
({String text, bool send}) placeUtterance({
  required String typed,
  required String heard,
  required bool busy,
}) {
  final current = typed.trim();
  if (current.isEmpty && !busy) return (text: heard, send: true);
  return (text: current.isEmpty ? heard : '$current $heard', send: false);
}
