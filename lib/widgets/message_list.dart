//ユーザー入力後を含む、会話履歴を画面に表示・更新する処理
import 'dart:io';
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
        // 追加: Tool状態を表示する位置
        final toolStatusIndex = messages.length;
        // metadata受信中だけ考え中表示を追加する
        final showThinking = provider.isThinking;
        // 考え中表示を追加する位置
        final thinkingIndex = messages.length + (hasToolStatus ? 1 : 0);
        // Hot Restart やアプリ再起動後は、ChatProvider の会話履歴が空になる。
        // 会話履歴・検索中表示・ローディング表示がすべて無い場合は、
        // チャット欄に何も表示せず、入力欄のプレースホルダーだけを見せる。
        // 遡れる履歴が残っている場合は、表示中のメッセージが空でも
        // 「もっと見る」を出したいので早期リターンしない。
        if (messages.isEmpty &&
            !hasToolStatus &&
            !provider.isLoading &&
            !provider.hasMoreHistory) {
          return const Center(
          );
        }
        
        // 過去メッセージの遡り。
        //
        // サーバーは1回の応答で一定量しか返さない（WebSocket の送信上限のため）。
        // 続きがある場合は先頭に「もっと見る」を置く。
        //
        // スクロール位置を監視する自動読み込みにすると、
        // 差し込み後に表示位置が飛ぶ扱いが要る。明示的なボタンの方が
        // 挙動が読みやすいのでこちらにしている。
        final showLoadOlder = provider.hasMoreHistory;
        final loadOlderOffset = showLoadOlder ? 1 : 0;

        return ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: loadOlderOffset +
              messages.length +
              (hasToolStatus ? 1 : 0) +
              (showThinking ? 1 : 0),
          itemBuilder: (context, rawIndex) {
            // 先頭の「もっと見る」
            if (showLoadOlder && rawIndex == 0) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: provider.isLoadingOlder
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            color: Color(0xFFB4E61D),
                            strokeWidth: 2,
                          ),
                        )
                      : TextButton(
                          onPressed: () => provider.loadOlderMessages(),
                          child: const Text(
                            'もっと見る',
                            style: TextStyle(
                              color: Color(0xFFB4E61D),
                              fontSize: 13,
                            ),
                          ),
                        ),
                ),
              );
            }

            // 以降は「もっと見る」の分だけ添字をずらす
            final index = rawIndex - loadOlderOffset;
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
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                ),
              );
            }
            // ローディング中なら最後にローディング表示
            if (showThinking && index == thinkingIndex) {
              return const Padding(
                padding: EdgeInsets.all(8),
                child: Row(
                  children: [
                    ThinkingIndicator(),
                    SizedBox(width: 8),
                    Text(
                      '考え中…',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
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

    // 「考え中」の3つの点を表示するウィジェット
    class ThinkingIndicator extends StatefulWidget {
      const ThinkingIndicator({super.key});

      @override
      State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
    }

    // アニメーションの状態を管理するクラス
    class _ThinkingIndicatorState extends State<ThinkingIndicator>
        with SingleTickerProviderStateMixin {
      late final AnimationController _controller;

      @override
      void initState() {
        super.initState();

        // 900ミリ秒ごとにアニメーションを繰り返す
        _controller = AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 900),
        )..repeat();
      }

      @override
      void dispose() {
        // 画面破棄時にアニメーションを停止する
        _controller.dispose();
        super.dispose();
      }

      @override
      Widget build(BuildContext context) {
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            // 現在明るくする点の番号を計算する
            final activeIndex = (_controller.value * 3).floor();

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (index) {
                return AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),

                  // 現在の点だけ明るくする
                  opacity: activeIndex == index ? 1.0 : 0.3,

                  child: Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.symmetric(horizontal: 3),

                    // 丸い白い点を作る
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                );
              }),
            );
          },
        );
      }
    }