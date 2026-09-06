// lib/services/wav_writer.dart
//
// PCM の生バイト列に wav ヘッダを付けるだけの処理。
//
// 【なぜ必要か】
// 音声処理は失敗してもエラーが出ない。「検知されない」としか分からず、
// 原因がマイクなのかサンプリングレートなのか認識エンジンなのか切り分けられない。
// 耳で聴ける形に落とせる手段を最初に用意しておかないと、後の調査が詰む。
//
// ここで書き出した wav は tools/stt の Python 検証スクリプトにそのまま渡せる。
// Flutter 側のマイク処理が正しいかを、Vosk と切り離して確認できる。

import 'dart:typed_data';

class WavWriter {
  WavWriter._();

  /// 16bit PCM のバイト列に wav ヘッダ（44 バイト）を付けて返す。
  ///
  /// [pcm] はリトルエンディアンの signed 16bit。
  /// record パッケージの `AudioEncoder.pcm16bits` はこの形式で来る。
  static Uint8List fromPcm16({
    required Uint8List pcm,
    int sampleRate = 16000,
    int channels = 1,
  }) {
    const headerSize = 44;
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;

    final out = Uint8List(headerSize + pcm.length);
    final view = ByteData.view(out.buffer);

    // RIFF チャンク
    _ascii(out, 0, 'RIFF');
    view.setUint32(4, 36 + pcm.length, Endian.little); // 以降のバイト数
    _ascii(out, 8, 'WAVE');

    // fmt チャンク
    _ascii(out, 12, 'fmt ');
    view.setUint32(16, 16, Endian.little); // fmt チャンクのサイズ
    view.setUint16(20, 1, Endian.little); // 1 = リニア PCM
    view.setUint16(22, channels, Endian.little);
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, byteRate, Endian.little);
    view.setUint16(32, blockAlign, Endian.little);
    view.setUint16(34, bitsPerSample, Endian.little);

    // data チャンク
    _ascii(out, 36, 'data');
    view.setUint32(40, pcm.length, Endian.little);

    out.setRange(headerSize, headerSize + pcm.length, pcm);
    return out;
  }

  static void _ascii(Uint8List out, int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      out[offset + i] = text.codeUnitAt(i);
    }
  }
}
