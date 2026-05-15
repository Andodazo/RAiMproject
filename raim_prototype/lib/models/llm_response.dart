class LLMResponse {
  final String text;
  final String emotion;
  final double intensity;
  
  LLMResponse({
    required this.text,
    required this.emotion,
    required this.intensity,
  });
  
  // JSON文字列をLLMResponseオブジェクトに変換する
  factory LLMResponse.fromJson(Map<String, dynamic> json) {
    return LLMResponse(
      text: json['text'] as String,
      emotion: json['emotion'] as String,
      intensity: (json['intensity'] as num).toDouble(),
    );
  }
}