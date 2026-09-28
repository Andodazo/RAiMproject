import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/wake_word_service.dart';

/// ウェイクワードの判定が、実機検証で見えた認識結果に対して
/// 期待どおりに動くことを確かめる。
///
/// ケースの多くは Python の検証スクリプトで実際に出た Vosk の出力。
/// ここが壊れると「呼んでも反応しない」か「関係ない語で起動する」になる。
void main() {
  const polite = ['ねえ ライム', 'ねえ らいむ'];
  const both = ['ねえ ライム', 'ねえ らいむ', 'ライム', 'らいむ'];

  String? match(String text, List<String> wake) =>
      matchWakeWord(wakeTokensOf(text), wake);

  group('wakeTokensOf', () {
    test('[unk] と余分な空白を取り除く', () {
      expect(wakeTokensOf('[unk]  ねえ ライム [unk]'), ['ねえ', 'ライム']);
    });

    test('[unk] だけなら空になる', () {
      expect(wakeTokensOf('[unk] [unk]'), isEmpty);
    });
  });

  group('「ねえライム」モード', () {
    test('そのまま言えば検知する', () {
      expect(match('ねえ ライム', polite), 'ねえ ライム');
      expect(match('ねえ らいむ', polite), 'ねえ らいむ');
    });

    test('前に環境音が付いても検知する（録音開始直後のクリック音など）', () {
      expect(match('[unk] ねえ ライム', polite), 'ねえ ライム');
    });

    test('後ろに次の呼びかけの頭が付いても検知する', () {
      expect(match('ねえ らいむ ねえ', polite), 'ねえ らいむ');
    });

    test('「ライム」だけでは起動しない', () {
      expect(match('ライム', polite), isNull);
      expect(match('[unk] ライム', polite), isNull);
    });
  });

  group('紛らわしい語（デコイ）', () {
    test('デコイとして認識された語では起動しない', () {
      for (final decoy in kWakeDecoys) {
        expect(match(decoy, both), isNull, reason: decoy);
      }
    });

    test('「ライムライト」は単語単位で比べるので「ライム」に一致しない', () {
      expect(match('ライムライト', both), isNull);
      expect(match('ねえ ライムライト', both), isNull);
    });
  });

  group('「ねえ」と「ライム」が別々の結果に分かれた場合', () {
    // 「ねえ、ライム」と間を空けると、Vosk が区切りと判断して
    // 2回に分けて結果を返すことがある。WakeWordService は直前の
    // 結果の末尾をつないで判定する。
    test('つなげば検知する', () {
      final joined = [...wakeTokensOf('ねえ'), ...wakeTokensOf('ライム')];
      expect(matchWakeWord(joined, polite), 'ねえ ライム');
    });

    test('つながなければ検知しない', () {
      expect(match('ねえ', polite), isNull);
      expect(match('ライム', polite), isNull);
    });
  });

  group('両方モード', () {
    test('「ライム」だけでも起動する', () {
      expect(match('ライム', both), 'ライム');
      expect(match('[unk] らいむ', both), 'らいむ');
    });
  });

  test('空の結果では何もしない', () {
    expect(match('', both), isNull);
    expect(match('[unk]', both), isNull);
  });
}
