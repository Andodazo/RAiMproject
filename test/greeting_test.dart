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
  GreetingLlm(this.greeting, {List<Map<String, dynamic>> chat = const []})
      : super(chat);

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
    {'type': 'text_chunk', 'text': 'おはよ。'},
    {'type': 'chat_end', 'full_text': 'おはよ。', 'emotion': 'happy'},
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

  // 2026-11-13: 開いてすぐ送ったあと、返事が遅くてつなぎ直したときに、会話の途中で話しかけていた
  test('返事の途中で話しかけの番が来たら、そのあとつなぎ直しても話しかけない', () async {
    final llm = GreetingLlm(reply, chat: const [
      {'type': 'text_chunk', 'text': '3分ね'},
      {'type': 'chat_end', 'full_text': '3分ね'},
    ]);
    final chat = ChatProvider(
      llm,
      FakeUnity(),
      audioQueue: FakeAudioQueue(),
      greetOnLaunchEnabled: () => true,
    );
    addTearDown(chat.dispose);

    // 開いてすぐ送り、返事の途中で話しかけの番が来る
    final sending = chat.sendUserMessage('3分計って');
    await chat.greetOnLaunch();
    await sending;
    // 返事が遅くてつなぎ直したときにも呼ばれる
    await chat.greetOnLaunch();
    expect(llm.greetings, 0);
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
    // 途中まで出た吹き出しは閉じる（以前は消えずに残っていた）
    expect(unity.chatEnds, 1);
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

  group('毎回は話しかけない', () {
    const chatReply = [
      {'type': 'text_chunk', 'text': 'うん。'},
      {'type': 'chat_end', 'full_text': 'うん。', 'emotion': 'neutral'},
    ];

    /// 少し前に話した会話を開いている状態を作る。
    Future<(GreetingLlm, ChatProvider)> afterChat({
      required Duration elapsed,
      required double dice,
    }) async {
      final llm = GreetingLlm(reply, chat: chatReply);
      final chat = ChatProvider(
        llm,
        FakeUnity(),
        audioQueue: FakeAudioQueue(),
        greetOnLaunchEnabled: () => true,
        greetDice: () => dice,
        clock: () => DateTime.now().add(elapsed),
      );
      addTearDown(chat.dispose);
      await chat.sendUserMessage('ただいま');
      return (llm, chat);
    }

    test('前回から間が空いていたら、くじに関係なく話しかける', () async {
      final (llm, chat) = await afterChat(
        elapsed: ChatProvider.greetAlwaysAfter + const Duration(minutes: 1),
        dice: 0.99,
      );
      await chat.greetOnLaunch();
      expect(llm.greetings, 1);
    });

    test('間が空いていないときは、くじに当たったら話しかける', () async {
      final (llm, chat) = await afterChat(
        elapsed: const Duration(minutes: 30),
        dice: ChatProvider.greetChance - 0.01,
      );
      await chat.greetOnLaunch();
      expect(llm.greetings, 1);
    });

    test('くじに外れたら話しかけず、つなぎ直しても引き直さない', () async {
      final (llm, chat) = await afterChat(
        elapsed: const Duration(minutes: 30),
        dice: ChatProvider.greetChance,
      );
      final before = chat.messages.length;
      await chat.greetOnLaunch();
      await chat.greetOnLaunch();
      expect(llm.greetings, 0);
      expect(chat.messages, hasLength(before));
      expect(chat.isLoading, isFalse);
    });

    test('会話が無いとき（初めて）は、くじに関係なく話しかける', () async {
      final llm = GreetingLlm(reply);
      final chat = ChatProvider(
        llm,
        FakeUnity(),
        audioQueue: FakeAudioQueue(),
        greetOnLaunchEnabled: () => true,
        greetDice: () => 0.99,
      );
      addTearDown(chat.dispose);
      await chat.greetOnLaunch();
      expect(llm.greetings, 1);
    });
  });

  group('返事の途中で会話を変えたとき、Windows の吹き出しを閉じる', () {
    /// 本文を1つ送ったあと、テストが閉じるまで続きを送らない話しかけ
    Future<(FakeUnity, ChatProvider, StreamController<LLMResponse>)>
        midGreeting() async {
      final replies = StreamController<LLMResponse>();
      final llm = _GatedGreetingLlm(replies.stream);
      final unity = FakeUnity();
      final chat = ChatProvider(
        llm,
        unity,
        audioQueue: FakeAudioQueue(),
        greetOnLaunchEnabled: () => true,
      );
      addTearDown(chat.dispose);
      addTearDown(replies.close);

      unawaited(chat.greetOnLaunch());
      replies.add(LLMResponse.fromJson(const {
        'type': 'text_chunk',
        'chunk_id': 'c1',
        'text': 'おはよ。',
      }));
      await pumpEventQueue();
      expect(chat.isLoading, isTrue);
      expect(unity.chatEnds, 0);
      return (unity, chat, replies);
    }

    test('新しい会話にしたら chat_end を送る', () async {
      final (unity, chat, _) = await midGreeting();
      chat.startNewThread();
      // 以前は考え中の点のときしか送らず、文が出たあとだと吹き出しが残っていた
      expect(unity.chatEnds, 1);
    });

    test('ログアウトしたら chat_end を送る', () async {
      final (unity, chat, _) = await midGreeting();
      chat.resetForSignOut();
      expect(unity.chatEnds, 1);
    });

    test('返事の途中でなければ、新しい会話にしても送らない', () async {
      final unity = FakeUnity();
      final chat = ChatProvider(
        GreetingLlm(reply),
        unity,
        audioQueue: FakeAudioQueue(),
      );
      addTearDown(chat.dispose);
      chat.startNewThread();
      expect(unity.chatEnds, 0);
    });
  });
}

/// 渡されたストリームをそのまま話しかけの返事にする偽の会話サービス
class _GatedGreetingLlm extends ScriptedLlm implements GreetingService {
  _GatedGreetingLlm(this.replies) : super(const []);

  final Stream<LLMResponse> replies;

  @override
  Stream<LLMResponse> sendGreeting({String? threadId}) => replies;
}
