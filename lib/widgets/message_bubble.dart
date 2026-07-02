//chat画面の一件分のメッセージを吹き出しとして表示する
import 'package:flutter/material.dart';
import 'package:raim_prototype/models/message.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  
  const MessageBubble({super.key, required this.message});
  
  @override
  Widget build(BuildContext context) {
    //メッセージがユーザーの発言かどうかを判定
    final isUser = message.role == MessageRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser ? Colors.blue[100] : Colors.grey[200],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message.text),
            if (message.emotion != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '感情: ${message.emotion}',
                  style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}