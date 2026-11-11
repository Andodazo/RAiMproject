// 前の話を探す（「この前話したお店なんだっけ」）: 見つけた会話を開くカード
//
//   flutter test test/past_talk_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/models/conversation_thread.dart';
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/models/planner_card.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/widgets/planner_card_view.dart';

import 'review/support/fakes.dart';

ThreadHistory _page(List<(String, String)> messages, {int startIndex = 0, bool hasMore = false}) => ThreadHistory(
      threadId: 'thread-cafe',
      title: '週末の話',
      messages: [
        for (var i = 0; i < messages.length; i++)
          ThreadMessage(role: i.isEven ? 'user' : 'assistant', text: messages[i].$1, createdAt: messages[i].$2),
      ],
      startIndex: startIndex,
      hasMore: hasMore,
      totalMessages: startIndex + messages.length,
    );

void main() {
  test('history.found はカードになり、ラベルに日付とタイトルが出る', () {
    final talk = PastTalkRef.fromJson({
      'threadId': 'thread-cafe', 'at': '2026-11-03T01:05:00.000Z', 'title': '週末の話', 'date': '2026-11-03',
    })!;
    expect(talk.label, '11/3(火)の会話「週末の話」');
    expect(PastTalkRef.fromJson({'threadId': 'x', 'at': 'きのう'}), isNull);
    expect(PastTalkRef.fromJson({'at': '2026-11-03T01:05:00.000Z'}), isNull);
  });

  test('カードの「開く」で会話を開き、見つかるまで古い方を読み足して、その発言へ送る', () async {
    final server = FakeRaimServer();
    final requested = <int?>[];
    server.onThreadHistory = (id, before) async {
      requested.add(before);
      if (before == null) {
        return _page([('新しい話', '2026-11-05T00:00:00.000Z'), ('うん', '2026-11-05T00:00:00.000Z')], startIndex: 2, hasMore: true);
      }
      return _page([
        ('駅前のモカってカフェ、すごくよかった', '2026-11-03T01:05:00.000Z'),
        ('いいね', '2026-11-03T01:05:00.000Z'),
      ]);
    };
    server.script = [
      {
        'type': 'client_action', 'action': 'history.found', 'actionId': 'h1',
        'params': {'threadId': 'thread-cafe', 'at': '2026-11-03T01:05:00.000Z', 'title': '週末の話', 'date': '2026-11-03'},
      },
      {'type': 'chat_end', 'full_text': '11/3に話してたね、駅前のモカってカフェ'},
    ];
    final chat = ChatProvider(server, FakeUnity(), audioQueue: FakeAudioQueue());
    addTearDown(chat.dispose);

    await chat.sendUserMessage('この前話したカフェなんだっけ');
    await settle();
    final card = chat.messages.last.plannerCard!;
    expect(card.type, PlannerCardType.talk);
    expect(card.isActionable, isTrue);

    final opened = await chat.openPastTalk(card.talk!);
    expect(opened, isTrue);
    expect(chat.currentThreadId, 'thread-cafe');
    expect(requested, [null, 2]);
    expect(chat.messages[chat.focusIndex!].text, '駅前のモカってカフェ、すごくよかった');
    expect(chat.focusSerial, 1);
  });

  testWidgets('前の会話のカードに「開く」が出る', (tester) async {
    final chat = ChatProvider(FakeRaimServer(), FakeUnity(), audioQueue: FakeAudioQueue());
    addTearDown(chat.dispose);
    final card = PlannerCard.talk(const PastTalkRef(
      threadId: 'thread-cafe', at: '2026-11-03T01:05:00.000Z', title: '週末の話', date: '2026-11-03',
    ));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChangeNotifierProvider.value(value: chat, child: PlannerCardView(card: card)),
      ),
    ));
    expect(find.text('11/3(火)の会話「週末の話」'), findsOneWidget);
    expect(find.text('開く'), findsOneWidget);
  });

  test('LLMResponse の client_action から読める', () {
    final response = LLMResponse.fromJson({
      'type': 'client_action', 'action': 'history.found',
      'params': {'threadId': 't', 'at': '2026-11-03T01:05:00.000Z'},
    });
    expect(PastTalkRef.fromJson(response.actionParams)?.threadId, 't');
  });
}
