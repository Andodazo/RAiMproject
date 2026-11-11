// lib/models/planner_card.dart
//
// チャットに出す予定のカード。
//
//   入れたよカード … ライムが予定を入れたとき（planner.added）。「取り消す」が押せる
//   「予定に入れる？」 … 話に出ただけの予定（planner.suggest）。押すと入れる
//
// サーバーの会話の記録には残らない（開き直すと消える）。予定そのものは
// 「予定とメモ」の画面にいつでもある。

import 'package:raim_prototype/models/planner_item.dart';

enum PlannerCardType { added, suggest }

enum PlannerCardState {
  /// 押される前
  open,

  /// 処理中（取り消し中・入れている途中）
  busy,

  /// 取り消した（入れたよカード）
  undone,

  /// 入れた（「予定に入れる？」）
  accepted,

  /// 閉じた（「予定に入れる？」で × を押した）
  dismissed,

  /// うまくいかなかった（もう一度押せる）
  failed,
}

class PlannerCard {
  const PlannerCard._({
    required this.type,
    required this.createdAt,
    this.item,
    this.candidate,
    this.state = PlannerCardState.open,
  });

  factory PlannerCard.added(PlannerItem item, {DateTime? at}) => PlannerCard._(
        type: PlannerCardType.added,
        item: item,
        createdAt: at ?? DateTime.now(),
      );

  factory PlannerCard.suggest(PlannerCandidate candidate, {DateTime? at}) =>
      PlannerCard._(
        type: PlannerCardType.suggest,
        candidate: candidate,
        createdAt: at ?? DateTime.now(),
      );

  final PlannerCardType type;

  /// 入れた予定（added のとき）
  final PlannerItem? item;

  /// 入れるか聞く予定（suggest のとき）
  final PlannerCandidate? candidate;

  final PlannerCardState state;
  final DateTime createdAt;

  String get title => item?.title ?? candidate?.title ?? '';
  String get whenLabel => item?.whenLabel ?? candidate?.whenLabel ?? '';

  /// まだ押せるか
  bool get isActionable =>
      state == PlannerCardState.open || state == PlannerCardState.failed;

  PlannerCard withState(PlannerCardState next) => PlannerCard._(
        type: type,
        item: item,
        candidate: candidate,
        createdAt: createdAt,
        state: next,
      );
}
