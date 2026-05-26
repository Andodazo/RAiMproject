// lib/models/llm_response.dart
//
// 変更点（v2）:
// - type フィールドを追加（"chat" / "filler_audio" を識別）
// - fromJson のフィールドアクセスを null安全に
// - サーバーが送ってくる version, code 等の追加フィールドは無視される（安全）

class LLMResponse {
  /// メッセージ種別: "chat" / "filler_audio" / "error" など
  /// 既存の OllamaService は type を持たないので、未設定なら "chat" として扱う
  final String type;
  final String text;
  final String emotion;
  final double intensity;

  LLMResponse({
    this.type = 'chat',
    required this.text,
    required this.emotion,
    required this.intensity,
  });

  /// JSON文字列をLLMResponseオブジェクトに変換する
  /// 未設定フィールドはデフォルト値にフォールバック（クラッシュ防止）
  factory LLMResponse.fromJson(Map<String, dynamic> json) {
    return LLMResponse(
      type: (json['type'] as String?) ?? 'chat',
      text: (json['text'] as String?) ?? '',
      emotion: (json['emotion'] as String?) ?? 'neutral',
      intensity: (json['intensity'] as num?)?.toDouble() ?? 0.5,
    );
  }

  /// 通常のチャット応答か（UIに吹き出し追加すべきか）
  bool get isChat => type == 'chat';

  /// つなぎ言葉か（音声だけ再生、UIには出さない）
  bool get isFillerAudio => type == 'filler_audio';
}