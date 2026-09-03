import 'dart:async';

import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/unity_communicator.dart';

/// Unity を動かせないプラットフォーム向けの、何もしないブリッジ。
///
/// RAiM が対応しているのは Windows / Android / iOS の3つ。
/// Web・macOS・Linux ではビルドは通るがマスコットは動かない。
///
/// 以前は Web も macOS / Linux も Windows 用の実装へ落ちていた。
/// Windows 用は dart:io の HttpServer を立てて raim.exe を起動するので、
/// Web では起動時に例外になり、macOS / Linux では存在しない exe を
/// 探しに行っていた。
///
/// チャット機能自体は動くので、マスコットだけ黙って無効化する。
class NoopUnityBridge implements UnityCommunicator {
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get unityEvents => _events.stream;

  @override
  bool get isUnityConnected => false;

  @override
  Future<void> start() async {
    RaimLog.i('[NoopUnityBridge] このプラットフォームではマスコットを表示しません');
  }

  @override
  Future<void> stop() async {
    await _events.close();
  }

  @override
  Future<void> ensureUnityRunning() async {}

  @override
  void sendEmotion({
    required String text,
    required String emotion,
    required double intensity,
  }) {}

  @override
  void sendEmotions({
    required Map<String, double> emotions,
    required double overallIntensity,
  }) {}

  @override
  void sendToolState({
    required bool isUsingTool,
    String? description,
  }) {}

  @override
  void sendText({
    required String text,
    bool isFiller = false,
  }) {}

  @override
  void sendBubbleBreak() {}

  @override
  void sendChatEnd({String? fullText}) {}

  @override
  void sendError({required String message}) {}

  @override
  void sendAppQuit() {}
}
