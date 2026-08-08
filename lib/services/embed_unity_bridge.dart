import 'dart:convert';
import 'package:flutter_embed_unity/flutter_embed_unity.dart';
import 'package:raim_prototype/services/unity_communicator.dart';

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
  @override
  Future<void> start() async {
    // flutter_embed_unity は Unity ウィジェット描画時に初期化されるため、ここでは何もしません。
    print('EmbedUnityBridge: 初期化完了（Unity ウィジェット描画時に起動）');
  }

  @override
  void sendEmotion({
    required String text,
    required String emotion,
    required double intensity,
  }) {
    // emotion 文字列だけを Unity に送る（シンプルに）。
    sendToUnity(gameObjectName, emotionMethodName, emotion);

    print('Unity 送信: $gameObjectName.$emotionMethodName($emotion)');
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

  sendToUnity(
    gameObjectName,
    toolStateMethodName,
    json,
  );

  print(
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
    sendToUnity(
      gameObjectName,
      emotionsMethodName,
      json,
    );
  }
}
