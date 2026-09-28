import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/aws/event_stream.dart';
import 'package:raim_prototype/services/aws/transcribe_events.dart';

/// 期待値のバイト列は Python で組み立て、AWS 公式の Python ライブラリ
/// （botocore の EventStreamBuffer）で読めることを確かめたもの。
Uint8List _hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

const _audio1234 =
    '0000006c000000585c509ce30d3a636f6e74656e742d747970650700186170706c69'
    '636174696f6e2f6f637465742d73747265616d0b3a6576656e742d7479706507000a'
    '417564696f4576656e740d3a6d6573736167652d747970650700056576656e740102'
    '0304744c824a';

const _endOfStream =
    '0000006800000058a9d03a230d3a636f6e74656e742d747970650700186170706c69'
    '636174696f6e2f6f637465742d73747265616d0b3a6576656e742d7479706507000a'
    '417564696f4576656e740d3a6d6573736167652d747970650700056576656e745cc6'
    '4095';

// 本文: {"Transcript": {"Results": [{"Alternatives": [{"Transcript":
//   "ねえ、今日の天気は？", "Items": []}], "EndTime": 1.5,
//   "IsPartial": false, "ResultId": "r-1", "StartTime": 0.25}]}}
const _transcript =
    '0000011f0000005557cfa9e40b3a6576656e742d7479706507000f5472616e736372'
    '6970744576656e740d3a636f6e74656e742d747970650700106170706c6963617469'
    '6f6e2f6a736f6e0d3a6d6573736167652d747970650700056576656e747b22547261'
    '6e736372697074223a207b22526573756c7473223a205b7b22416c7465726e617469'
    '766573223a205b7b225472616e736372697074223a2022e381ade38188e38081e4bb'
    '8ae697a5e381aee5a4a9e6b097e381afefbc9f222c20224974656d73223a205b5d7d'
    '5d2c2022456e6454696d65223a20312e352c202249735061727469616c223a206661'
    '6c73652c2022526573756c744964223a2022722d31222c2022537461727454696d65'
    '223a20302e32357d5d7d7d582cf77c';

const _exception =
    '000000c80000006186f22dbd0f3a657863657074696f6e2d74797065070013426164'
    '52657175657374457863657074696f6e0d3a636f6e74656e742d7479706507001061'
    '70706c69636174696f6e2f6a736f6e0d3a6d6573736167652d747970650700096578'
    '63657074696f6e7b224d657373616765223a2022596f757220726571756573742074'
    '696d6564206f75742062656361757365206e6f206e657720617564696f2077617320'
    '726563656976656420666f72203135207365636f6e64732e227d1c01cfa9';

// ヘッダの型をすべて含むもの
const _mixed =
    '0000006a00000058d3106943017400016601016202fe02736803fed4016904000111'
    '70016c05000001000000000002627906000300ff1003737472070006e697a5e69cac'
    '02747308000001a0e86fd6ae026964090102030405060708090a0b0c0d0e0f106f6b'
    '71f0720e';

void main() {
  group('Crc32', () {
    test('標準の検査値', () {
      expect(Crc32.of(ascii.encode('123456789')), 0xCBF43926);
    });

    test('空', () {
      expect(Crc32.of(const []), 0);
    });
  });

  group('送る音声', () {
    test('botocore と同じバイト列になる', () {
      expect(TranscribeAudio.event(const [1, 2, 3, 4]), _hex(_audio1234));
    });

    test('話し終わりの合図は本文が空', () {
      expect(TranscribeAudio.endOfStream(), _hex(_endOfStream));
    });
  });

  group('EventStreamDecoder.decode', () {
    test('送る音声を読み戻せる', () {
      final m = EventStreamDecoder.decode(_hex(_audio1234));
      expect(m.headers, {
        ':content-type': 'application/octet-stream',
        ':event-type': 'AudioEvent',
        ':message-type': 'event',
      });
      expect(m.payload, [1, 2, 3, 4]);
    });

    test('すべての型のヘッダを読める', () {
      final m = EventStreamDecoder.decode(_hex(_mixed));
      expect(m.headers['t'], true);
      expect(m.headers['f'], false);
      expect(m.headers['b'], -2);
      expect(m.headers['sh'], -300);
      expect(m.headers['i'], 70000);
      expect(m.headers['l'], 1099511627776);
      expect(m.headers['by'], [0x00, 0xff, 0x10]);
      expect(m.headers['str'], '日本');
      expect(
        m.headers['ts'],
        DateTime.fromMillisecondsSinceEpoch(1790606038702, isUtc: true),
      );
      expect(m.headers['id'], '0102030405060708090a0b0c0d0e0f10');
      expect(utf8.decode(m.payload), 'ok');
    });

    test('本文が1バイト壊れていたら CRC で弾く', () {
      final bytes = _hex(_audio1234);
      bytes[bytes.length - 6] ^= 0x01;
      expect(() => EventStreamDecoder.decode(bytes), throwsFormatException);
    });

    test('prelude が壊れていたら弾く', () {
      final bytes = _hex(_audio1234);
      bytes[5] ^= 0x01;
      expect(() => EventStreamDecoder.decode(bytes), throwsFormatException);
    });

    test('短すぎるものは弾く', () {
      expect(
        () => EventStreamDecoder.decode(Uint8List(8)),
        throwsFormatException,
      );
    });
  });

  group('EventStreamDecoder.add', () {
    test('1バイトずつ届いても読める', () {
      final decoder = EventStreamDecoder();
      final bytes = _hex(_transcript);
      final got = <EventStreamMessage>[];
      for (final b in bytes) {
        got.addAll(decoder.add([b]));
      }
      expect(got, hasLength(1));
      expect(decoder.pendingLength, 0);
    });

    test('2件が連結して届いても読める', () {
      final decoder = EventStreamDecoder();
      final joined = [..._hex(_transcript), ..._hex(_exception)];
      final got = decoder.add(joined);
      expect(got.map((m) => m.messageType), ['event', 'exception']);
      expect(decoder.pendingLength, 0);
    });

    test('途中までなら残しておく', () {
      final decoder = EventStreamDecoder();
      final bytes = _hex(_transcript);
      expect(decoder.add(bytes.sublist(0, 100)), isEmpty);
      expect(decoder.pendingLength, 100);
      expect(decoder.add(bytes.sublist(100)), hasLength(1));
    });

    test('ありえない長さは弾く', () {
      final decoder = EventStreamDecoder();
      final bad = _hex(_audio1234)..setRange(0, 4, [0x7f, 0xff, 0xff, 0xff]);
      expect(() => decoder.add(bad), throwsFormatException);
    });
  });

  group('TranscribeEvent.parse', () {
    test('文字起こしの結果を読める', () {
      final event = TranscribeEvent.parse(
        EventStreamDecoder.decode(_hex(_transcript)),
      );
      expect(event, isA<TranscriptEvent>());
      final results = (event! as TranscriptEvent).results;
      expect(results, hasLength(1));
      expect(results.first.text, 'ねえ、今日の天気は？');
      expect(results.first.isPartial, isFalse);
      expect(results.first.resultId, 'r-1');
      expect(results.first.startTime, 0.25);
      expect(results.first.endTime, 1.5);
    });

    test('例外を読める', () {
      final event = TranscribeEvent.parse(
        EventStreamDecoder.decode(_hex(_exception)),
      );
      expect(event, isA<TranscribeFailure>());
      final failure = event! as TranscribeFailure;
      expect(failure.type, 'BadRequestException');
      expect(failure.message, contains('15 seconds'));
      expect(failure.isTransient, isFalse);
    });

    test('結果が空でも落ちない', () {
      final m = EventStreamMessage(
        headers: {':message-type': 'event', ':event-type': 'TranscriptEvent'},
        payload: Uint8List.fromList(utf8.encode('{"Transcript":{"Results":[]}}')),
      );
      final event = TranscribeEvent.parse(m)! as TranscriptEvent;
      expect(event.results, isEmpty);
    });

    test('知らないイベントは無視する', () {
      final m = EventStreamMessage(
        headers: {':message-type': 'event', ':event-type': 'SomethingNew'},
        payload: Uint8List(0),
      );
      expect(TranscribeEvent.parse(m), isNull);
    });

    test('error 形式も読める', () {
      final m = EventStreamMessage(
        headers: {
          ':message-type': 'error',
          ':error-code': 'InternalFailureException',
          ':error-message': 'oops',
        },
        payload: Uint8List(0),
      );
      final failure = TranscribeEvent.parse(m)! as TranscribeFailure;
      expect(failure.type, 'InternalFailureException');
      expect(failure.isTransient, isTrue);
    });
  });
}
