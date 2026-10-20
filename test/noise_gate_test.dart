import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/voice/noise_gate.dart';

/// [ms] ミリ秒の 440Hz の音（振幅 [amplitude]）。16kHz / 16bit。
Uint8List tone(int ms, int amplitude) {
  final n = 16 * ms;
  final out = Uint8List(n * 2);
  final data = ByteData.sublistView(out);
  for (var i = 0; i < n; i++) {
    final v = (amplitude * math.sin(2 * math.pi * 440 * i / 16000)).round();
    data.setInt16(i * 2, v, Endian.little);
  }
  return out;
}

Uint8List join(List<Uint8List> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}

/// [pcm] の [fromMs]〜[toMs] に音が残っているか。
bool hasSound(Uint8List pcm, int fromMs, int toMs) {
  final data = ByteData.sublistView(pcm);
  for (var i = fromMs * 16; i < toMs * 16 && i * 2 + 1 < pcm.length; i++) {
    if (data.getInt16(i * 2, Endian.little) != 0) return true;
  }
  return false;
}

void main() {
  // 振幅 3277 の正弦波 ≒ -23dBFS（二乗平均）。振幅 328 ≒ -43dBFS
  const loud = 3277;
  const quiet = 328;

  group('speechLevelDb', () {
    test('正弦波の大きさを測れる', () {
      final db = NoiseGate.speechLevelDb(tone(500, loud))!;
      expect(db, closeTo(-23, 0.5));
    });

    test('無音しか無ければ null', () {
      expect(NoiseGate.speechLevelDb(Uint8List(16000)), isNull);
    });

    test('間に無音があっても、声の部分の大きさを返す', () {
      final pcm = join([Uint8List(16000), tone(400, loud), Uint8List(16000)]);
      expect(NoiseGate.speechLevelDb(pcm), closeTo(-23, 0.5));
    });
  });

  group('process', () {
    NoiseGate gate() => NoiseGate(referenceDb: -23, marginDb: 9);

    test('先読みの分だけ遅れて出る', () {
      final out = gate().process(tone(1000, loud));
      expect(out.length, 16 * 900 * 2);
    });

    test('呼んだ声と同じくらいの音は通す', () {
      final out = gate().process(tone(1000, loud));
      expect(hasSound(out, 0, 900), isTrue);
    });

    test('小さい音は、始めに開けておく間を過ぎたら消す', () {
      final out = gate().process(tone(2000, quiet));
      // 始めの 350ms（保持 250ms + 先読み 100ms）は開けてある
      expect(hasSound(out, 0, 300), isTrue);
      expect(hasSound(out, 500, 1900), isFalse);
    });

    test('大きい音の少し前から通す（語頭を切らない）', () {
      final out = gate().process(join([tone(1000, quiet), tone(500, loud)]));
      // 大きい音は 1000ms から。出力は 100ms 遅れるので、入力の 900〜1000ms が
      // 出力の 900〜1000ms 付近にあたる
      expect(hasSound(out, 600, 800), isFalse);
      expect(hasSound(out, 920, 1000), isTrue);
    });

    test('大きい音が終わっても少しの間は通す（語尾を切らない）', () {
      final out = gate().process(join([tone(500, loud), tone(1500, quiet)]));
      expect(hasSound(out, 500, 650), isTrue);
      expect(hasSound(out, 1000, 1800), isFalse);
    });

    test('細かく分けて渡しても、まとめて渡しても同じ結果になる', () {
      final input = join([tone(700, quiet), tone(300, loud), tone(800, quiet)]);
      final whole = gate().process(input);

      final g = gate();
      final pieces = BytesBuilder();
      for (var i = 0; i < input.length; i += 250) {
        final end = math.min(i + 250, input.length);
        pieces.add(g.process(Uint8List.sublistView(input, i, end)));
      }
      expect(pieces.takeBytes(), whole);
    });

    test('消した割合を数える', () {
      final g = gate();
      g.process(tone(2000, quiet));
      expect(g.mutedRatio, greaterThan(0.7));
    });
  });
}
