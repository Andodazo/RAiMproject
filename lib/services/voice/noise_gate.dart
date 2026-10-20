// lib/services/voice/noise_gate.dart
//
// 呼んだ人の声より十分小さい音を無音にする（ノイズゲート）。
//
// 【何のため】
// 「ねえライム」のあとの聞き取り（Transcribe）で、周りの人の話し声まで
// 文字になってしまう。呼んだ人は端末の近くで話すので声が大きく、
// 離れた人の声は小さい。その差を使って、小さい音を消してから送る。
//
// 【基準は「呼んだ人の声」】
// 周りの雑音の大きさを基準にする方法も試したが、離れた人の話し声は
// 雑音よりずっと大きいのでほとんど消せなかった（合成音声で確認）。
// そこで「ねえライム」と言った声の大きさを基準にし、それより
// [marginDb] 以上小さい音を消す。
//
// 合成音声で確かめた目安（保持 250ms）:
//   幅  9dB: 本人の声 97% 残る / 12dB 小さい声 69% 残る / 18dB 小さい声 6% 残る
//   幅  6dB: 本人の声 95% 残る / 12dB 小さい声 36% 残る / 18dB 小さい声 1% 残る
// 離れた人の声が本人より 12dB 小さい ≒ 本人の4倍くらい離れている。
// すぐ隣で話している人の声は、ほぼ同じ大きさなので消せない。
//
// 【声を切らないために】
// - 保持: 大きい音が途切れても [hold] の間は開けておく（語尾や息継ぎ）
// - 先読み: 音を [lookahead] だけ遅らせて出し、開いたときはその少し前から通す（語頭）
// - 開け閉めは 20ms かけて音量を変える（ぷつっという音を作らない）

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

class NoiseGate {
  NoiseGate({
    required this.referenceDb,
    required this.marginDb,
    this.hold = const Duration(milliseconds: 250),
    this.lookahead = const Duration(milliseconds: 100),
  })  : _holdFrames = hold.inMilliseconds ~/ frameMs,
        _lookFrames = lookahead.inMilliseconds ~/ frameMs {
    // 始めは開けておく。呼ばれた直後に話し始めた頭を切らないため
    _openLeft = _holdFrames + _lookFrames;
  }

  /// 1回に判定する長さ（16kHz で 320 サンプル）。
  static const int frameMs = 20;
  static const int frameSamples = 16000 * frameMs ~/ 1000;
  static const int _frameBytes = frameSamples * 2;

  /// これより小さいフレームは無音とみなす（声の大きさを測るとき）。
  static const double silenceDb = -70;

  /// 基準にする声の大きさ（dBFS）。
  final double referenceDb;

  /// 基準からどれだけ小さい音まで通すか（dB）。
  final double marginDb;

  final Duration hold;
  final Duration lookahead;
  final int _holdFrames;
  final int _lookFrames;

  /// これより小さい音を消す（dBFS）。
  double get thresholdDb => referenceDb - marginDb;

  final Queue<Uint8List> _delay = Queue<Uint8List>();
  Uint8List _rest = Uint8List(0);
  int _openLeft = 0;
  double _gain = 1;

  int _frames = 0;
  int _muted = 0;

  /// 消したフレームの割合（0〜1）。ログ用。
  double get mutedRatio => _frames == 0 ? 0 : _muted / _frames;

  /// 音を通す。出てくる音は [lookahead] だけ遅れる。
  /// 20ms に満たない端数は次に回す。
  Uint8List process(Uint8List chunk) {
    final Uint8List input;
    if (_rest.isEmpty) {
      input = chunk;
    } else {
      input = Uint8List(_rest.length + chunk.length)
        ..setRange(0, _rest.length, _rest)
        ..setRange(_rest.length, _rest.length + chunk.length, chunk);
    }

    final whole = input.length - input.length % _frameBytes;
    _rest = Uint8List.fromList(Uint8List.sublistView(input, whole));

    final out = BytesBuilder(copy: false);
    for (var offset = 0; offset < whole; offset += _frameBytes) {
      final frame = Uint8List.fromList(
        Uint8List.sublistView(input, offset, offset + _frameBytes),
      );
      if (levelDb(frame) >= thresholdDb) {
        _openLeft = _holdFrames + _lookFrames;
      }
      _delay.add(frame);
      if (_delay.length > _lookFrames) {
        out.add(_apply(_delay.removeFirst(), _openLeft > 0 ? 1 : 0));
      }
      if (_openLeft > 0) _openLeft--;
    }
    return out.takeBytes();
  }

  /// [frame] の音量を [_gain] から [target] へ徐々に変える。
  Uint8List _apply(Uint8List frame, double target) {
    _frames++;
    if (target == 0) _muted++;

    final from = _gain;
    _gain = target;
    if (from == 1 && target == 1) return frame;

    final out = Uint8List(frame.length);
    final src = ByteData.sublistView(frame);
    final dst = ByteData.sublistView(out);
    final n = frame.length ~/ 2;
    for (var i = 0; i < n; i++) {
      if (from == 0 && target == 0) break; // 全部 0 のまま
      final g = from + (target - from) * (i + 1) / n;
      final v = (src.getInt16(i * 2, Endian.little) * g).round();
      dst.setInt16(i * 2, v.clamp(-32768, 32767), Endian.little);
    }
    return out;
  }

  /// 16bit PCM の音量（dBFS、二乗平均）。無音は -120。
  static double levelDb(Uint8List pcm) {
    final n = pcm.length ~/ 2;
    if (n == 0) return -120;
    final data = ByteData.sublistView(pcm);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final v = data.getInt16(i * 2, Endian.little);
      sum += v * v;
    }
    final rms = math.sqrt(sum / n);
    if (rms <= 0) return -120;
    return 20 * math.log(rms / 32768) / math.ln10;
  }

  /// 話し声の大きさ（dBFS）。20ms ごとの音量の上から2割の位置。
  ///
  /// 平均にすると、言葉の間の無音や小さい音に引っ張られて低く出る。
  /// 無音しか無ければ null。
  static double? speechLevelDb(Uint8List pcm) {
    final levels = <double>[];
    for (var offset = 0;
        offset + _frameBytes <= pcm.length;
        offset += _frameBytes) {
      final db = levelDb(Uint8List.sublistView(pcm, offset, offset + _frameBytes));
      if (db > silenceDb) levels.add(db);
    }
    if (levels.isEmpty) return null;
    levels.sort();
    final index = ((levels.length - 1) * 0.8).round();
    return levels[index];
  }
}
