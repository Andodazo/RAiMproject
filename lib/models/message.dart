//全体Messageの定義
//Messageの型定義
class Message {
  final String text;
  final MessageRole role;
  final DateTime timestamp;
  final String? emotion;
  final double? intensity;
//Messageの戻り値
  Message({
    required this.text,
    required this.role,
    required this.timestamp,
    this.emotion,
    this.intensity,
  });
}

//下のenum内のRoleによってメッセージの表示場所を分割している
enum MessageRole {
  user,
  assistant,
}