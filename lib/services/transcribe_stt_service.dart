// lib/services/transcribe_stt_service.dart
//
// 「ねえライム」と呼ばれたあとの一言を、Amazon Transcribe で文字にする。
//
// 【流れ】
//   1. マイクの音を受け取り始める（接続を待つ間の音も取っておく）
//   2. Cognito の一時認証情報で署名付き URL を作り、WebSocket でつなぐ
//   3. 100ms ずつ音声を送り、途中経過と確定結果を受け取る
//   4. 話し終わったら「終わり」の合図を送り、残りの確定結果を待って閉じる
//
// 【いつ終えるか】
// Transcribe は「話し終わった」とは教えてくれない。届いた文字の変化を見て
// こちらで判断する（SttTiming）。
//   - 最後に文字が増えてから少し静かなら終わり
//   - 何も話されないまま数秒たったら、呼び間違いとみなして終わり
//
// 【料金】
// Transcribe は接続している時間で課金される（1回あたり最低15秒）。
// 無音でもつないでいる間は課金されるので、話し終わったらすぐ閉じる。
// 呼び出されていない間は一切つながない。
//
// 【ログ】
// 文字起こしの本文は会話の内容そのものなので出さない。長さだけ出す。
// 接続失敗の例外も中身は出さない。メッセージに署名付き URL
// （一時的な認証情報入り）が含まれることがあるため。

import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:raim_prototype/services/aws/cognito_credentials_provider.dart';
import 'package:raim_prototype/services/aws/event_stream.dart';
import 'package:raim_prototype/services/aws/transcribe_events.dart';
import 'package:raim_prototype/services/aws/transcribe_presigner.dart';
import 'package:raim_prototype/services/mic_stream_service.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// 聞き取りが終わった理由。
enum SttEndReason {
  /// 話し終わった
  completed,

  /// 何も話されなかった（呼び間違いなど）
  noSpeech,

  /// 長すぎたので打ち切った
  maxDuration,

  /// 呼び出し側が取り消した
  cancelled,

  /// 接続できなかった、または Transcribe がエラーを返した
  failed,
}

/// 聞き取りの結果。
class SttOutcome {
  const SttOutcome({required this.text, required this.reason, this.error});

  /// 聞き取れた文字。無ければ空。
  final String text;
  final SttEndReason reason;

  /// 失敗したときの、ユーザーに見せてよい説明。
  final String? error;

  @override
  String toString() => 'SttOutcome(${reason.name}, ${text.length}文字)';
}

/// 終わりどきの判断に使う時間。
class SttTiming {
  const SttTiming({
    this.noSpeechTimeout = const Duration(seconds: 6),
    this.endSilence = const Duration(milliseconds: 1200),
    this.partialSilence = const Duration(milliseconds: 2500),
    this.maxDuration = const Duration(seconds: 20),
    this.presignTimeout = const Duration(seconds: 10),
    this.connectTimeout = const Duration(seconds: 5),
    this.finalWait = const Duration(milliseconds: 2500),
    this.tick = const Duration(milliseconds: 100),
  });

  /// つながってからこの時間、何の文字も出なければ終える。
  ///
  /// 「呼ばれてから」ではなく「つながってから」数える。初回は認証情報の
  /// 取得で接続に数秒かかり、その間の音声は溜めておいて接続後に送るため。
  /// 呼ばれてから数えると、普通に話していても結果が返る前に打ち切ってしまう。
  final Duration noSpeechTimeout;

  /// 全部が確定してから、この時間新しい文字が無ければ終える。
  ///
  /// 確定結果は Transcribe が「間が空いた」と判断したときに出るので、
  /// ここは短めでよい。長くすると、話し終えてからライムが反応するまでが遅い。
  final Duration endSilence;

  /// 途中経過のまま止まっているときに待つ時間。
  ///
  /// 確定が来ないまま文字が変わらないのは、話し終えたのに
  /// Transcribe がまだ区切りを付けていない状態。少し長めに待つ。
  final Duration partialSilence;

  /// 1回の聞き取りの上限（つながってから数える）。
  final Duration maxDuration;

  /// 認証情報の用意（Cognito への問い合わせ）を待つ上限。
  final Duration presignTimeout;

  /// WebSocket の接続を待つ上限。
  final Duration connectTimeout;

  /// 「終わり」の合図を送ってから、残りの確定結果を待つ上限。
  final Duration finalWait;

  /// 終わりどきを確かめる間隔。
  final Duration tick;

  /// 終えるべきなら理由を返す。まだなら null。
  ///
  /// [elapsed] はつながってからの時間。
  /// [sinceLastText] は最後に文字が変わってからの時間。
  /// まだ一度も文字が出ていなければ null。
  SttEndReason? decide({
    required Duration elapsed,
    required Duration? sinceLastText,
    required bool hasPartial,
  }) {
    if (elapsed >= maxDuration) return SttEndReason.maxDuration;
    if (sinceLastText == null) {
      return elapsed >= noSpeechTimeout ? SttEndReason.noSpeech : null;
    }
    final quiet = hasPartial ? partialSilence : endSilence;
    return sinceLastText >= quiet ? SttEndReason.completed : null;
  }
}

/// 届いた結果をつなげて、今の時点の文字にする。
///
/// 同じ ResultId の結果は、途中経過で何度も届いたあと確定版で置き換わる。
/// 違う ResultId は、話の区切りごとの別の文。届いた順につなげる。
class TranscriptAccumulator {
  final List<String> _order = [];
  final Map<String, TranscriptResult> _results = {};

  void add(TranscriptResult result) {
    final id = result.resultId;
    if (id.isEmpty) return;
    if (!_results.containsKey(id)) _order.add(id);
    _results[id] = result;
  }

  /// 日本語なので区切りの空白は入れない。
  String get text => _order
      .map((id) => _results[id]!.text.trim())
      .where((t) => t.isNotEmpty)
      .join();

  /// まだ確定していない結果があるか。
  bool get hasPartial => _results.values.any((r) => r.isPartial);
}

/// WebSocket の差し替え口（テストで偽物を使うため）。
abstract class SttSocket {
  /// 接続できたら完了する。
  Future<void> get ready;

  /// 受け取ったデータ。バイナリは `List<int>` で届く。
  Stream<dynamic> get stream;

  void add(Uint8List data);

  Future<void> close();
}

typedef SttSocketConnector = SttSocket Function(Uri uri);

class _WebSocketSttSocket implements SttSocket {
  _WebSocketSttSocket(Uri uri) : _channel = WebSocketChannel.connect(uri);

  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void add(Uint8List data) => _channel.sink.add(data);

  @override
  Future<void> close() async {
    await _channel.sink.close();
  }
}

class TranscribeSttService {
  TranscribeSttService({
    Future<String?> Function()? idTokenGetter,
    CognitoCredentialsProvider? credentials,
    Future<Uri> Function()? presign,
    SttSocketConnector? connect,
    Future<Stream<Uint8List>> Function()? openMic,
    this.timing = const SttTiming(),
    DateTime Function()? clock,
  })  : assert(
          presign != null || idTokenGetter != null,
          'idTokenGetter か presign のどちらかが必要です',
        ),
        _idTokenGetter = idTokenGetter,
        _credentials = credentials ?? CognitoCredentialsProvider.instance,
        _presignOverride = presign,
        _connect = connect ?? _WebSocketSttSocket.new,
        _openMic = openMic ?? MicStreamService.instance.start,
        _clock = clock ?? DateTime.now;

  /// 1回に送る音声の量（100ms ぶん）。AWS の推奨は 50〜200ms。
  static const int chunkBytes = MicStreamService.sampleRate *
      MicStreamService.bytesPerSample *
      100 ~/
      1000;

  final Future<String?> Function()? _idTokenGetter;
  final CognitoCredentialsProvider _credentials;
  final Future<Uri> Function()? _presignOverride;
  final SttSocketConnector _connect;
  final Future<Stream<Uint8List>> Function() _openMic;
  final DateTime Function() _clock;
  final SttTiming timing;

  /// 認証情報を先に取っておく。
  ///
  /// 取得には Cognito への2往復で数秒かかる。呼ばれてから取りに行くと
  /// そのぶん接続が遅れるので、待機を始めたときに済ませておく。
  /// 一度取れば失効の5分前まで使い回されるので、何度呼んでも軽い。
  Future<void> warmUp() async {
    if (_presignOverride != null) return;
    try {
      final token = await _idTokenGetter!();
      if (token == null || token.isEmpty) return;
      await _credentials.getCredentials(token);
    } catch (e) {
      // 呼ばれたときにもう一度試すので、ここでは記録だけ
      RaimLog.w('[STT] 認証情報の事前取得に失敗しました: ${e.runtimeType}');
    }
  }

  /// 聞き取りを始める。
  ///
  /// [onPartial] には、話している途中の文字が変わるたびに今の全文が届く。
  ///
  /// [initialAudio] は、マイクより先に送る音声。「ねえライム、今日の天気は」と
  /// 続けて話されたとき、既に話し終えた部分を渡す。
  /// [stripWakePhrase] なら、結果の先頭の「ねえライム」を取り除く。
  SttSession listen({
    void Function(String text)? onPartial,
    Uint8List? initialAudio,
    bool stripWakePhrase = false,
  }) {
    final session = SttSession._(this, onPartial, stripWakePhrase);
    if (initialAudio != null && initialAudio.isNotEmpty) {
      session._audio.add(initialAudio);
    }
    unawaited(session._start());
    return session;
  }

  Future<Uri> _presign() async {
    final override = _presignOverride;
    if (override != null) return override();

    final token = await _idTokenGetter!();
    if (token == null || token.isEmpty) {
      throw StateError('ログインが必要です');
    }
    final credentials = await _credentials.getCredentials(token);
    return TranscribePresigner.presign(
      credentials: credentials,
      sampleRate: MicStreamService.sampleRate,
    );
  }
}

/// 1回ぶんの聞き取り。
class SttSession {
  SttSession._(this._service, this._onPartial, this._strip);

  final TranscribeSttService _service;
  final void Function(String text)? _onPartial;
  final bool _strip;

  final Completer<SttOutcome> _outcome = Completer<SttOutcome>();
  final TranscriptAccumulator _transcript = TranscriptAccumulator();
  final EventStreamDecoder _decoder = EventStreamDecoder();

  /// まだ送っていない音声。
  final BytesBuilder _audio = BytesBuilder(copy: false);

  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<dynamic>? _socketSub;
  SttSocket? _socket;
  Completer<void>? _socketClosed;
  Timer? _ticker;

  late final DateTime _startedAt;
  DateTime? _connectedAt;
  DateTime? _lastTextAt;
  bool _connected = false;
  bool _ending = false;

  SttTiming get _timing => _service.timing;

  /// 終わったら完了する。失敗しても例外にはならず、reason で分かる。
  Future<SttOutcome> get outcome => _outcome.future;

  /// 今の時点で聞き取れている文字。
  String get text =>
      _strip ? stripWakePhrase(_transcript.text) : _transcript.text;

  bool get isDone => _outcome.isCompleted;

  /// 取り消す。聞き取った文字は捨てる。
  void cancel() => unawaited(_end(SttEndReason.cancelled));

  /// 今の時点で話し終わったことにする（ボタンで止めたときなど）。
  void finish() => unawaited(_end(SttEndReason.completed));

  Future<void> _start() async {
    _startedAt = _service._clock();
    _ticker = Timer.periodic(_timing.tick, (_) => _check());

    // 1. マイク
    try {
      final mic = await _service._openMic();
      if (_ending) return;
      _micSub = mic.listen(
        _onMic,
        onError: (Object e) {
          RaimLog.e('[STT] マイクでエラー', e.runtimeType);
          unawaited(_end(SttEndReason.failed, 'マイクを使えませんでした'));
        },
      );
    } catch (e) {
      RaimLog.e('[STT] マイクを開けませんでした', e.runtimeType);
      await _end(SttEndReason.failed, 'マイクを使えませんでした');
      return;
    }

    // 2. 署名付き URL
    final Uri uri;
    try {
      uri = await _service._presign().timeout(_timing.presignTimeout);
    } catch (e) {
      RaimLog.e('[STT] 認証情報を用意できませんでした', e.runtimeType);
      await _end(SttEndReason.failed, 'AWS の認証に失敗しました');
      return;
    }
    if (_ending) return;
    final presignedAt = _service._clock();

    // 3. 接続
    try {
      final socket = _service._connect(uri);
      _socket = socket;
      final closed = Completer<void>();
      _socketClosed = closed;
      _socketSub = socket.stream.listen(
        _onSocketData,
        onError: (Object e) {
          RaimLog.e('[STT] 通信でエラー', e.runtimeType);
          unawaited(_end(SttEndReason.failed, 'Transcribe との通信が切れました'));
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
          if (_ending) return;
          // 途中で切られた。聞き取れた分があればそれを使う。
          RaimLog.w('[STT] Transcribe から接続が閉じられました');
          unawaited(_end(
            text.isEmpty
                ? SttEndReason.failed
                : SttEndReason.completed,
            'Transcribe との接続が閉じられました',
          ));
        },
        cancelOnError: true,
      );

      await socket.ready.timeout(_timing.connectTimeout);
    } catch (e) {
      // 権限不足（403）もここに来る。キャッシュした認証情報が古い可能性も
      // あるので捨てておく。次回は取り直す。
      _service._credentials.clear();
      RaimLog.e(
        '[STT] Transcribe に接続できませんでした',
        '${e.runtimeType}${_handshakeStatus(e)}',
      );
      await _end(SttEndReason.failed, 'Transcribe に接続できませんでした');
      return;
    }
    if (_ending) return;

    _connected = true;
    final connectedAt = _service._clock();
    _connectedAt = connectedAt;
    final auth = presignedAt.difference(_startedAt).inMilliseconds;
    final connect = connectedAt.difference(presignedAt).inMilliseconds;
    RaimLog.d('[STT] 接続しました (認証 ${auth}ms / 接続 ${connect}ms)');

    // 接続を待つ間に溜まった音声をまとめて送る
    _flush();
  }

  void _onMic(Uint8List chunk) {
    if (_ending) return;
    _audio.add(chunk);
    if (_connected && _audio.length >= TranscribeSttService.chunkBytes) {
      _flush();
    }
  }

  /// 溜まった音声を 100ms ずつ送る。[all] なら端数も送る。
  void _flush({bool all = false}) {
    final socket = _socket;
    if (socket == null || !_connected || _audio.isEmpty) return;

    final bytes = _audio.takeBytes();
    const size = TranscribeSttService.chunkBytes;
    var offset = 0;
    while (bytes.length - offset >= size) {
      _send(socket, Uint8List.sublistView(bytes, offset, offset + size));
      offset += size;
    }
    if (offset < bytes.length) {
      final rest = Uint8List.sublistView(bytes, offset);
      if (all) {
        _send(socket, rest);
      } else {
        _audio.add(Uint8List.fromList(rest));
      }
    }
  }

  void _send(SttSocket socket, Uint8List pcm) {
    try {
      socket.add(TranscribeAudio.event(pcm));
    } catch (e) {
      RaimLog.e('[STT] 送信に失敗しました', e.runtimeType);
      unawaited(_end(SttEndReason.failed, 'Transcribe との通信が切れました'));
    }
  }

  void _onSocketData(dynamic data) {
    if (data is! List<int>) return;

    try {
      for (final message in _decoder.add(data)) {
        final event = TranscribeEvent.parse(message);
        switch (event) {
          case TranscriptEvent(:final results):
            final before = text;
            results.forEach(_transcript.add);
            final now = text;
            if (now != before && now.isNotEmpty) {
              _lastTextAt = _service._clock();
              _onPartial?.call(now);
            }
          case TranscribeFailure(:final type, :final message):
            RaimLog.e('[STT] Transcribe がエラーを返しました: $type');
            // 説明文は「15秒間音声が届かなかった」などの理由で、
            // 話した内容は含まれない。原因を追うために debug で出す。
            if (message.isNotEmpty) RaimLog.d('[STT] $message');
            unawaited(_end(SttEndReason.failed, _describeFailure(type)));
          case null:
            break;
        }
      }
    } on FormatException catch (e) {
      RaimLog.e('[STT] 応答を読めませんでした', e.message);
      unawaited(_end(SttEndReason.failed, 'Transcribe の応答を読めませんでした'));
    }
  }

  void _check() {
    if (_ending) return;

    // つながるまでは判断しない（認証と接続はそれぞれの上限で見ている）
    final connectedAt = _connectedAt;
    if (connectedAt == null) return;

    final now = _service._clock();
    final last = _lastTextAt;
    final reason = _timing.decide(
      elapsed: now.difference(connectedAt),
      sinceLastText: last == null ? null : now.difference(last),
      hasPartial: _transcript.hasPartial,
    );
    if (reason != null) unawaited(_end(reason));
  }

  Future<void> _end(SttEndReason reason, [String? error]) async {
    if (_ending) return;
    _ending = true;
    _ticker?.cancel();
    _ticker = null;

    final mic = _micSub;
    _micSub = null;
    await mic?.cancel();

    final socket = _socket;
    final finalize = reason == SttEndReason.completed ||
        reason == SttEndReason.maxDuration;

    // 話し終わりなら、残りの音声と「終わり」を送って確定結果を待つ。
    // 送らずに閉じると、最後の一言が途中経過のまま捨てられる。
    if (socket != null && _connected && finalize) {
      _flush(all: true);
      try {
        socket.add(TranscribeAudio.endOfStream());
        await _socketClosed?.future.timeout(
          _timing.finalWait,
          onTimeout: () {},
        );
      } catch (e) {
        RaimLog.w('[STT] 終わりの合図を送れませんでした');
      }
    }

    await _socketSub?.cancel();
    _socketSub = null;
    try {
      // 相手が応じないと close は返ってこないので、待つのは少しだけ
      await socket?.close().timeout(
            const Duration(seconds: 2),
            onTimeout: () {},
          );
    } catch (_) {
      // 既に閉じている
    }

    final heard = reason == SttEndReason.cancelled ? '' : text;
    final outcome = SttOutcome(text: heard, reason: reason, error: error);
    final seconds =
        _service._clock().difference(_startedAt).inMilliseconds / 1000;
    RaimLog.i(
      '[STT] 終了 ${reason.name} ${heard.length}文字 '
      '(${seconds.toStringAsFixed(1)}秒)',
    );
    if (!_outcome.isCompleted) _outcome.complete(outcome);
  }

  /// 接続時の HTTP ステータスだけを取り出す（` (HTTP 403)` の形）。
  ///
  /// 例外のメッセージには署名付き URL（一時認証情報入り）がそのまま
  /// 入っているので、全体は出さない。403 なら権限か時計のずれ、
  /// 取れなければ通信の問題、と切り分けられる。
  static String _handshakeStatus(Object e) {
    final code =
        RegExp(r'status code:?\s*(\d{3})').firstMatch(e.toString())?.group(1);
    return code == null ? '' : ' (HTTP $code)';
  }

  String _describeFailure(String type) {
    switch (type) {
      case 'LimitExceededException':
        return '同時に使える数を超えました。少し待ってください';
      case 'InternalFailureException':
      case 'ServiceUnavailableException':
        return 'Transcribe が一時的に使えません';
      default:
        return '聞き取りに失敗しました';
    }
  }
}

/// 先頭の呼びかけ（「ねえライム」など）を取り除く。
///
/// 「ねえライム、今日の天気は」を続けて話したときは発話全体を Transcribe に
/// 送るので、結果の頭に呼びかけが付いてくる。そのまま送るとライムへの
/// 質問に「ねえライム」が混ざるので落とす。
/// 表記は Transcribe の出方に合わせて幅を持たせる（ねえ／ねぇ／ねー、
/// 読点の有無、ライム／らいむ／RAiM）。
String stripWakePhrase(String text) {
  final stripped = text.replaceFirst(_wakePrefix, '');
  return stripped.trim();
}

final RegExp _wakePrefix = RegExp(
  r'^\s*(?:ねえ|ねぇ|ねー|ね)?[、,，\s]*(?:ライム|らいむ|raim)(?:さん|ちゃん)?'
  r'[、。,，.!！?？\s]*',
  caseSensitive: false,
);
