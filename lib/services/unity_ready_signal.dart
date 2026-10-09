import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// スマホで Unity（ライムの表示）の準備ができたかどうか。
///
/// Unity は最初の画面を描き終えると `{"type":"unity.ready"}` を送ってくる。
/// Unity はアプリが動いている間ずっと起動したままなので、一度立てたら戻さない。
/// （ログアウトしてまたチャット画面に来たときは、もう準備ができている）
class UnityReadySignal {
  UnityReadySignal._();

  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);

  /// Unity を画面に出してから、合図が届かないままこれだけたったら準備できたものとみなす。
  ///
  /// Unity へのメッセージは準備ができるまで送らずにためておく（EmbedUnityBridge）。
  /// 合図を送らない古い Unity のビルドなどで、ずっと送れないままにならないための保険。
  static const Duration fallbackDelay = Duration(seconds: 30);

  static Timer? _fallback;

  /// Unity を画面に出したときに呼ぶ。何度呼んでもよい。
  static void startWaiting() {
    if (ready.value || _fallback != null) return;
    _fallback = Timer(fallbackDelay, () {
      if (ready.value) return;
      RaimLog.w('[UnityReadySignal] Unity から準備完了が届かないので、届いたものとして進めます');
      ready.value = true;
    });
  }

  /// Unity から届いたメッセージを見て、準備完了の合図なら [ready] を立てる。
  static void handleMessage(String message) {
    if (ready.value) return;
    try {
      final data = jsonDecode(message);
      if (data is Map && data['type'] == 'unity.ready') {
        _fallback?.cancel();
        _fallback = null;
        ready.value = true;
      }
    } on FormatException {
      // JSON でないメッセージは関係ないので無視する
    }
  }

  /// テスト用。最初の状態に戻す。
  @visibleForTesting
  static void reset() {
    _fallback?.cancel();
    _fallback = null;
    ready.value = false;
  }
}
