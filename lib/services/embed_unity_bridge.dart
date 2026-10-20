import 'dart:convert';
import 'package:flutter_embed_unity/flutter_embed_unity.dart';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/unity_ready_signal.dart';

/// iOS/Android 版での Unity 通信実装です。
///
/// `flutter_embed_unity` の `sendToUnity` 関数を使って、
/// Unity 内の GameObject のメソッドを直接呼びます。
class EmbedUnityBridge implements UnityCommunicator {
  /// Unity 側の GameObject 名
  /// （RAiMCharacterController.cs がアタッチされてる Character オブジェクト）
  static const String gameObjectName = "character";
  
  /// Unity 側で呼ばれるメソッド名
  /// （RAiMCharacterController.ReceiveEmotion）
  static const String emotionMethodName = "ReceiveEmotion";

  /// 旧形式: 単一感情を送る Unity 側メソッド名
  ///
  /// emotion / intensity だけを見る既存Unity処理との互換性を保つために残す。
  /// Unity 側の RAiMCharacterController.ReceiveEmotion に対応する。
  static const String emotionsMethodName = "ReceiveEmotions";
  static const String toolStateMethodName = "ReceiveToolState";
  static const String layoutMethodName = "ReceiveLayout";
  static const String sleepMethodName = "ReceiveSleep";

  EmbedUnityBridge() {
    UnityReadySignal.ready.addListener(_flushPending);
  }

  /// 最後に伝えた「寝ているか」。同じ値を何度も送らないために覚えておく
  bool _sleeping = false;

  /// Unity の準備ができる前に送ろうとしたもの。送り先のメソッドごとに最新の1件だけ持つ。
  final Map<String, String> _pending = {};

  /// Unity へ送る。準備ができる前ならためておき、できたところでまとめて送る。
  ///
  /// 以前は準備前でもそのまま送っていて、Unity が読み込まれる前の分は
  /// 「Native libraries not loaded」と捨てられていた。
  /// （起動前に寝ていた・感情が届いていた、などが反映されなかった）
  void _send(String method, String message) {
    if (!UnityReadySignal.ready.value) {
      // 古いものを消してから入れ直し、送る順番を「最後に来た順」にそろえる
      _pending.remove(method);
      _pending[method] = message;
      return;
    }
    // ためていた古いものが後から送られて、これを上書きしないようにする
    _pending.remove(method);
    sendToUnity(gameObjectName, method, message);
  }

  void _flushPending() {
    if (!UnityReadySignal.ready.value || _pending.isEmpty) return;
    final pending = Map<String, String>.of(_pending);
    _pending.clear();
    RaimLog.d('[EmbedUnityBridge] 準備前にためていた ${pending.length} 件を送ります');
    pending.forEach((method, message) {
      sendToUnity(gameObjectName, method, message);
    });
  }

  @override
  Future<void> start() async {
    // flutter_embed_unity は Unity ウィジェット描画時に初期化されるため、ここでは何もしません。
    RaimLog.d('EmbedUnityBridge: 初期化完了（Unity ウィジェット描画時に起動）');
  }

  @override
  void sendEmotion({
    required String text,
    required String emotion,
    required double intensity,
  }) {
    // emotion 文字列だけを Unity に送る（シンプルに）。
    _send(emotionMethodName, emotion);

    RaimLog.d('[EmbedUnityBridge] 送信 $emotionMethodName');
  }

  @override
void sendToolState({
  required bool isUsingTool,
  String? description,
}) {
  final json = jsonEncode({
    'type': 'tool_state',
    'is_using_tool': isUsingTool,
    'description': description,
  });

  _send(toolStateMethodName, json);

  RaimLog.d(
    'Unity送信: $gameObjectName.$toolStateMethodName($json)',
  );
}

  // ============================================================
  // 吹き出し（Windows版のみ）
  // ============================================================
  // モバイルは Flutter のチャット画面が文字を描くため、
  // Unity へテキストは送らない。インターフェースを満たすための空実装。

  @override
  void sendText({
    required String text,
    bool isFiller = false,
  }) {
    // 何もしない
  }

  @override
  void sendLayout({required double headTop}) {
    final json = jsonEncode({'head_top': headTop});
    _send(layoutMethodName, json);
    RaimLog.d('[EmbedUnityBridge] 送信 $layoutMethodName($json)');
  }

  @override
  void sendSleeping(bool sleeping) {
    if (_sleeping == sleeping) return;
    _sleeping = sleeping;
    final value = sleeping ? 'true' : 'false';
    _send(sleepMethodName, value);
    RaimLog.d('[EmbedUnityBridge] 送信 $sleepMethodName($value)');
  }

  /// スマホは Flutter のチャット欄に考え中の吹き出しを出すので、Unity には送らない
  @override
  void sendThinking() {}

  @override
  void sendBubbleBreak() {
    // 何もしない
  }

  @override
  void sendChatEnd({String? fullText}) {
    // 何もしない
  }

  @override
  void sendError({required String message}) {
    // 何もしない
  }

  @override
  void sendAppQuit() {
    // モバイルでは Unity がアプリ内にいるので個別終了はしない
  }

  // ============================================================
  // Unity → Flutter
  // ============================================================
  // モバイルでは Unity が Flutter の中に埋め込まれており、
  // クリックもウィンドウ移動も存在しない。常に空の Stream を返す。

  @override
  Stream<Map<String, dynamic>> get unityEvents => const Stream.empty();

  @override
  bool get isUnityConnected => true;

  @override
  Future<void> ensureUnityRunning() async {
    // モバイルでは Unity がアプリ内にいるので起動制御は不要
  }

  @override
  void setExhibitionMode(bool enabled) {
    // モバイル版には Windows の外部ウィンドウ表示がない。
  }

  @override
  void setMascotScale(double scale) {
    // スマホのライムは画面に合わせて出すので、大きさの設定は無い
  }

  @override
  Future<void> stop() async {
    // flutter_embed_unity は自動管理なので明示的な停止は不要です。
  }

  // ============================================================
  // v2.2: 複数感情送信
  // ============================================================
  // 新仕様では happy / curious など複数の感情比率が届く。
  // Flutter側で JSON に変換し、Unity側の ReceiveEmotions に送る。
  @override
  void sendEmotions({
    required Map<String, double> emotions,
    required double overallIntensity,
  }) {
     // Unity に渡しやすいように、複数感情情報を JSON 文字列へ変換する
    final json = jsonEncode({
      'emotions': emotions,
      'overall_intensity': overallIntensity,
    });
    // Unity 側の ReceiveEmotions を呼び出し、複数感情を反映する
    _send(emotionsMethodName, json);
  }
}
