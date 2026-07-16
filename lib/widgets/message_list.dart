//ユーザー入力後を含む、会話履歴を画面に表示・更新する処理
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/widgets/message_bubble.dart';
import 'package:raim_prototype/models/message.dart';

class MessageList extends StatelessWidget {
  const MessageList({super.key});
  
  @override
  Widget build(BuildContext context) {
    //chatproviderの状態変化を監視
    return Consumer<ChatProvider>(
      builder: (context, provider, child) {
        //会話履歴の取得(ユーザー・AIどちらとも)
        final messages = provider.messages;

        // ============================================================
        // tool_call 表示用の状態
        // ============================================================
        // RAiM v2.2 では、検索などの外部ツール実行中に tool_call が届く。
        // ChatProvider 側で _toolStatus に入れた文を、ここで一時表示する。
        //
        // 例: 「ラーメンの歴史を検索しています」
        //
        // toolStatus は通常の Message ではないため、
        // ListView の itemCount と index を手動で調整する。
        final hasToolStatus = provider.toolStatus != null && provider.toolStatus!.isNotEmpty;
        // toolStatus は通常メッセージの直後に表示する
        final toolStatusIndex = messages.length;
        // loading 表示は toolStatus のさらに後ろに表示する
        final loadingIndex = messages.length + (hasToolStatus ? 1 : 0);
        // Hot Restart やアプリ再起動後は、ChatProvider の会話履歴が空になる。
        // 会話履歴・検索中表示・ローディング表示がすべて無い場合は、
        // チャット欄に何も表示せず、入力欄のプレースホルダーだけを見せる。
        if (messages.isEmpty && !hasToolStatus && !provider.isLoading) {
          return const Center(
          );
        }
        
        return ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: messages.length + (hasToolStatus ? 1 : 0) + (provider.isLoading ? 1 : 0),
          itemBuilder: (context, index) {
            // ============================================================
            // tool_call の状態表示
            // ============================================================
            // 検索などの外部処理中だけ表示する。
            // chat_end が来て ChatProvider 側で toolStatus が null になると消える。
            if (hasToolStatus && index == toolStatusIndex) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    provider.toolStatus!,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 13,
                    ),
                  ),
                ),
              );
            }
            // ローディング中なら最後にローディング表示
            if (provider.isLoading && index == loadingIndex) {
              return const Padding(
                padding: EdgeInsets.all(8),
                child: Text('考え中...'),
              );
            }

            final message = messages[index];

            // MessageBubble と同じ判定方法に変更
            final isUser = message.role == MessageRole.user;

            // Messageモデル内の画像パスプロパティ名に合わせる
            final hasImages = message.selectedImagePaths != null && message.selectedImagePaths!.isNotEmpty;

            return Column(
              crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 画像データがある場合、プレビューと同じ見た目のContainerを表示
                if (hasImages)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    child: Wrap(
                      spacing: 12, // プレビューの隙間と同じ
                      runSpacing: 8,
                      children: message.selectedImagePaths!.map<Widget>((imagePath) {
                        return Container(
                          width: 130,  // チャット欄で見やすいようにプレビューより少し大きめに
                          height: 130,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12), // プレビューと共通の丸み
                            border: Border.all(
                              color: Colors.white30, // プレビューと共通のガラス風の白い細枠
                              width: 1.5,
                            ),
                            //FileImageでの描画に統一
                            image: DecorationImage(
                              image: FileImage(File(imagePath)),
                              fit: BoxFit.cover, // プレビューと同じく全体をカバー
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),          
                  //各メッセージを吹き出し表示。※ユーザーなら右・AIなら左の処理はmessage_bubbleが担当
                  MessageBubble(message: messages[index]),
              ],
            );
          },
        );
      },
    );
  }
}