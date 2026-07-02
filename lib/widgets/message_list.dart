//ユーザー入力後を含む、会話履歴を画面に表示・更新する処理
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/widgets/message_bubble.dart';

class MessageList extends StatelessWidget {
  const MessageList({super.key});
  
  @override
  Widget build(BuildContext context) {
    //chatproviderの状態変化を監視
    return Consumer<ChatProvider>(
      builder: (context, provider, child) {
        //会話履歴の取得(ユーザー・AIどちらとも)
        final messages = provider.messages;
        
        return ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: messages.length + (provider.isLoading ? 1 : 0),
          itemBuilder: (context, index) {
            // ローディング中なら最後にローディング表示
            if (provider.isLoading && index == messages.length) {
              return const Padding(
                padding: EdgeInsets.all(8),
                child: Text('考え中...'),
              );
            }
            //各メッセージを吹き出し表示。※ユーザーなら右・AIなら左の処理はmessage_bubbleが担当
            return MessageBubble(message: messages[index]);
          },
        );
      },
    );
  }
}