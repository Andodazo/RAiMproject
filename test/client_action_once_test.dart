// 同じ client_action は1回だけ実行する（R-05）。
//
// サーバーの再試行で、同じ操作（駅アラームを始める など）がもう一度届くことがある。

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/providers/chat_provider.dart';

import 'review/support/fakes.dart';

void main() {
  Map<String, dynamic> action(String? actionId) => {
        'type': 'client_action',
        'action': 'station_alarm.start',
        'actionId': ?actionId,
        'params': {'station': '新宿'},
      };

  test('同じ actionId は、送り直しても1回だけ流す', () async {
    final chat = ChatProvider(
      ScriptedLlm.sequence([
        [action('req-1_action_0'), action('req-1_action_0'), {'type': 'chat_end'}],
        [action('req-1_action_0'), {'type': 'chat_end'}],
      ]),
      FakeUnity(),
      audioQueue: FakeAudioQueue(),
    );
    addTearDown(chat.dispose);
    final seen = <String>[];
    chat.clientActions.listen((a) => seen.add(a.action));

    await chat.sendUserMessage('新宿で起こして');
    await chat.sendUserMessage('新宿で起こして');
    await Future<void>.delayed(Duration.zero);

    expect(seen, ['station_alarm.start']);
  });

  test('ID が違えば別の操作として流す。ID の無い古いサーバーの分も流す', () async {
    final chat = ChatProvider(
      ScriptedLlm([
        action('req-1_action_0'),
        action('req-1_action_1'),
        action(null),
        {'type': 'chat_end'},
      ]),
      FakeUnity(),
      audioQueue: FakeAudioQueue(),
    );
    addTearDown(chat.dispose);
    final seen = <String>[];
    chat.clientActions.listen((a) => seen.add(a.action));

    await chat.sendUserMessage('新宿で起こして');
    await Future<void>.delayed(Duration.zero);

    expect(seen, hasLength(3));
  });
}
