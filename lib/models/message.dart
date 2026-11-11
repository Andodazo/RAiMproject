//全体Messageの定義
import 'package:raim_prototype/models/planner_card.dart';

//Messageの型定義
class Message {
  final String text;
  final MessageRole role;
  final DateTime timestamp;
  final String? emotion;
  final double? intensity;
  final List<String>? selectedImagePaths;
  final Map<String, double> emotions;
  final double overallIntensity;

  /// 予定のカード（入れたよ・予定に入れる？）。ふつうの発言では null。
  /// カードのときは text が空で、ライムの返事のあとに並ぶ
  final PlannerCard? plannerCard;
//Messageの戻り値
  Message({
    required this.text,
    required this.role,
    required this.timestamp,
    this.emotion,
    this.intensity,
    this.selectedImagePaths,
    this.emotions = const {'neutral': 1.0},
    this.overallIntensity = 0.5,
    this.plannerCard,
  });

  // ============================================================
  // text_chunk 更新用コピー処理
  // ============================================================
  // 既存のMessageを直接書き換えず、
  // 一部の値だけ変更した新しいMessageを作る。
  //
  // text_chunk を受け取るたびに、
  // textだけを「元の文章 + 新しいchunk」に更新するために使う。
  //
  // chat_end では emotion / intensity / emotions / overallIntensity だけを
  // 最終結果に更新するためにも使う。
  Message copyWith({
    String? text,
    MessageRole? role,
    DateTime? timestamp,
    String? emotion,
    double? intensity,
    List<String>? selectedImagePaths,
    Map<String, double>? emotions,
    double? overallIntensity,
    PlannerCard? plannerCard,
  }) {
    return Message(
      text: text ?? this.text,
      role: role ?? this.role,
      timestamp: timestamp ?? this.timestamp,
      emotion: emotion ?? this.emotion,
      intensity: intensity ?? this.intensity,
      selectedImagePaths: selectedImagePaths ?? this.selectedImagePaths,
      emotions: emotions ?? this.emotions,
      overallIntensity: overallIntensity ?? this.overallIntensity,
      plannerCard: plannerCard ?? this.plannerCard,
    );
  }
}

//下のenum内のRoleによってメッセージの表示場所を分割している
enum MessageRole {
  user,
  assistant,
}

