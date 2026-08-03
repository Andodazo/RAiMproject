// lib/widgets/thread_selector_menu.dart
// =============================================================================
// 会話スレッドの選択メニュー
// =============================================================================
//
// 「新しい会話」ボタンの真下に出るドロップダウン。
// ボタンに下向き矢印が付いているので、下から生えてくる形に合わせている。
//
// 【showMenu ではなく Overlay を使う理由】
//
// showMenu は開いた時点で項目が確定し、あとから差し替えられない。
// そのため「一覧を読んでから開く」ことになり、タップしても数百ms〜数秒
// 何も起きない時間ができる（壊れているように見える）。
//
// Overlay なら開いた状態のまま中身を差し替えられるので、
// タップした瞬間に開いて、中で読み込み状態を見せられる。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/models/conversation_thread.dart';

const Color _kAccent = Color(0xFFB4E61D);
const Color _kSurface = Color(0xFF1C1F26);

/// スレッド選択メニューをボタンの真下に開く
///
/// [buttonContext] は「新しい会話」ボタン自身の BuildContext。
/// 画面全体の context を渡すと位置がずれる。
void showThreadMenu(BuildContext buttonContext) {
  final provider = buttonContext.read<ChatProvider>();
  final anchor = _anchorRect(buttonContext);
  if (anchor == null) return;

  final overlay = Overlay.of(buttonContext);
  late OverlayEntry entry;

  void close() {
    if (entry.mounted) entry.remove();
  }

  entry = OverlayEntry(
    builder: (_) => _ThreadMenuOverlay(
      anchor: anchor,
      provider: provider,
      onClose: close,
    ),
  );

  overlay.insert(entry);

  // 開いてから読み込む。Consumer が拾って中身が差し替わる
  provider.loadThreads();
}

/// ボタンの位置と大きさを、オーバーレイ座標で得る
Rect? _anchorRect(BuildContext buttonContext) {
  final button = buttonContext.findRenderObject();
  final overlayBox = Overlay.of(buttonContext).context.findRenderObject();

  if (button is! RenderBox || overlayBox is! RenderBox) return null;
  if (!button.hasSize) return null;

  final topLeft = button.localToGlobal(Offset.zero, ancestor: overlayBox);
  return topLeft & button.size;
}

class _ThreadMenuOverlay extends StatelessWidget {
  const _ThreadMenuOverlay({
    required this.anchor,
    required this.provider,
    required this.onClose,
  });

  final Rect anchor;
  final ChatProvider provider;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;

    // ボタンが細いときでも読める幅を確保する
    final width = anchor.width.clamp(260.0, 360.0);

    // 右端がはみ出すなら左へずらす
    var left = anchor.left;
    if (left + width > screen.width - 8) {
      left = screen.width - width - 8;
    }
    if (left < 8) left = 8;

    // ボタン下端からの残り高さに収める
    final top = anchor.bottom + 6;
    final maxHeight = (screen.height - top - 16).clamp(120.0, 420.0);

    return Stack(
      children: [
        // 外側タップで閉じる。透明な全画面レイヤー
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: width,
          child: ChangeNotifierProvider<ChatProvider>.value(
            value: provider,
            child: _MenuCard(maxHeight: maxHeight, onClose: onClose),
          ),
        ),
      ],
    );
  }
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({required this.maxHeight, required this.onClose});

  final double maxHeight;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _kSurface,
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _NewThreadRow(onClose: onClose),
            const Divider(color: Colors.white12, height: 1),
            Flexible(child: _ThreadListSection(onClose: onClose)),
          ],
        ),
      ),
    );
  }
}

/// 「新しい会話を始める」
class _NewThreadRow extends StatelessWidget {
  const _NewThreadRow({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        context.read<ChatProvider>().startNewThread();
        onClose();
      },
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.add_comment_outlined, color: _kAccent, size: 18),
            SizedBox(width: 10),
            Text(
              '新しい会話を始める',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一覧部分（読み込み中・エラー・空・一覧を出し分ける）
class _ThreadListSection extends StatelessWidget {
  const _ThreadListSection({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        // 読み込み中かつ一覧が空のときだけ。
        // 高さを固定しないと Flexible が使える高さを全部取ってしまう
        if (provider.isLoadingThreads && provider.threads.isEmpty) {
          return const SizedBox(
            height: 56,
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  color: _kAccent,
                  strokeWidth: 2,
                ),
              ),
            ),
          );
        }

        // 失敗したときは黙って空にせず、理由と再試行を出す
        if (provider.threadError != null && provider.threads.isEmpty) {
          return _MessageRow(
            text: provider.threadError!,
            actionLabel: '再試行',
            onAction: () => provider.loadThreads(),
          );
        }

        if (provider.threads.isEmpty) {
          return const _MessageRow(text: 'まだ会話がありません');
        }

        return ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: provider.threads.length,
          itemBuilder: (context, index) {
            final thread = provider.threads[index];
            return _ThreadRow(
              thread: thread,
              isCurrent: thread.threadId == provider.currentThreadId,
              onTap: () {
                if (thread.threadId != provider.currentThreadId) {
                  provider.switchThread(thread.threadId);
                }
                onClose();
              },
            );
          },
        );
      },
    );
  }
}

/// 読み込み結果が無いときの1行
class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.text, this.actionLabel, this.onAction});

  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Text(
                  text,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ),
            ),
            if (actionLabel != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  actionLabel!,
                  style: const TextStyle(color: _kAccent, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 一覧の1行
class _ThreadRow extends StatelessWidget {
  const _ThreadRow({
    required this.thread,
    required this.isCurrent,
    required this.onTap,
  });

  final ThreadSummary thread;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(
              isCurrent
                  ? Icons.chat_bubble_rounded
                  : Icons.chat_bubble_outline_rounded,
              color: isCurrent ? _kAccent : Colors.white38,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    thread.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight:
                          isCurrent ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (thread.displayDate.isNotEmpty) thread.displayDate,
                      '${thread.turnCount}往復',
                    ].join(' ・ '),
                    style: const TextStyle(
                      color: Colors.white30,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
