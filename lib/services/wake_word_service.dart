// lib/services/wake_word_service.dart
//
// Vosk を使ったウェイクワード検知。
//
// 【なぜ音声認識でウェイクワードをやるか】
// Vosk は本来「何を喋ったか」を全部書き起こすエンジンだが、
// 文法（grammar）を渡すと認識候補をその語だけに絞り込める。
// 探索空間が小さくなるので、専用エンジンに近い軽さと精度で動く。
// 語を変えるのがコード1行で済むため、「ねえライム」への変更や
// 将来の駅名検知にも同じ仕組みが使える。
//
// 【デコイ】
// 文法に「ライム」しか無いと、デコーダは「スライム」を聞いても
// 一番近い選択肢を選ぼうとして `[unk] + ライム` に分解してしまう。
// 実測でこれが起き、しかも conf は正解 0.50 / 誤検知 0.49 と
// 分離できなかった（閾値による足切りが使えない）。
// 紛らわしい語をあらかじめ文法に入れておくと、デコーダはそちらを
// 選ぶようになる。実測では スライム 0.94 / ライムライト 1.00 で
// 正しく認識され、誤検知が 0 になった。
//
// 【判定】
// 完全一致だと厳しすぎる。実測では発話の前後に環境音が乗って
// `[unk] ねえ ライム` や `ねえ らいむ ねえ` になり、正しい発話が
// 落ちた。`[unk]` を除いた単語列の中に、ウェイクワードの単語列が
// 連続して現れるかで判定する。
// デコイがあるため、この緩和をしても誤検知は増えない。
//
// 【続けて話されたとき】
// Vosk は発話の切れ目（無音）で結果を返す。「ねえライム、今日の天気は」と
// 間を空けずに言うと、検知した時点で質問まで言い終わっている。
// そこから Transcribe につないでも質問は聞けないので、Vosk に渡した音を
// 少し溜めておき、ウェイクワードの後ろに続きがあった場合はその発話の音を
// まるごと検知結果に付けて渡す（WakeWordDetection.utterance）。

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

import 'package:raim_prototype/services/mic_stream_service.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/vosk/vosk_engine.dart';

/// 文法に入れるが、検知扱いにはしない語。
///
/// いずれも「ライム」を含むか、それに近い音の語で、
/// vosk-model-small-ja-0.22 の辞書に存在することを確認済み。
const List<String> kWakeDecoys = [
  'スライム',
  'メタルスライム',
  'プライム',
  'サブプライム',
  'クライム',
  'グライム',
  'ヒルクライム',
  'ヘイトクライム',
  'ライムライト',
  'ライムグリーン',
  'ライムスター',
];

/// アセットに置いたモデルの zip。
///
/// 展開済みのディレクトリではなく zip を1ファイル同梱する。
/// モデルは数十ファイルあり、ディレクトリごとアセット登録すると
/// pubspec と各プラットフォームのビルド設定が煩雑になるため。
const String kVoskModelAsset =
    'assets/models/vosk-model-small-ja-0.22.zip';

class WakeWordService {
  WakeWordService._();
  static final WakeWordService instance = WakeWordService._();

  /// Vosk に一度に渡すバイト数（200ms ぶん）。
  ///
  /// record が返すチャンクは Windows 実測で 894 バイト（約28ms）と
  /// 中途半端かつ可変なので、そのまま渡さずここまで溜める。
  /// 細かく渡すと Android では MethodChannel の往復が増えて重い。
  static const int _feedBytes = MicStreamService.sampleRate *
      MicStreamService.bytesPerSample *
      200 ~/
      1000;

  Model? _model;
  Recognizer? _recognizer;
  StreamSubscription<Uint8List>? _micSub;

  final BytesBuilder _pending = BytesBuilder(copy: false);
  int _pendingBytes = 0;

  final StreamController<WakeWordDetection> _detections =
      StreamController<WakeWordDetection>.broadcast();

  List<String> _wakeWords = const [];
  bool _suspended = false;

  /// 認識器への投入を1本の列に並べるためのもの。
  ///
  /// acceptWaveformBytes は Future を返す（Android では MethodChannel を
  /// 通る）。並行に投げると結果の取り出し順が前後しうるので直列にする。
  Future<void> _feeding = Future.value();

  /// 直前の結果の末尾の単語。
  ///
  /// 「ねえ、ライム」と間を空けて言うと、Vosk が発話の区切りと判断して
  /// 「ねえ」と「ライム」を別々の結果で返すことがある。
  /// 直前の結果の末尾と今回の結果をつないで判定するために持っておく。
  List<String> _carry = const [];
  DateTime? _carryAt;

  /// Vosk に渡した音の直近ぶん。続けて話された発話を取り出すために持つ。
  final List<Uint8List> _ring = [];
  int _ringBytes = 0;

  /// [_ring] の先頭が、渡し始めから数えて何バイト目か。
  int _ringStartFed = 0;

  /// 渡し始めてからの合計バイト数。
  int _fedBytes = 0;

  /// 今の発話（Vosk の区切りから次の区切りまで）が始まった位置。
  int _roundStartFed = 0;

  /// 溜めておく長さ。1回の発話としては十分に長い。
  static const int _ringLimit =
      MicStreamService.sampleRate * MicStreamService.bytesPerSample * 12;

  /// 前の結果とつなげてよい間隔。これより空いたら別の発話とみなす。
  static const Duration _carryWindow = Duration(seconds: 2);

  /// ウェイクワードを検知したときに流れる。
  Stream<WakeWordDetection> get detections => _detections.stream;

  bool get isListening => _micSub != null;

  /// 一時停止中か。ライムが喋っている間は true にする。
  bool get isSuspended => _suspended;

  /// モデルを読み込む。初回はアセットの zip を展開するため数秒かかる。
  ///
  /// 展開先を明示しているのは、既定が
  /// `getApplicationDocumentsDirectory()/models` で、Windows では
  /// OneDrive 配下になることがあるため。48MB のモデルが同期対象に
  /// なってしまうので、アプリ専用領域に置く。
  Future<void> initialize() async {
    if (_model != null) return;

    final support = await getApplicationSupportDirectory();
    final storage = '${support.path}${Platform.pathSeparator}vosk';

    final loader = ModelLoader(modelStorage: storage);
    final started = DateTime.now();
    final modelPath = await loader.loadFromAssets(kVoskModelAsset);
    // iOS は本家 vosk_flutter が対応していないので、VoskEngine が
    // アプリに静的リンクした libvosk を FFI で呼ぶ
    _model = await VoskEngine.createModel(modelPath);

    final ms = DateTime.now().difference(started).inMilliseconds;
    RaimLog.i('[WakeWord] モデルを読み込みました (${ms}ms)');
  }

  /// 読み込んだモデル。駅アラームなど、別の文法で認識したい機能と共有する。
  ///
  /// モデルは約48MB あり、読み込みにも時間がかかるので1つだけ持つ。
  /// 認識器（Recognizer）は文法ごとに別に作れる。
  Future<Model> sharedModel() async {
    await initialize();
    return _model!;
  }

  /// 待機を開始する。
  ///
  /// [wakeWords] は VoiceSettingsProvider から渡す。
  /// 既に別の語で待機していれば、認識器を作り直して切り替える。
  Future<void> start({required List<String> wakeWords}) async {
    await initialize();

    final sameWords = _wakeWords.length == wakeWords.length &&
        _wakeWords.every(wakeWords.contains);
    if (isListening && sameWords) return;

    await stop();
    _wakeWords = List.unmodifiable(wakeWords);

    final grammar = <String>[
      ..._wakeWords,
      ...kWakeDecoys.where((d) => !_wakeWords.contains(d)),
      '[unk]',
    ];

    _recognizer = await VoskEngine.createRecognizer(
      model: _model!,
      sampleRate: MicStreamService.sampleRate,
      grammar: grammar,
    );

    final stream = await MicStreamService.instance.start();
    _micSub = stream.listen(
      _onChunk,
      onError: (Object e) => RaimLog.e('[WakeWord] マイクでエラー', e),
      onDone: () {
        // 誰かがマイクを閉じた。待機中のつもりで止まっているのを避ける。
        if (_micSub != null) {
          RaimLog.w('[WakeWord] マイクが閉じられたため待機を終了しました');
          _micSub = null;
        }
      },
    );

    RaimLog.i('[WakeWord] 待機開始 words=$_wakeWords');
  }

  Future<void> stop() async {
    final sub = _micSub;
    _micSub = null;
    await sub?.cancel();

    // 列に残っている投入が終わるのを待ってから認識器を破棄する。
    // Windows では Vosk を FFI で直接呼んでいるため、破棄したあとに
    // 残りの投入が走ると解放済みのメモリを触ってアプリごと落ちる。
    final recognizer = _recognizer;
    _recognizer = null;
    await _feeding.catchError((Object _) {});
    await recognizer?.dispose();

    _pending.clear();
    _pendingBytes = 0;
    _suspended = false;
    _clearCarry();
    _clearRing();
  }

  /// 検知を一時停止する。マイク自体は開けたままにする。
  ///
  /// ライムが喋っている間に呼ぶ。Windows では record のエコー
  /// キャンセルが効かないため、TTS の音声をマイクが拾う。発話に
  /// 「ライム」が含まれると自分の声で自分が起動してしまう。
  ///
  /// マイクを閉じないのは、開き直しに 0.2〜0.5 秒かかり、
  /// 再開直後の発話の頭が欠けるため。
  void suspend() {
    if (_suspended) return;
    _suspended = true;
    RaimLog.d('[WakeWord] 一時停止');
    _pending.clear();
    _pendingBytes = 0;
    _clearCarry();
    // 溜めた音にライムの声が混ざらないよう捨てる
    _clearRing();
    unawaited(_recognizer?.reset());
  }

  void resume() {
    if (!_suspended) return;
    _suspended = false;
    RaimLog.d('[WakeWord] 再開');
  }

  Future<void> dispose() async {
    await stop();
    _model?.dispose();
    _model = null;
    await _detections.close();
  }

  void _onChunk(Uint8List chunk) {
    if (_suspended) return;

    _pending.add(chunk);
    _pendingBytes += chunk.length;
    if (_pendingBytes < _feedBytes) return;

    final buffer = _pending.takeBytes();
    _pendingBytes = 0;

    // 端数は次に回す。フレームの境界がずれると認識精度が落ちる。
    final feedable = buffer.length - (buffer.length % 2);
    final frame = Uint8List.sublistView(buffer, 0, feedable);
    if (feedable < buffer.length) {
      _pending.add(Uint8List.sublistView(buffer, feedable));
      _pendingBytes = buffer.length - feedable;
    }

    _feeding = _feeding.then((_) => _feed(frame));
  }

  Future<void> _feed(Uint8List frame) async {
    final recognizer = _recognizer;
    if (recognizer == null) return;

    // 直列の列に並んでいる間に suspend() されたぶんは捨てる。
    // ライムが喋り出す直前の音が遅れて届くことがあるため。
    if (_suspended) return;

    try {
      _remember(frame);
      final ready = await recognizer.acceptWaveformBytes(frame);
      // await の間に stop() / start() で認識器が差し替わっていたら触らない
      if (!ready || !identical(recognizer, _recognizer)) return;

      final result = await recognizer.getResult();
      if (!identical(recognizer, _recognizer)) return;
      final text = _textOf(result);
      if (text.isEmpty) {
        _roundStartFed = _fedBytes;
        return;
      }

      final tokens = _tokensOf(text);
      final now = DateTime.now();

      // 直前の結果が近ければ、その末尾とつないで判定する。
      // 直前の結果だけでは一致しなかった（一致していれば発火済み）ので、
      // つないで一致した場合は必ず今回の結果にまたがっている。
      final carryAt = _carryAt;
      final joined = (carryAt != null && now.difference(carryAt) <= _carryWindow)
          ? [..._carry, ...tokens]
          : tokens;

      final matched = _matchedWakeWord(joined);
      if (matched == null) {
        _rememberCarry(tokens, now);
        _roundStartFed = _fedBytes;
        RaimLog.d('[WakeWord] 非検知');
        return;
      }

      // ウェイクワードの後ろに続きがあれば、この発話の音をまるごと渡す
      final continued = hasSpeechAfterWakeWord(text, matched);

      // 検知したら状態を捨てる。残っていると次の判定に混ざり、
      // 同じ発話で二重に発火することがある。
      await recognizer.reset();

      // reset を待つ間にマイクから届いた分（_pending）も含めたいので、
      // 捨てる直前に取り出す
      final utterance = continued ? _utteranceAudio() : null;
      _pending.clear();
      _pendingBytes = 0;
      _clearCarry();
      _clearRing();

      RaimLog.i(
        utterance == null
            ? '[WakeWord] 検知しました'
            : '[WakeWord] 検知しました（続けて話された '
                '${(utterance.length / (MicStreamService.sampleRate * MicStreamService.bytesPerSample)).toStringAsFixed(1)}秒）',
      );
      if (!_detections.isClosed) {
        _detections.add(
          WakeWordDetection(
            phrase: matched,
            preroll: MicStreamService.instance.takePreroll(),
            at: DateTime.now(),
            utterance: utterance,
          ),
        );
      }
    } catch (e) {
      RaimLog.e('[WakeWord] 認識に失敗しました', e);
    }
  }

  /// Vosk が返す JSON から text を取り出す。
  String _textOf(String resultJson) {
    try {
      final map = jsonDecode(resultJson) as Map<String, dynamic>;
      return (map['text'] as String? ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  List<String> _tokensOf(String text) => wakeTokensOf(text);

  /// 次の結果とつなぐために、今回の末尾を覚えておく。
  ///
  /// 取っておくのは「ウェイクワードの単語数 - 1」個だけ。
  /// それ以上前の単語は、つないでも一致に関わらない。
  void _rememberCarry(List<String> tokens, DateTime at) {
    final keep = _wakeWords
            .map((w) => _tokensOf(w).length)
            .fold<int>(1, (a, b) => a > b ? a : b) -
        1;
    if (keep <= 0 || tokens.isEmpty) {
      _clearCarry();
      return;
    }
    _carry = tokens.length <= keep
        ? List.unmodifiable(tokens)
        : List.unmodifiable(tokens.sublist(tokens.length - keep));
    _carryAt = at;
  }

  void _clearCarry() {
    _carry = const [];
    _carryAt = null;
  }

  /// Vosk に渡した音を覚えておく。古いものから捨てる。
  void _remember(Uint8List frame) {
    _ring.add(frame);
    _ringBytes += frame.length;
    _fedBytes += frame.length;
    while (_ring.isNotEmpty && _ringBytes - _ring.first.length >= _ringLimit) {
      final old = _ring.removeAt(0);
      _ringBytes -= old.length;
      _ringStartFed += old.length;
    }
  }

  void _clearRing() {
    _ring.clear();
    _ringBytes = 0;
    _ringStartFed = _fedBytes;
    _roundStartFed = _fedBytes;
  }

  /// 今の発話の始まりから今までの音（まだ Vosk に渡していない分も含む）。
  Uint8List _utteranceAudio() {
    final out = BytesBuilder(copy: false);
    var skip = _roundStartFed - _ringStartFed;
    if (skip < 0) skip = 0;
    for (final chunk in _ring) {
      if (skip >= chunk.length) {
        skip -= chunk.length;
        continue;
      }
      out.add(skip == 0 ? chunk : Uint8List.sublistView(chunk, skip));
      skip = 0;
    }
    out.add(_pending.toBytes());
    return out.takeBytes();
  }

  String? _matchedWakeWord(List<String> tokens) =>
      matchWakeWord(tokens, _wakeWords);
}

/// 認識結果を単語列にする。[unk] は判定の邪魔になるので除く。
List<String> wakeTokensOf(String text) => text
    .split(RegExp(r'\s+'))
    .where((t) => t.isNotEmpty && t != '[unk]')
    .toList();

/// 認識結果の中で、ウェイクワードの後ろに何か続いているか。
///
/// 「ねえ ライム [unk] [unk]」のように、ウェイクワードの最後の語より
/// 後ろに語（[unk] を含む）があれば true。[unk] も数えるのは、文法に無い
/// 普通の言葉（「今日の天気は」など）は [unk] として出てくるため。
bool hasSpeechAfterWakeWord(String text, String wakeWord) {
  final raw = text.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  final want = wakeTokensOf(wakeWord);
  if (want.isEmpty) return false;
  final last = raw.lastIndexOf(want.last);
  return last >= 0 && last < raw.length - 1;
}

/// 単語列の中に、ウェイクワードの単語列が連続して現れるか。
/// 一致したウェイクワードを返す。無ければ null。
///
/// 部分文字列ではなく単語単位で比べるのが要点。文字列で見ると
/// 「ライムライト」が「ライム」に一致してしまうが、単語列なら
/// ['ライムライト'] と ['ライム'] で一致しない。
///
/// Vosk に依存しない純粋な関数にしてあるのはテストするため。
String? matchWakeWord(List<String> tokens, List<String> wakeWords) {
  if (tokens.isEmpty) return null;

  for (final wake in wakeWords) {
    final want = wakeTokensOf(wake);
    if (want.isEmpty || want.length > tokens.length) continue;

    for (var i = 0; i + want.length <= tokens.length; i++) {
      var hit = true;
      for (var j = 0; j < want.length; j++) {
        if (tokens[i + j] != want[j]) {
          hit = false;
          break;
        }
      }
      if (hit) return wake;
    }
  }
  return null;
}

/// ウェイクワードを検知したことを表す。
class WakeWordDetection {
  const WakeWordDetection({
    required this.phrase,
    required this.preroll,
    required this.at,
    this.utterance,
  });

  /// 一致したウェイクワード。
  final String phrase;

  /// 「ねえライム、今日の天気は」のように続けて話されたときの、その発話の
  /// 音声（16bit PCM、ウェイクワードの部分も含む）。続きが無ければ null。
  final Uint8List? utterance;

  /// 検知の直前までの音声（16bit PCM）。
  ///
  /// 検知した時点では続きの発話がもう始まっているため、
  /// これを先頭に付けてから STT に流さないと頭が欠ける。
  final Uint8List preroll;

  final DateTime at;
}
