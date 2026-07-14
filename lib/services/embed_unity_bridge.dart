import 'dart:convert';
import 'package:flutter_embed_unity/flutter_embed_unity.dart';
import 'package:raim_prototype/services/unity_communicator.dart';

/// iOS/Android 版での Unity 通信実装
/// 
/// flutter_embed_unity の sendToUnity 関数を使って、
/// Unity 内の GameObject のメソッドを直接呼ぶ
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
  
  @override
  Future<void> start() async {
    // flutter_embed_unity は自動初期化なので何もしない
    print('EmbedUnityBridge: 初期化完了（Unity ウィジェット描画時に起動）');
  }
  
  @override
  void sendEmotion({
    required String text,
    required String emotion,
    required double intensity,
  }) {
    // emotion 文字列だけを Unity に送る（シンプルに）
    sendToUnity(
      gameObjectName,
      emotionMethodName,
      emotion,
    );
    
    print('Unity 送信: $gameObjectName.$emotionMethodName($emotion)');
  }
  
  @override
  Future<void> stop() async {
    // flutter_embed_unity は自動管理なので明示的な停止不要
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