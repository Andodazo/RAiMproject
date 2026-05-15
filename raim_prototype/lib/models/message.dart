class Message {
  final String text;
  final MessageRole role;
  final DateTime timestamp;
  final String? emotion;
  final double? intensity;
  
  Message({
    required this.text,
    required this.role,
    required this.timestamp,
    this.emotion,
    this.intensity,
  });
}

enum MessageRole {
  user,
  assistant,
}