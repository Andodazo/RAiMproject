import 'dart:convert';

import 'package:flutter/foundation.dart';

/// スマホで Unity（ライムの表示）の準備ができたかどうか。
///
/// Unity は最初の画面を描き終えると `{"type":"unity.ready"}` を送ってくる。
/// Unity はアプリが動いている間ずっと起動したままなので、一度立てたら戻さない。
/// （ログアウトしてまたチャット画面に来たときは、もう準備ができている）
class UnityReadySignal {
  UnityReadySignal._();

  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);

  /// Unity から届いたメッセージを見て、準備完了の合図なら [ready] を立てる。
  static void handleMessage(String message) {
    if (ready.value) return;
    try {
      final data = jsonDecode(message);
      if (data is Map && data['type'] == 'unity.ready') {
        ready.value = true;
      }
    } on FormatException {
      // JSON でないメッセージは関係ないので無視する
    }
  }
}
