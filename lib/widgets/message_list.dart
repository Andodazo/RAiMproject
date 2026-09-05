//ユーザー入力後を含む、会話履歴を画面に表示・更新する処理
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/widgets/message_bubble.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/services/raim_log.dart';

class MessageList extends StatefulWidget {
  const MessageList({super.key});

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  /// 最新のメッセージを追いかけるためのコントローラ。
  ///
  /// 以前はコントローラ自体が無く、返答が流れてきても画面が追従しなかった。
  /// ユーザーは自分で下へスクロールし続ける必要があった。
  final ScrollController _scrollController = ScrollController();

  /// 末尾からこの距離以内にいれば「最新を追っている」とみなす。
  ///
  /// 過去を読み返している最中に勝手に下へ飛ばされると読めなくなるので、
  /// 下端付近にいるときだけ追従する。
  static const double _followThreshold = 120;

  bool get _isNearBottom {
    if (!_scrollController.hasClients) return true;

    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels <= _followThreshold;
  }

  /// 描画後に末尾へ寄せる。
  ///
  /// text_chunk のたびに再描画されるので、ストリーミング中も追従する。
  /// アニメーションさせると細かく再生され続けて逆に見づらいため jumpTo にする。
  void _scheduleFollow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

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

        // 判定は再描画の「前」の位置で行う。
        // 「もっと見る」で先頭に差し込んだ直後はユーザーが上にいるので、
        // 追従せず読んでいる位置が保たれる。
        if (_isNearBottom) {
          _scheduleFollow();
        }

        return ListView.builder(
          controller: _scrollController,
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
                              // 履歴の画像は端末のローカルパスを指している。
                              // 再インストール後・別端末・元画像を消したあとは
                              // 読み込めず、例外がログに出て枠だけが残っていた。
                              onError: (error, stackTrace) {
                                RaimLog.d('[MessageList] 画像を表示できません');
                              },
                            ),
                          ),
                          child: _MissingImageHint(path: imagePath),
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

/// 画像ファイルが見つからないときだけ見えるヒント。
///
/// DecorationImage が描けた場合はその下に隠れるので、
/// 読み込めたときは何も見えない。
class _MissingImageHint extends StatelessWidget {
  const _MissingImageHint({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    if (File(path).existsSync()) return const SizedBox.shrink();

    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_not_supported_outlined,
              color: Colors.white38, size: 28),
          SizedBox(height: 6),
          Text(
            '画像は端末に残っていません',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
        ],
      ),
    );
  }
}