// アプリを開いたときに、ライムから一言話しかける。
//
// 利用者の吹き出しは出さず、ライムの返事だけを出す。同じログインの間は1回だけ。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/services/llm_service.dart';

import 'review/support/fakes.dart';

/// 話しかけに対応した偽の会話サービス。
class GreetingLlm extends ScriptedLlm implements GreetingService {
  GreetingLlm(this.greeting) : super(const []);

  final List<Map<String, dynamic>> greeting;
  int greetings = 0;
  String? lastThreadId;

  @override
  Stream<LLMResponse> sendGreeting({String? threadId}) async* {
    greetings++;
    lastThreadId = threadId;
    for (final json in greeting) {
      await Future<void>.delayed(Duration.zero);
      yield LLMResponse.fromJson(json);
    }
  }
}

void main() {
  const reply = [
    {'type': 'text_chunk', 'text': 'おはよ、ご主人様。'},
    {'type': 'chat_end', 'full_text': 'おはよ、ご主人様。', 'emotion': 'happy'},
  ];

  test('ライムの返事だけを出し、利用者の吹き出しは出さない', () async {
    final llm = GreetingLlm(reply);
    final chat = ChatProvider(
      llm,
      FakeUnity(),
      audioQueue: FakeAudioQueue(),
      greetOnLaunchEnabled: () => true,
    );
    addTearDown(chat.dispose);

    await chat.greetOnLaunch();

    expect(llm.greetings, 1);
    expect(chat.messages, hasLength(1));
    expect(chat.messages.single.role, MessageRole.assistant);
    expect(chat.messages.single.text, contains('おはよ'));
    expect(chat.isLoading, isFalse);
  });

  test('同じログインの間は1回だけ話しかける', () async {
    final llm = GreetingLlm(reply);
    final chat = ChatProvider(
      llm,
      FakeUnity(),
      audioQueue: FakeAudioQueue(),
      greetOnLaunchEnabled: () => true,
    );
    addTearDown(chat.dispose);

    await chat.greetOnLaunch();
    // つなぎ直したときにも呼ばれる
    await chat.greetOnLaunch();
    expect(llm.greetings, 1);

    // ログインし直したら、また話しかける
    chat.resetForSignOut();
    await chat.greetOnLaunch();
    expect(llm.greetings, 2);
  });

  test('設定で切っているときは話しかけない', () async {
    final llm = GreetingLlm(reply);
    final chat = ChatProvider(
      llm,
      FakeUnity(),
      audioQueue: FakeAudioQueue(),
      greetOnLaunchEnabled: () => false,
    );
    addTearDown(chat.dispose);

    await chat.greetOnLaunch();

    expect(llm.greetings, 0);
    expect(chat.messages, isEmpty);
  });

  test('返事が最後まで届かなくても、エラーの吹き出しは出さない', () async {
    final llm = GreetingLlm(const [
      {'type': 'text_chunk', 'text': 'おは'},
    ]);
    final unity = FakeUnity();
    final chat = ChatProvider(
      llm,
      unity,
      audioQueue: FakeAudioQueue(),
      greetOnLaunchEnabled: () => true,
    );
    addTearDown(chat.dispose);

    await chat.greetOnLaunch();

    // 利用者は何も頼んでいないので、途中の文を消すだけにする
    expect(chat.messages, isEmpty);
    expect(unity.errors, isEmpty);
    expect(chat.isLoading, isFalse);
  });

  test('サーバーに断られても、エラーの吹き出しは出さない', () async {
    // 話しかけを知らない古いサーバーは、本文が無いので入力不正で断る
    final llm = GreetingLlm(const [
      {'type': 'error', 'code': 'INVALID_INPUT', 'message': 'text or images is required'},
    ]);
    final unity = FakeUnity();
    final chat = ChatProvider(
      llm,
      unity,
      audioQueue: FakeAudioQueue(),
      greetOnLaunchEnabled: () => true,
    );
    addTearDown(chat.dispose);

    await chat.greetOnLaunch();

    expect(chat.messages, isEmpty);
    expect(unity.errors, isEmpty);
    expect(chat.isLoading, isFalse);
  });

  test('話しかけに対応していないサービスでは何もしない', () async {
    final chat = ChatProvider(
      ScriptedLlm(const []),
      FakeUnity(),
      audioQueue: FakeAudioQueue(),
      greetOnLaunchEnabled: () => true,
    );
    addTearDown(chat.dispose);

    await chat.greetOnLaunch();

    expect(chat.messages, isEmpty);
  });
}
