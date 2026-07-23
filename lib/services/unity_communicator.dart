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
  /// 通信を停止
  Future<void> stop();
}