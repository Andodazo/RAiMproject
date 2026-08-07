/// Unity との通信を抽象化するインターフェース
/// 
/// プラットフォームごとに実装が異なる：
/// - Windows: WebSocket経由（WindowsUnityBridge）
/// - iOS/Android: flutter_embed_unity 経由（EmbedUnityBridge）
abstract class UnityCommunicator {
  /// 通信を開始する（必要に応じて）
  Future<void> start();

  /// 感情パラメータを Unity に送信
  void sendEmotion({
    required String text,
    required String emotion,
    required double intensity,
  });

  void sendToolState({
    required bool isUsingTool,
    String? description,
  });

  /// v2.2: 複数感情を Unity に送信
  ///
  /// emotions:
  ///   例: {'happy': 0.6, 'curious': 0.4}
  /// overallIntensity:
  ///   感情全体の強さ。Unity側で表情や動きの強さ調整に使う。
  void sendEmotions({
    required Map<String, double> emotions,
    required double overallIntensity,
  });

  // ============================================================
  // 吹き出し（Windows版のデスクトップマスコット用）
  // ============================================================
  // Windows では文字を Unity 側の吹き出しに出すため、text_chunk を
  // そのまま Unity へ転送する。
  // モバイルは Flutter のチャット画面が文字を描くので、
  // EmbedUnityBridge 側では何もしない実装にしてある。

  /// text_chunk を Unity へ転送する
  void sendText({
    required String text,
    bool isFiller = false,
  });

  /// bubble_break を Unity へ転送する
  void sendBubbleBreak();

  /// chat_end を Unity へ転送する
  void sendChatEnd({String? fullText});

  /// error を Unity へ転送する
  void sendError({required String message});

  // ============================================================
  // Unity → Flutter
  // ============================================================
  // Windows ではライムのクリックやウィンドウ移動を Unity 側が検知して
  // 通知してくる。入力小窓を出す・追従させるのに使う。
  //
  // 届く JSON の例:
  //   {"type":"unity.clicked"}
  //   {"type":"unity.moved","x":900,"y":100,"width":800,"height":700}
  //
  // モバイルでは何も流れない（空の Stream）。

  Stream<Map<String, dynamic>> get unityEvents;

  /// 通信を停止
  Future<void> stop();
}
