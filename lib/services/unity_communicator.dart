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

  /// Flutter 側で終了が選ばれたことを Unity へ伝える。
  ///
  /// Flutter が Unity を起動した場合は stop() の kill で落とせるが、
  /// Unity Editor や手動起動の場合は kill が効かない。
  /// Unity 自身に終了してもらうためのメッセージ。
  void sendAppQuit();

  /// 画面の並びを Unity へ伝える（スマホのみ使う）。
  ///
  /// [headTop] は、ライムの頭のてっぺんを置きたい高さ（画面の上からの割合、0〜1）。
  /// 「新しい会話」のバーのすぐ下に来るよう、ChatScreen が計算して送る。
  /// 割合で渡すので、端末の画面サイズが違ってもライムの見え方がそろう。
  void sendLayout({required double headTop});

  /// ライムを寝ている立ち絵にする / 起こす。
  ///
  /// サーバーにつながらない（offline）間は寝ている立ち絵にする。
  /// Unity がまだ起動していなかった場合も、起動したら反映されるよう覚えておく。
  void sendSleeping(bool sleeping);

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

  /// Unity が接続中か。トレイメニューの出し分けに使う。
  bool get isUnityConnected;

  /// Unity が落ちていたら起動し直す。
  /// 既に繋がっていれば何もしない。
  Future<void> ensureUnityRunning();

  /// Windows展示モードの表示状態を Unity へ通知する。
  /// モバイル実装では何もしない。
  void setExhibitionMode(bool enabled);

  /// 通信を停止
  Future<void> stop();
}
