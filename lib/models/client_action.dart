// lib/models/client_action.dart
//
// ライム（サーバー）がアプリに頼む操作。
//
// サーバーの LLM がツール（start_station_alarm など）を使うと、
// client_action メッセージが届く。実際の動作はアプリが行い、
// ライムの返事（「新宿で起こすね」）は別に text_chunk で届く。
//
//   { "type": "client_action",
//     "action": "station_alarm.start",
//     "params": { "station": "新宿", "kana": "しんじゅく", "line": "中央線" } }

class ClientAction {
  const ClientAction({required this.action, this.params = const {}});

  /// 駅アラームを始める。
  /// params: station（駅名）, kana（よみがな、任意）, line（路線名、任意）
  static const String stationAlarmStart = 'station_alarm.start';

  /// 駅アラームを止める。
  static const String stationAlarmStop = 'station_alarm.stop';

  final String action;
  final Map<String, dynamic> params;

  /// params の文字列を読む。無い・空・型違いは null。
  String? param(String key) {
    final value = params[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  String toString() => 'ClientAction($action)';
}
