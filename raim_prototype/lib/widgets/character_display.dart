import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/models/message.dart';

/// キャラクター（立ち絵）を表示するウィジェット
/// 
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
  
  /// 最新のAIメッセージから emotion を取り出す
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
      case 'happy':
        return 'assets/images/happy.png';
      case 'sad':
        return 'assets/images/sad.png';
      case 'angry':
        return 'assets/images/angry.png';
      case 'surprised':
        return 'assets/images/surprise.png';
      case 'neutral':
      case 'caring':
      default:
        return 'assets/images/default.png';
    }
  }
}