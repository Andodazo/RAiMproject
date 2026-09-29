// lib/services/vosk/vosk_engine.dart
//
// Vosk の入口。プラットフォームごとの違いをここで吸収する。
//
//   Windows / Android … 本家 vosk_flutter をそのまま使う
//   iOS              … vosk_flutter が対応していないので、アプリに静的リンクした
//                      libvosk（packages/vosk_ios）を FFI で直接呼ぶ
//
// iOS でも、返すのは vosk_flutter の Model / Recognizer。
// どちらもライブラリの関数表（VoskLibrary）を渡せば FFI で動く作りなので、
// ウェイクワード・駅アラームのコードはプラットフォームを意識しなくてよい。

import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:vosk_flutter/vosk_flutter.dart';
// vosk_flutter は関数表（VoskLibrary）を公開していないが、Model / Recognizer に
// 渡すにはこれが要る。生成されたバインディングで、中身が変わることはまず無い。
// ignore: implementation_imports
import 'package:vosk_flutter/src/generated_vosk_bindings.dart';

import 'package:raim_prototype/services/raim_log.dart';

class VoskEngine {
  VoskEngine._();

  /// vosk_flutter の Model / Recognizer に渡すチャンネル。
  /// FFI で動くときは使われないが、引数として要る。
  static const MethodChannel _channel = MethodChannel('vosk_flutter');

  static VoskLibrary? _iosLibrary;
  static bool? _iosLinked;

  /// この端末で Vosk を使えるか。
  ///
  /// iOS は libvosk がアプリに入っているとき（fetch_libvosk.sh を実行して
  /// ビルドしたとき）だけ使える。
  static bool get isAvailable {
    if (kIsWeb) return false;
    if (Platform.isWindows || Platform.isAndroid) return true;
    if (Platform.isIOS) return _iosAvailable;
    return false;
  }

  static bool get _iosAvailable {
    final cached = _iosLinked;
    if (cached != null) return cached;
    var linked = false;
    try {
      linked = DynamicLibrary.process().providesSymbol('vosk_model_new');
    } catch (_) {
      linked = false;
    }
    if (!linked) {
      RaimLog.w('[Vosk] iOS に libvosk が入っていません（fetch_libvosk.sh 未実行）');
    }
    return _iosLinked = linked;
  }

  static VoskLibrary get _ios =>
      _iosLibrary ??= VoskLibrary(DynamicLibrary.process());

  /// モデルを読み込む。数百 ms〜数秒かかるので、iOS では別の isolate で読む。
  static Future<Model> createModel(String modelPath) async {
    if (!Platform.isIOS) {
      return VoskFlutterPlugin.instance().createModel(modelPath);
    }
    if (!_iosAvailable) {
      throw UnsupportedError('この端末では Vosk を使えません');
    }
    final address = await Isolate.run(() => _loadModelIos(modelPath));
    return Model(
      modelPath,
      _channel,
      Pointer<VoskModel>.fromAddress(address),
      _ios,
    );
  }

  /// 認識器を作る。[grammar] を渡すと、その語だけを候補にする（文法モード）。
  static Future<Recognizer> createRecognizer({
    required Model model,
    required int sampleRate,
    List<String>? grammar,
  }) async {
    if (!Platform.isIOS) {
      return VoskFlutterPlugin.instance().createRecognizer(
        model: model,
        sampleRate: sampleRate,
        grammar: grammar,
      );
    }
    final lib = _ios;
    final pointer = using((arena) {
      if (grammar == null) {
        return lib.vosk_recognizer_new(
          model.modelPointer!,
          sampleRate.toDouble(),
        );
      }
      return lib.vosk_recognizer_new_grm(
        model.modelPointer!,
        sampleRate.toDouble(),
        jsonEncode(grammar).toNativeUtf8(allocator: arena).cast<Char>(),
      );
    });
    if (pointer == nullptr) {
      throw StateError('Vosk の認識器を作れませんでした');
    }
    return Recognizer(
      id: -1,
      model: model,
      sampleRate: sampleRate,
      channel: _channel,
      recognizerPointer: pointer,
      voskLibrary: lib,
    );
  }
}

/// 別の isolate で動く。ポインタはそのまま渡せないので、アドレスの数値で返す。
int _loadModelIos(String modelPath) {
  final lib = VoskLibrary(DynamicLibrary.process());
  final pointer = using(
    (arena) => lib.vosk_model_new(
      modelPath.toNativeUtf8(allocator: arena).cast<Char>(),
    ),
  );
  if (pointer == nullptr) {
    throw StateError('Vosk のモデルを読み込めませんでした: $modelPath');
  }
  return pointer.address;
}
