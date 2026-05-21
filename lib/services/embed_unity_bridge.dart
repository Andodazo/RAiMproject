import 'package:raim_prototype/services/unity_communicator.dart';

/// iOS/Android 版での通信実装
///
/// 現在は Android でも Windows と同じ Image.asset 表示にするため、
/// Unity への送信は一時的に行わない。
class EmbedUnityBridge implements UnityCommunicator {
  @override
  Future<void> start() async {
    // Unityを使わないため、ここでは何もしない
    print('EmbedUnityBridge: Unity送信なしで起動');
  }

  @override
  void sendEmotion({
    required String text,
    required String emotion,
    required double intensity,
  }) {
    // CharacterDisplay は ChatProvider の emotion を見て画像を切り替えるため、
    // Unityへ送信しなくても画面表示は切り替わる
    print('Unity送信スキップ: emotion=$emotion, intensity=$intensity');
  }

  @override
  Future<void> stop() async {
    // Unityを使わないため、ここでは何もしない
  }
}