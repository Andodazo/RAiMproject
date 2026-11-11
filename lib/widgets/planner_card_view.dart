// lib/widgets/planner_card_view.dart
//
// チャットに出す予定のカード（入れたよ・予定に入れる？・タイマーを始めたよ・メモ）。
// 「この前話したお店なんだっけ」で見つけた会話を開くカードもここで出す。
//
// スマホはチャットの中に、Windows は入力欄の上に（compact）出す。
// 押したときの処理（取り消す・入れる）はここで PlannerController を呼び、
// カードの見た目の状態は ChatProvider が持つ。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:raim_prototype/models/planner_card.dart';
import 'package:raim_prototype/models/planner_item.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/providers/planner_controller.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/widgets/planner_memo_panel.dart';

class PlannerCardView extends StatelessWidget {
  const PlannerCardView({
    super.key,
    required this.card,
    this.compact = false,
    this.textColor = const Color(0xFF1F2328),
    this.mutedColor = const Color(0xFF5B6570),
    this.accentColor = const Color(0xFF4D7C0F),
    this.background = const Color(0xFFF1F6E8),
    this.borderColor = const Color(0xFFCFE3A8),
    this.onOpenMemos,
    this.onOpenedTalk,
  });

  /// メモのカードで「開く」を押したとき（Windows は入力欄の上で中身を出せないので、メモタブを開く）
  final VoidCallback? onOpenMemos;

  /// 前の会話を開いたあと（Windows は会話ログを開いて見せる）
  final VoidCallback? onOpenedTalk;

  final PlannerCard card;

  /// Windows の入力欄の上に出す、1行の形
  final bool compact;

  final Color textColor;
  final Color mutedColor;
  final Color accentColor;
  final Color background;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    if (card.type == PlannerCardType.show && !compact) return _showCard(context);
    final message = _message();
    final actions = _actions(context);
    final content = Row(
      children: [
        Icon(
          card.type == PlannerCardType.talk ? Icons.history : Icons.event_note_outlined,
          size: compact ? 16 : 18,
          color: accentColor,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            maxLines: compact ? 2 : 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor, fontSize: compact ? 12 : 13.5, height: 1.3),
          ),
        ),
        ...actions,
      ],
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: content,
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: content,
      ),
    );
  }

  String _message() {
    if (card.type == PlannerCardType.show) return _showSummary();
    if (card.type == PlannerCardType.talk) {
      final label = card.talk?.label ?? '前の会話';
      return card.state == PlannerCardState.failed ? '$label を開けなかった' : label;
    }
    final item = card.item;
    if (item != null && item.isTimer) return _timerMessage(item);
    if (item != null && item.isMemo) {
      return card.state == PlannerCardState.undone
          ? 'メモを取り消したよ'
          : card.state == PlannerCardState.failed
              ? '取り消せなかった。もう一度押してね'
              : '「${item.text}」をメモしたよ';
    }
    if (item != null && item.isList) return _listMessage(item);
    final what = '${card.whenLabel} ${card.title}';
    return switch ((card.type, card.state)) {
      (PlannerCardType.added, PlannerCardState.undone) => '$what を取り消したよ',
      (PlannerCardType.added, PlannerCardState.failed) => '取り消せなかった。もう一度押してね',
      (PlannerCardType.added, _) => '$what を入れたよ',
      (PlannerCardType.suggest, PlannerCardState.accepted) => '$what を入れたよ',
      (PlannerCardType.suggest, PlannerCardState.failed) => '入れられなかった。もう一度押してね',
      (PlannerCardType.suggest, _) => '予定に入れる？ $what',
      (PlannerCardType.show, _) => _showSummary(),
      (PlannerCardType.talk, _) => card.talk?.label ?? '前の会話',
    };
  }

  /// 「3分のタイマーを始めたよ（15:03 に鳴る）」
  String _timerMessage(PlannerItem item) {
    final label = item.title.trim();
    final length = item.durationLabel;
    final name = (label.isEmpty || label == 'タイマー')
        ? (length.isEmpty ? 'タイマー' : '$lengthのタイマー')
        : (length.isEmpty ? '$labelのタイマー' : '$labelのタイマー（$length）');
    return switch (card.state) {
      PlannerCardState.undone => '$nameを止めたよ',
      PlannerCardState.failed => '止められなかった。もう一度押してね',
      _ => '$nameを始めたよ（${item.whenLabel}）',
    };
  }

  /// リストに入れたときの文
  String _listMessage(PlannerItem item) {
    final added = card.isListAddition
        ? item.entries.where((e) => card.addedEntryIds.contains(e.id)).map((e) => e.text).toList()
        : item.entries.map((e) => e.text).toList();
    final what = added.isEmpty ? '' : '${added.take(4).join('・')}${added.length > 4 ? ' ほか' : ''} を';
    return switch (card.state) {
      PlannerCardState.undone => card.isListAddition ? '足した項目を取り消したよ' : '「${item.title}」を取り消したよ',
      PlannerCardState.failed => '取り消せなかった。もう一度押してね',
      _ => card.isListAddition ? '「${item.title}」に $what足したよ' : '「${item.title}」を作って $what入れたよ',
    };
  }

  /// メモのカードを1行にしたもの（Windows の入力欄の上）
  String _showSummary() {
    final items = card.showItems;
    final events = items.where((i) => i.isEvent).toList();
    if (events.isNotEmpty) {
      return '今日の予定: ${events.take(4).map(_eventLine).join('・')}${events.length > 4 ? ' ほか' : ''}';
    }
    final memos = items.where((i) => i.isMemo).toList();
    if (memos.isNotEmpty) {
      return 'メモ ${memos.length}件「${memos.first.text}」${memos.length > 1 ? ' ほか' : ''}';
    }
    final list = items.first;
    final open = list.openEntries.map((e) => e.text).toList();
    return '${list.title}: ${open.isEmpty ? '全部チェック済み' : open.take(5).join('・')}';
  }

  /// 今日の予定の1行「15:00 バイト」
  static String _eventLine(PlannerItem e) => e.hasTime ? '${e.time} ${e.title}' : e.title;

  /// メモのカード（スマホのチャットの中）。リストはその場でチェックできる。
  /// 朝のまとめでは、今日の予定を全部出す
  Widget _showCard(BuildContext context) {
    final items = card.showItems;
    final events = items.where((i) => i.isEvent).toList();
    final memos = items.where((i) => i.isMemo).toList();
    final lists = items.where((i) => i.isList).toList();
    final title = TextStyle(color: textColor, fontSize: 13.5, fontWeight: FontWeight.w600);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (events.isNotEmpty) ...[
              Row(children: [
                Icon(Icons.today_outlined, size: 16, color: accentColor),
                const SizedBox(width: 6),
                Text('今日の予定', style: title),
              ]),
              const SizedBox(height: 4),
              for (final e in events)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 48,
                        child: Text(e.hasTime ? e.time : '終日', style: TextStyle(color: mutedColor, fontSize: 12.5)),
                      ),
                      Expanded(child: Text(e.title, style: TextStyle(color: textColor, fontSize: 13, height: 1.35))),
                    ],
                  ),
                ),
            ],
            if (memos.isNotEmpty) ...[
              Row(children: [
                Icon(Icons.sticky_note_2_outlined, size: 16, color: accentColor),
                const SizedBox(width: 6),
                Text('メモ', style: title),
              ]),
              const SizedBox(height: 4),
              for (final memo in memos.take(10))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('・${memo.text}', style: TextStyle(color: textColor, fontSize: 13, height: 1.35)),
                ),
              if (memos.length > 10)
                Text('ほかに${memos.length - 10}件（「予定とメモ」のメモタブ）',
                    style: TextStyle(color: mutedColor, fontSize: 11.5)),
            ],
            for (final list in lists) ...[
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(children: [
                  Icon(Icons.checklist, size: 16, color: accentColor),
                  const SizedBox(width: 6),
                  Expanded(child: Text(list.title, style: title)),
                ]),
              ),
              PlannerListEntries(
                listId: list.itemId,
                fallback: list,
                textColor: textColor,
                mutedColor: mutedColor,
                accentColor: accentColor,
                maxEntries: 15,
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    if (card.type == PlannerCardType.show) {
      // Windows の入力欄の上: メモタブを開く・閉じる
      return [
        if (onOpenMemos != null) _button('開く', onOpenMemos!),
        _close(context),
      ];
    }
    if (card.state == PlannerCardState.busy) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: accentColor),
          ),
        ),
      ];
    }
    if (!card.isActionable) {
      // Windows の入力欄の上のカードは、押し終わったら × で閉じる
      return compact ? [_close(context)] : const [];
    }
    if (card.type == PlannerCardType.added) {
      return [_button('取り消す', () => _undo(context)), if (compact) _close(context)];
    }
    if (card.type == PlannerCardType.talk) {
      return [_button('開く', () => _openTalk(context)), if (compact) _close(context)];
    }
    return [_button('入れる', () => _accept(context)), _close(context)];
  }

  Widget _button(String label, VoidCallback onPressed) => TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          label,
          style: TextStyle(color: accentColor, fontSize: compact ? 12 : 13, fontWeight: FontWeight.w600),
        ),
      );

  Widget _close(BuildContext context) => IconButton(
        tooltip: '閉じる',
        icon: const Icon(Icons.close, size: 15),
        color: mutedColor,
        splashRadius: 15,
        visualDensity: VisualDensity.compact,
        onPressed: () => context
            .read<ChatProvider>()
            .updatePlannerCard(card, PlannerCardState.dismissed),
      );

  Future<void> _undo(BuildContext context) async {
    final chat = context.read<ChatProvider>();
    final planner = context.read<PlannerController>();
    final itemId = card.item?.itemId;
    if (itemId == null) return;
    final busy = chat.updatePlannerCard(card, PlannerCardState.busy);
    try {
      if (card.isListAddition) {
        // リストに足した項目だけ消す（前からあった項目は残す）
        await planner.removeEntries(itemId, card.addedEntryIds.toSet());
      } else {
        await planner.deleteItem(itemId);
      }
      if (busy != null) chat.updatePlannerCard(busy, PlannerCardState.undone);
    } catch (e) {
      RaimLog.d('[PlannerCard] 取り消せませんでした: ${e.runtimeType}');
      if (busy != null) chat.updatePlannerCard(busy, PlannerCardState.failed);
    }
  }

  /// 見つけた前の会話を開いて、その発言まで送る。何度でも開ける
  Future<void> _openTalk(BuildContext context) async {
    final chat = context.read<ChatProvider>();
    final talk = card.talk;
    if (talk == null) return;
    final busy = chat.updatePlannerCard(card, PlannerCardState.busy);
    bool opened = false;
    try {
      opened = await chat.openPastTalk(talk);
    } catch (e) {
      RaimLog.d('[PlannerCard] 前の会話を開けませんでした: ${e.runtimeType}');
    }
    // 別の会話を開くと、このカードは画面から消える（前の会話にはカードが無い）
    if (busy != null) chat.updatePlannerCard(busy, opened ? PlannerCardState.open : PlannerCardState.failed);
    if (opened) onOpenedTalk?.call();
  }

  Future<void> _accept(BuildContext context) async {
    final chat = context.read<ChatProvider>();
    final planner = context.read<PlannerController>();
    final candidate = card.candidate;
    if (candidate == null) return;
    final busy = chat.updatePlannerCard(card, PlannerCardState.busy);
    try {
      await planner.addEvent(
        title: candidate.title,
        date: candidate.date,
        time: candidate.time,
        source: 'suggest',
        followUpId: candidate.followUpId,
      );
      if (busy != null) chat.updatePlannerCard(busy, PlannerCardState.accepted);
    } catch (e) {
      RaimLog.d('[PlannerCard] 入れられませんでした: ${e.runtimeType}');
      if (busy != null) chat.updatePlannerCard(busy, PlannerCardState.failed);
    }
  }
}
