import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/providers/voice_controller.dart';
import 'package:raim_prototype/services/transcribe_stt_service.dart';
import 'package:raim_prototype/services/wake_word_service.dart';

void main() {
  group('hasSpeechAfterWakeWord', () {
    test('ウェイクワードだけなら続きなし', () {
      expect(hasSpeechAfterWakeWord('ねえ ライム', 'ねえ ライム'), isFalse);
      expect(hasSpeechAfterWakeWord('[unk] ねえ ライム', 'ねえ ライム'), isFalse);
    });

    test('後ろに [unk] が続けば続きあり', () {
      // 文法に無い普通の言葉は [unk] になる
      expect(
        hasSpeechAfterWakeWord('ねえ ライム [unk] [unk]', 'ねえ ライム'),
        isTrue,
      );
    });

    test('表記違いのウェイクワードでも判定できる', () {
      expect(hasSpeechAfterWakeWord('ねえ らいむ [unk]', 'ねえ らいむ'), isTrue);
    });

    test('ウェイクワードが無ければ false', () {
      expect(hasSpeechAfterWakeWord('スライム [unk]', 'ねえ ライム'), isFalse);
    });
  });

  group('stripWakePhrase', () {
    test('いろいろな表記の呼びかけを落とす', () {
      expect(stripWakePhrase('ねえ、ライム、今日の天気は？'), '今日の天気は？');
      expect(stripWakePhrase('ねえライム今日の天気は？'), '今日の天気は？');
      expect(stripWakePhrase('ねぇ ライム。電気消して'), '電気消して');
      expect(stripWakePhrase('ねーらいむ、おはよう'), 'おはよう');
      expect(stripWakePhrase('ねえ RAiM 元気？'), '元気？');
      expect(stripWakePhrase('ライム、おはよう'), 'おはよう');
    });

    test('呼びかけだけなら空になる', () {
      expect(stripWakePhrase('ねえ、ライム。'), '');
    });

    test('途中の「ライム」は消さない', () {
      expect(stripWakePhrase('今日はライムを買った'), '今日はライムを買った');
    });
  });

  group('placeUtterance', () {
    test('入力欄が空で返事待ちでなければそのまま送る', () {
      final r = placeUtterance(typed: '', heard: '今日の天気は？', busy: false);
      expect(r.send, isTrue);
      expect(r.text, '今日の天気は？');
    });

    test('書きかけがあれば送らずに後ろへ足す', () {
      final r = placeUtterance(typed: 'えっと', heard: '明日は？', busy: false);
      expect(r.send, isFalse);
      expect(r.text, 'えっと 明日は？');
    });

    test('返事の生成中は送らずに入力欄へ入れる', () {
      final r = placeUtterance(typed: '  ', heard: '待って', busy: true);
      expect(r.send, isFalse);
      expect(r.text, '待って');
    });
  });
}
