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
// 追加
  void sendToolState({
    required bool isUsingTool,
    String? description,
  });

  /// v2.2: 複数感情を Unity に送信
  /// 新しいRAiMサーバーでは、単一の emotion / intensity だけでなく、
  /// emotions と overallIntensity が返ってくる。
  /// emotions:
  ///   例: {'happy': 0.6, 'curious': 0.4}
  /// overallIntensity:
  ///   感情全体の強さ。Unity側で表情や動きの強さ調整に使う。
  /// このメソッドを interface に追加したため、
  /// WindowsUnityBridge / EmbedUnityBridge など全ての実装クラスで
  /// sendEmotions() を実装する必要がある。
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
  ///
  /// サーバーから 140〜270ms 間隔で届くので、Unity 側は届いた順に
  /// 追記するだけで自然なタイプライター表示になる。
  void sendText({
    required String text,
    bool isFiller = false,
  });

  /// bubble_break を Unity へ転送する
  ///
  /// ツールの前置き（「ちょっと待ってね」）と本文を別の吹き出しに
  /// 分けるための区切り。
  void sendBubbleBreak();

  /// chat_end を Unity へ転送する
  ///
  /// Unity 側はここから吹き出しの消去タイマーを開始する。
  /// [fullText] は取りこぼし対策の最終確定テキスト。
  void sendChatEnd({String? fullText});

  /// 通信を停止
  Future<void> stop();
}
