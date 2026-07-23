import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/models/message.dart';

/// キャラクター（立ち絵）を表示するウィジェット
/// windows用のfile(windows unity)
/// ChatProvider の最新メッセージから emotion を取得して、
/// 対応する立ち絵画像を表示する
class CharacterDisplay extends StatelessWidget {
  const CharacterDisplay({super.key});
  
  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, chatProvider, _) {
        // 最新のAIメッセージから emotion を取得
        final emotion = _getCurrentEmotion(chatProvider.messages);
        final imagePath = _getImagePath(emotion);
        //画像の配置
        return Container(
          alignment: Alignment.bottomCenter,
          child: Image.asset(
            imagePath,
            fit: BoxFit.contain,
          ),
        );
      },
    );
  }
  
  /// 最新のAIメッセージから emotion を取り出す（AIのメッセージかつ感情が設定されているもの）
  /// メッセージがないまたは感情が入ってない場合はdefault
  /// なければ default
  String _getCurrentEmotion(List<Message> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      if (msg.role == MessageRole.assistant && msg.emotion != null) {
        return msg.emotion!;
      }
    }
    return 'default';
  }
  
  /// emotion → 画像パスのマッピング
  String _getImagePath(String emotion) {
    switch (emotion) {
      case 'amused':
        return 'assets/images/amused.png';
      case 'angry':
        return 'assets/images/angry.png';
      case 'caring':
        return 'assets/images/caring.png';
      case 'curious':
        return 'assets/images/curious.png';
      case 'embarrassed':
        return 'assets/images/embarrassed.png';
      case 'excited':
        return 'assets/images/excited.png';
      case 'happy':
        return 'assets/images/happy.png';
      case 'playful':
        return 'assets/images/playful.png';
      case 'sad':
        return 'assets/images/sad.png';
      case 'surprised':
        return 'assets/images/surprise.png';
      case 'thoughtful':
        return 'assets/images/thoughtful.png';
      case 'investigate':
         return 'assets/images/investigate.png';
      default:
        return 'assets/images/default.png';
    }
  }
}