import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/widgets/message_bubble.dart';

class MessageList extends StatelessWidget {
  const MessageList({super.key});
  
  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, child) {
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
            
            return MessageBubble(message: messages[index]);
          },
        );
      },
    );
  }
}