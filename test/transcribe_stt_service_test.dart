import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/aws/event_stream.dart';
import 'package:raim_prototype/services/aws/transcribe_events.dart';
import 'package:raim_prototype/services/transcribe_stt_service.dart';

/// Transcribe の代わり。送られたものを記録し、こちらから結果を返す。
class _FakeSocket implements SttSocket {
  _FakeSocket({this.failToConnect = false});

  final bool failToConnect;
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final List<EventStreamMessage> sent = [];
  bool closed = false;

  /// 「終わり」の合図を受け取ったら返す確定結果。
  List<TranscriptResult> finalOnEnd = const [];

  @override
  Future<void> get ready => failToConnect
      ? Future.error(Exception('403 wss://secret-url'))
      : Future.value();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  void add(Uint8List data) {
    final message = EventStreamDecoder.decode(data);
    sent.add(message);
    if (message.payload.isEmpty) {
      if (finalOnEnd.isNotEmpty) reply(finalOnEnd);
      // 本物も、終わりの合図のあと確定結果を返して閉じる
      unawaited(_incoming.close());
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  void reply(List<TranscriptResult> results) {
    final json = {
      'Transcript': {
        'Results': [
          for (final r in results)
            {
              'ResultId': r.resultId,
              'IsPartial': r.isPartial,
              'StartTime': r.startTime,
              'EndTime': r.endTime,
              'Alternatives': [
                {
                  'Transcript': r.text,
                  'Items': [
                    for (final i in r.items)
                      {
                        'Content': i.content,
                        'StartTime': i.startTime,
                        'EndTime': i.endTime,
                        'Type': i.isPunctuation ? 'punctuation' : 'pronunciation',
                        if (i.speaker != null) 'Speaker': i.speaker,
                      },
                  ],
                },
              ],
            },
        ],
      },
    };
    _incoming.add(EventStreamEncoder.encode(
      const {
        ':event-type': 'TranscriptEvent',
        ':content-type': 'application/json',
        ':message-type': 'event',
      },
      utf8.encode(jsonEncode(json)),
    ));
  }

  void replyException(String type) {
    _incoming.add(EventStreamEncoder.encode(
      {
        ':exception-type': type,
        ':content-type': 'application/json',
        ':message-type': 'exception',
      },
      utf8.encode(jsonEncode({'Message': 'x'})),
    ));
  }

  /// 送った音声の合計バイト数（終わりの合図を除く）。
  int get audioBytes => sent.fold(0, (sum, m) => sum + m.payload.length);

  bool get sentEndOfStream => sent.isNotEmpty && sent.last.payload.isEmpty;
}

TranscriptResult _r(String id, String text, {bool partial = false}) =>
    TranscriptResult(
      resultId: id,
      text: text,
      isPartial: partial,
      startTime: 0,
      endTime: 0,
    );

/// 話者付きの結果。[words] は (語, 話者, 始まりの秒)。話者が null なら句読点。
TranscriptResult _spk(String id, List<(String, String?, double)> words,
    {bool partial = false}) {
  final items = [
    for (final w in words)
      TranscriptItem(
        content: w.$1,
        startTime: w.$3,
        endTime: w.$3 + 0.2,
        speaker: w.$2,
        isPunctuation: w.$2 == null,
      ),
  ];
  return TranscriptResult(
    resultId: id,
    text: items.map((i) => i.content).join(),
    isPartial: partial,
    startTime: 0,
    endTime: 0,
    items: items,
  );
}

/// テスト用に短くした時間。
const _fast = SttTiming(
  noSpeechTimeout: Duration(milliseconds: 300),
  endSilence: Duration(milliseconds: 120),
  partialSilence: Duration(milliseconds: 250),
  maxDuration: Duration(seconds: 3),
  connectTimeout: Duration(milliseconds: 500),
  finalWait: Duration(milliseconds: 300),
  tick: Duration(milliseconds: 20),
);

void main() {
  group('TranscriptAccumulator', () {
    test('同じ ResultId は置き換え、違う ResultId はつなげる', () {
      final acc = TranscriptAccumulator()
        ..add(_r('a', '今日の', partial: true))
        ..add(_r('a', '今日の天気は？'))
        ..add(_r('b', '傘いる？', partial: true));
      expect(acc.text, '今日の天気は？傘いる？');
      expect(acc.hasPartial, isTrue);

      acc.add(_r('b', '傘いるかな？'));
      expect(acc.text, '今日の天気は？傘いるかな？');
      expect(acc.hasPartial, isFalse);
    });

    test('空の結果は無視する', () {
      final acc = TranscriptAccumulator()
        ..add(_r('', 'x'))
        ..add(_r('a', '  '));
      expect(acc.text, '');
    });
  });

  group('呼んだ人の言葉だけ残す（TranscriptAccumulator）', () {
    test('先頭で「ライム」と言った人を呼んだ人とみなす', () {
      final t = TranscriptAccumulator()
        ..add(_spk('a', [
          ('えっと', '1', 0.0),
          ('ねえ', '0', 0.3),
          ('ライム', '0', 0.6),
          ('明日', '0', 1.5),
        ]));
      expect(t.callerSpeaker(until: 1.0), '0');
    });

    test('「ライム」が無ければ、先頭で一番多く話した人', () {
      final t = TranscriptAccumulator()
        ..add(_spk('a', [
          ('ねえ', '1', 0.1),
          ('ね', '1', 0.4),
          ('明日', '0', 0.8),
          ('天気', '0', 1.5),
        ]));
      expect(t.callerSpeaker(until: 1.0), '1');
    });

    test('話者が付いていなければ分からない', () {
      final t = TranscriptAccumulator()..add(_r('a', 'ねえライム'));
      expect(t.callerSpeaker(until: 1.0), isNull);
    });

    test('ほかの人の語と、その後ろの句読点を捨てる', () {
      final t = TranscriptAccumulator()
        ..add(_spk('a', [
          ('明日', '0', 1.0),
          ('の', '0', 1.2),
          ('天気', '0', 1.4),
          ('は', '0', 1.6),
          ('？', null, 1.7),
        ]))
        ..add(_spk('b', [
          ('ラーメン', '1', 2.0),
          ('食べ', '1', 2.3),
          ('よう', '1', 2.5),
          ('。', null, 2.6),
        ]));
      expect(t.textOf('0'), '明日の天気は？');
      expect(t.textOf('1'), 'ラーメン食べよう。');
      expect(t.speakers, {'0', '1'});
    });

    test('話者の付いていない途中経過は、判断できないのでそのまま入れる', () {
      final t = TranscriptAccumulator()
        ..add(_spk('a', [('明日', '0', 1.0)]))
        ..add(_r('b', 'ラーメン', partial: true));
      expect(t.textOf('0'), '明日ラーメン');
    });
  });

  group('SttTiming.decide', () {
    const t = SttTiming();
    Duration s(double sec) => Duration(milliseconds: (sec * 1000).round());

    test('何も話されないまま時間切れ', () {
      expect(
        t.decide(elapsed: s(5.9), sinceLastText: null, hasPartial: false),
        isNull,
      );
      expect(
        t.decide(elapsed: s(6), sinceLastText: null, hasPartial: false),
        SttEndReason.noSpeech,
      );
    });

    test('確定してから少し静かなら終わり', () {
      expect(
        t.decide(elapsed: s(3), sinceLastText: s(1.1), hasPartial: false),
        isNull,
      );
      expect(
        t.decide(elapsed: s(3), sinceLastText: s(1.2), hasPartial: false),
        SttEndReason.completed,
      );
    });

    test('途中経過のままなら長めに待つ', () {
      expect(
        t.decide(elapsed: s(3), sinceLastText: s(2), hasPartial: true),
        isNull,
      );
      expect(
        t.decide(elapsed: s(3), sinceLastText: s(2.5), hasPartial: true),
        SttEndReason.completed,
      );
    });

    test('話し続けても上限で打ち切る', () {
      expect(
        t.decide(elapsed: s(20), sinceLastText: s(0.1), hasPartial: true),
        SttEndReason.maxDuration,
      );
    });
  });

  group('SttSession', () {
    late StreamController<Uint8List> mic;
    late _FakeSocket socket;
    late Completer<Uri> presign;

    TranscribeSttService service({bool failToConnect = false}) {
      socket = _FakeSocket(failToConnect: failToConnect);
      return TranscribeSttService(
        presign: () => presign.future,
        connect: (_) => socket,
        openMic: () async => mic.stream,
        timing: _fast,
      );
    }

    setUp(() {
      mic = StreamController<Uint8List>.broadcast();
      presign = Completer<Uri>();
    });

    tearDown(() => mic.close());

    test('接続前の音声も送り、話し終わりで確定結果を返す', () async {
      final partials = <String>[];
      final session = service().listen(onPartial: partials.add);
      await Future<void>.delayed(Duration.zero);

      // 接続を待っている間に話し始めた（5000 バイト）
      mic.add(Uint8List(3000));
      mic.add(Uint8List(2000));

      presign.complete(Uri.parse('wss://example.com'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 100ms（3200 バイト）ずつ送る。端数は次に回す
      expect(socket.audioBytes, 3200);
      expect(socket.sent.first.stringHeader(':event-type'), 'AudioEvent');

      socket.reply([_r('a', 'こんにち', partial: true)]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      socket.reply([_r('a', 'こんにちは', partial: true)]);
      socket.finalOnEnd = [_r('a', 'こんにちは。')];

      final outcome = await session.outcome;
      expect(outcome.reason, SttEndReason.completed);
      expect(outcome.text, 'こんにちは。');
      // 途中経過のたびと、最後の確定で届く
      expect(partials, ['こんにち', 'こんにちは', 'こんにちは。']);

      // 端数も送ってから「終わり」を送っている
      expect(socket.sentEndOfStream, isTrue);
      expect(socket.audioBytes, 5000);
      expect(socket.closed, isTrue);
      expect(mic.hasListener, isFalse);
    });

    test('接続が遅くても、つながる前に話した分で打ち切らない', () async {
      // 初回は認証情報の取得で数秒かかる。その間の音声は溜めて後で送る。
      // 無言の判定を「呼ばれてから」数えていたため、実機で
      // 普通に話したのに noSpeech で終わっていた。
      final session = service().listen();
      await Future<void>.delayed(Duration.zero);
      mic.add(Uint8List(6400));

      // 無言判定（300ms）より長く待たせてからつなぐ
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(session.isDone, isFalse);
      presign.complete(Uri.parse('wss://example.com'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      socket.reply([_r('a', '今日の天気は？')]);
      final outcome = await session.outcome;
      expect(outcome.reason, SttEndReason.completed);
      expect(outcome.text, '今日の天気は？');
      expect(socket.audioBytes, 6400);
    });

    test('続けて話された音から始め、先頭の呼びかけを落とす', () async {
      socket = _FakeSocket();
      final stt = TranscribeSttService(
        presign: () => presign.future,
        connect: (_) => socket,
        openMic: () async => mic.stream,
        timing: _fast,
      );
      final partials = <String>[];
      final session = stt.listen(
        onPartial: partials.add,
        initialAudio: Uint8List(8000),
        stripWakePhrase: true,
      );
      presign.complete(Uri.parse('wss://example.com'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 溜めておいた音を先に送っている（100ms 単位、端数は後で）
      expect(socket.audioBytes, 6400);

      socket.reply([_r('a', 'ねえ、ライム', partial: true)]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      socket.reply([_r('a', 'ねえ、ライム、今日の天気は？')]);

      final outcome = await session.outcome;
      expect(outcome.text, '今日の天気は？');
      // 呼びかけだけの途中経過は出さない
      expect(partials, ['今日の天気は？']);
    });

    test('呼んだ人の言葉だけ残す', () async {
      socket = _FakeSocket();
      final stt = TranscribeSttService(
        presign: () => presign.future,
        connect: (_) => socket,
        openMic: () async => mic.stream,
        timing: _fast,
      );
      // 先頭の 1 秒が「ねえライム」の音
      final session = stt.listen(
        initialAudio: Uint8List(32000),
        stripWakePhrase: true,
        callerOnly: true,
      );
      presign.complete(Uri.parse('wss://example.com'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      socket.reply([
        _spk('a', [
          ('ねえ', '0', 0.1),
          ('ライム', '0', 0.4),
          ('、', null, 0.6),
          ('明日', '0', 1.3),
          ('の', '0', 1.5),
          ('天気', '0', 1.6),
          ('は', '0', 1.8),
          ('？', null, 1.9),
        ]),
        _spk('b', [
          ('ラーメン', '1', 1.4),
          ('食べ', '1', 1.7),
          ('よう', '1', 1.9),
          ('。', null, 2.0),
        ]),
      ]);

      final outcome = await session.outcome;
      expect(outcome.text, '明日の天気は？');
    });

    test('話者が付いてこなければ、今までどおり全部使う', () async {
      socket = _FakeSocket();
      final stt = TranscribeSttService(
        presign: () => presign.future,
        connect: (_) => socket,
        openMic: () async => mic.stream,
        timing: _fast,
      );
      final session = stt.listen(
        initialAudio: Uint8List(32000),
        stripWakePhrase: true,
        callerOnly: true,
      );
      presign.complete(Uri.parse('wss://example.com'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      socket.reply([_r('a', 'ねえ、ライム、明日の天気は？')]);
      final outcome = await session.outcome;
      expect(outcome.text, '明日の天気は？');
    });

    test('何も話されなければ noSpeech で閉じる', () async {
      final session = service().listen();
      presign.complete(Uri.parse('wss://example.com'));

      final outcome = await session.outcome;
      expect(outcome.reason, SttEndReason.noSpeech);
      expect(outcome.text, isEmpty);
      // 課金を止めるためにすぐ閉じる。確定を待つ必要は無い
      expect(socket.sentEndOfStream, isFalse);
      expect(socket.closed, isTrue);
    });

    test('Transcribe がエラーを返したら failed', () async {
      final session = service().listen();
      presign.complete(Uri.parse('wss://example.com'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      socket.replyException('LimitExceededException');
      final outcome = await session.outcome;
      expect(outcome.reason, SttEndReason.failed);
      expect(outcome.error, isNotNull);
    });

    test('接続できなければ failed で、マイクも離す', () async {
      final session = service(failToConnect: true).listen();
      presign.complete(Uri.parse('wss://example.com'));

      final outcome = await session.outcome;
      expect(outcome.reason, SttEndReason.failed);
      expect(outcome.error, isNot(contains('secret-url')));
      expect(mic.hasListener, isFalse);
    });

    test('認証情報を用意できなければ failed', () async {
      final session = service().listen();
      presign.completeError(StateError('ログインが必要です'));

      final outcome = await session.outcome;
      expect(outcome.reason, SttEndReason.failed);
      expect(mic.hasListener, isFalse);
    });

    test('取り消したら文字は捨てる', () async {
      final session = service().listen();
      presign.complete(Uri.parse('wss://example.com'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      socket.reply([_r('a', 'やっぱりいい', partial: true)]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      session.cancel();

      final outcome = await session.outcome;
      expect(outcome.reason, SttEndReason.cancelled);
      expect(outcome.text, isEmpty);
      expect(socket.sentEndOfStream, isFalse);
    });

    test('finish で今までの分を確定させる', () async {
      final session = service().listen();
      presign.complete(Uri.parse('wss://example.com'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      socket.reply([_r('a', '電気消して', partial: true)]);
      socket.finalOnEnd = [_r('a', '電気消して。')];
      await Future<void>.delayed(const Duration(milliseconds: 10));
      session.finish();

      final outcome = await session.outcome;
      expect(outcome.reason, SttEndReason.completed);
      expect(outcome.text, '電気消して。');
    });
  });
}
