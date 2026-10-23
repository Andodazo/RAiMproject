// lib/services/station/station_denoiser.dart
//
// 駅アラームで、走行音などの雑音を消してから車内アナウンスを聞く。
//
// GTCRN という小さな雑音除去モデル（約520KB）を sherpa-onnx で動かす。
// 16kHz のまま、マイクの音を少しずつ渡して少しずつ受け取れる。
//
// 【効き目（Python の検証で、同じモデル・同じ駅名の文法）】
//   走行音（低い音の強い雑音）をアナウンスより 5dB 大きく混ぜた音:
//     駅名の入った認識結果  なし 10件 → あり 21件
//   残響・帯域制限・話し声を重ねた音:
//     なし「次は」だけ → あり「次は」と「到着」の両方を知らせた
//   雑音の無い音では、あってもなくても同じだった。
// 消すのは声以外の雑音だけ。周りの人の話し声は消えない。
//
// 【使えないとき】
// ライブラリやモデルが読めなければ、雑音を消さずにそのまま聞く（駅アラームは止めない）。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:raim_prototype/services/mic_stream_service.dart';
import 'package:raim_prototype/services/raim_log.dart';

class StationDenoiser {
  StationDenoiser._(this._denoiser);

  static const String modelAsset = 'assets/models/gtcrn_simple.onnx';

  /// false にすると雑音を消さない（比べたいとき用）。
  static bool enabled = true;

  static bool _bindingsReady = false;

  sherpa.OnlineSpeechDenoiser? _denoiser;

  /// 作れなければ null（雑音を消さずに聞く）。
  static Future<StationDenoiser?> create() async {
    if (!enabled) return null;
    try {
      final model = await _modelPath();
      if (!_bindingsReady) {
        sherpa.initBindings();
        _bindingsReady = true;
      }
      final denoiser = sherpa.OnlineSpeechDenoiser(
        sherpa.OnlineSpeechDenoiserConfig(
          model: sherpa.OfflineSpeechDenoiserModelConfig(
            gtcrn: sherpa.OfflineSpeechDenoiserGtcrnModelConfig(model: model),
            numThreads: 1,
            debug: false,
          ),
        ),
      );
      RaimLog.i('[Station] 雑音を消してから聞きます');
      return StationDenoiser._(denoiser);
    } catch (e) {
      RaimLog.w('[Station] 雑音を消せないので、そのまま聞きます: ${e.runtimeType}');
      return null;
    }
  }

  /// 16bit PCM を渡すと、雑音を消した 16bit PCM が返る。
  ///
  /// 中で少し溜めるので、渡した長さと返る長さは毎回同じとは限らない
  /// （合計はほぼ同じ）。失敗したら、それ以降は渡した音をそのまま返す。
  Uint8List process(Uint8List pcm) {
    final denoiser = _denoiser;
    if (denoiser == null || pcm.length < 2) return pcm;

    try {
      final input = ByteData.sublistView(pcm);
      final n = pcm.length ~/ 2;
      final samples = Float32List(n);
      for (var i = 0; i < n; i++) {
        samples[i] = input.getInt16(i * 2, Endian.little) / 32768;
      }

      final out = denoiser.run(
        samples: samples,
        sampleRate: MicStreamService.sampleRate,
      );

      final result = Uint8List(out.samples.length * 2);
      final view = ByteData.sublistView(result);
      for (var i = 0; i < out.samples.length; i++) {
        final v = (out.samples[i] * 32768).round().clamp(-32768, 32767);
        view.setInt16(i * 2, v, Endian.little);
      }
      return result;
    } catch (e) {
      RaimLog.w('[Station] 雑音を消すのに失敗したので、ここからはそのまま聞きます: '
          '${e.runtimeType}');
      dispose();
      return pcm;
    }
  }

  void dispose() {
    final denoiser = _denoiser;
    _denoiser = null;
    try {
      denoiser?.free();
    } catch (_) {
      // 既に解放されている
    }
  }

  /// sherpa-onnx はファイルのパスでモデルを読むので、アセットを
  /// アプリ専用領域へ写しておく（大きさが同じなら写し直さない）。
  static Future<String> _modelPath() async {
    final data = await rootBundle.load(modelAsset);
    final support = await getApplicationSupportDirectory();
    final sep = Platform.pathSeparator;
    final dir = Directory('${support.path}${sep}denoise');
    await dir.create(recursive: true);
    final file = File('${dir.path}${sep}gtcrn_simple.onnx');
    if (!await file.exists() || await file.length() != data.lengthInBytes) {
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return file.path;
  }
}
