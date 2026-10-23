// 課題3: 古いメッセージを読み込んでいる途中で会話を切り替えると、
//        前の会話の履歴が今の会話の先頭に入る
//
//   flutter test test/review/item3_older_history_test.dart

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/conversation_thread.dart';
import 'package:raim_prototype/providers/chat_provider.dart';

import 'support/fakes.dart';

void main() {
  late FakeRaimServer server;
  late ChatProvider chat;
  late Completer<ThreadHistory?> olderOfA;

  setUp(() {
    server = FakeRaimServer();
    olderOfA = Completer<ThreadHistory?>();
    server.onThreadHistory = (id, before) {
      if (id == 'thread-A' && before == null) {
        // A の新しい方。さらに古い分がある
        return Future.value(
          history('thread-A', ['A-3', 'A-4'], startIndex: 2, hasMore: true),
        );
      }
      if (id == 'thread-A') return olderOfA.future; // A の古い方は止めておく
      if (id == 'thread-B') {
        return Future.value(history('thread-B', ['B-1', 'B-2']));
      }
      return Future.value(null);
    };
    chat = ChatProvider(server, FakeUnity(), audioQueue: FakeAudioQueue());
  });

  tearDown(() => chat.dispose());

  test('読み込み中に別の会話へ切り替えたら、前の会話の古いメッセージを入れない', () async {
    await chat.switchThread('thread-A');
    expect(chat.messages.map((m) => m.text), ['A-3', 'A-4'], reason: '前提: A が出ている');

    // A の古い方を読み始める（返事待ち）
    final loading = chat.loadOlderMessages();
    await settle();

    // その間に B へ切り替える
    await chat.switchThread('thread-B');

    // A の古い方が今ごろ届く
    olderOfA.complete(history('thread-A', ['A-1', 'A-2'], startIndex: 0));
    await loading;

    expect(chat.currentThreadId, 'thread-B');
    expect(
      chat.messages.map((m) => m.text),
      ['B-1', 'B-2'],
      reason: 'B の画面に A の古いメッセージが入った',
    );
  });

  test('切り替えなければ、古いメッセージは今までどおり先頭に入る', () async {
    await chat.switchThread('thread-A');

    final loading = chat.loadOlderMessages();
    await settle();
    olderOfA.complete(history('thread-A', ['A-1', 'A-2'], startIndex: 0));
    await loading;

    expect(chat.messages.map((m) => m.text), ['A-1', 'A-2', 'A-3', 'A-4']);
  });
}
