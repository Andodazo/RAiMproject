// 消した会話への送信（R-02）。
//
// サーバーは消したスレッドを作り直さずに THREAD_DELETED を返す。

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/providers/chat_provider.dart';

import 'review/support/fakes.dart';

void main() {
  test('THREAD_DELETED なら新しい会話の ID に切り替え、送った発言は残す', () async {
    final llm = ScriptedLlm([
      {
        'type': 'error',
        'code': 'THREAD_DELETED',
        'message': 'Conversation thread was deleted',
        'text': 'Conversation thread was deleted',
      },
    ]);
    final chat = ChatProvider(llm, FakeUnity(), audioQueue: FakeAudioQueue());
    addTearDown(chat.dispose);
    chat.startNewThread();
    final before = chat.currentThreadId;

    await chat.sendUserMessage('まだいる？');

    expect(chat.currentThreadId, isNotNull);
    expect(chat.currentThreadId, isNot(before));
    expect(chat.messages.first.text, 'まだいる？');
    expect(
      chat.messages.last.text,
      contains('新しい会話にしました'),
    );
    expect(chat.messages.last.role, MessageRole.assistant);
    expect(chat.isLoading, isFalse);
  });
}
