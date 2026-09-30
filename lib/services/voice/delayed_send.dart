// lib/services/voice/delayed_send.dart
//
// 声で聞き取った文を、少し待ってから送る。
//
// 聞き間違いや周りの声がそのままライムに送られないよう、送る前に
// 数秒の猶予を置く（設定「少し待ってから送る」）。
// 待っている間に入力欄を触る・文字を直す・もう一度話し始めると止まり、
// 文は入力欄に残る。何もしなければ、そのまま送られる。
//
// 入力欄（スマホ）と入力小窓（Windows）の両方で使う。

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:raim_prototype/providers/voice_settings_provider.dart';

/// 聞き取った文を、どうするか。
enum UtteranceAction {
  /// すぐ送る
  sendNow,

  /// 少し待ってから送る
  sendLater,

  /// 入力欄に入れるだけ
  keep,
}

/// 聞き取った文をどうするかを決める。
///
/// [canSend] は placeUtterance が「そのまま送ってよい」と判断したか
/// （書きかけや返事の生成中なら false）。送れないときは設定に関係なく入れるだけ。
UtteranceAction decideUtteranceAction({
  required bool canSend,
  required VoiceSendMode mode,
}) {
  if (!canSend) return UtteranceAction.keep;
  return switch (mode) {
    VoiceSendMode.immediate => UtteranceAction.sendNow,
    VoiceSendMode.delayed => UtteranceAction.sendLater,
    VoiceSendMode.manual => UtteranceAction.keep,
  };
}

class DelayedSend extends ChangeNotifier {
  DelayedSend({this.delay = defaultDelay});

  /// 送るまで待つ時間。
  static const Duration defaultDelay = Duration(seconds: 3);

  final Duration delay;

  Timer? _timer;
  DateTime? _startedAt;

  /// 送るのを待っているか。
  bool get isPending => _timer != null;

  /// 待ち始めた時刻。表示（残り時間の輪）を作り直すための目印に使う。
  DateTime? get startedAt => _startedAt;

  /// [send] を [delay] 後に呼ぶ。待っている途中なら待ち直す。
  void start(VoidCallback send) {
    _timer?.cancel();
    _startedAt = DateTime.now();
    _timer = Timer(delay, () {
      _timer = null;
      _startedAt = null;
      notifyListeners();
      send();
    });
    notifyListeners();
  }

  /// 待つのをやめる（送らない）。文は入力欄に残る。
  void cancel() {
    if (_timer == null) return;
    _timer?.cancel();
    _timer = null;
    _startedAt = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
