// 課題4: 返事を途中まで流したあとでエラーになると、途中の文が正しい返事のように残り、
//        声も鳴り続ける
//
//   flutter test test/review/item4_partial_reply_error_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/providers/chat_provider.dart';

import 'support/fakes.dart';

List<String> assistantTexts(ChatProvider chat) => chat.messages
    .where((m) => m.role == MessageRole.assistant)
    .map((m) => m.text)
    .toList();

void main() {
  late FakeUnity unity;
  late FakeAudioQueue audio;

  setUp(() {
    unity = FakeUnity();
    audio = FakeAudioQueue();
  });

  ChatProvider build(List<Map<String, dynamic>> script) {
    final chat = ChatProvider(ScriptedLlm(script), unity, audioQueue: audio);
    addTearDown(chat.dispose);
    return chat;
  }

  test('途中の文（吹き出しが分かれた前の分も）を消し、エラーだけを残す', () async {
    final chat = build([
      {'type': 'metadata', 'emotion': 'happy'},
      {'type': 'text_chunk', 'text': '前半の文。'},
      {'type': 'bubble_break'},
      {'type': 'text_chunk', 'text': '後半の文。'},
      {'type': 'error', 'text': 'うまく返事を作れませんでした'},
    ]);

    await chat.sendUserMessage('こんにちは');

    final texts = assistantTexts(chat);
    expect(texts.any((t) => t.contains('前半の文')), isFalse,
        reason: '吹き出しが分かれた前の分の途中の文が残っている');
    expect(texts.any((t) => t.contains('後半の文')), isFalse, reason: '途中の文が残っている');
    expect(texts, ['うまく返事を作れませんでした'], reason: 'エラーの知らせだけが残るはず');
    expect(chat.messages.first.text, 'こんにちは', reason: '送った発言まで消えている');
    expect(chat.isLoading, isFalse);
  });

  test('途中の文を消したら、声を止めて Unity に失敗を知らせる', () async {
    final chat = build([
      {'type': 'text_chunk', 'text': '前半の文。'},
      {'type': 'bubble_break'},
      {'type': 'error', 'text': 'うまく返事を作れませんでした'},
    ]);

    final resetsBefore = audio.resetCount;
    await chat.sendUserMessage('こんにちは');

    expect(audio.resetCount, greaterThan(resetsBefore), reason: '声を止めていない（音声キューを reset していない）');
    expect(unity.errors, isNotEmpty, reason: 'Unity（Windows の吹き出し）に失敗を知らせていない');
  });

  test('本文が来る前のエラーは、今までどおりエラーを出すだけ', () async {
    final chat = build([
      {'type': 'error', 'text': '接続を新しくしました'},
    ]);

    await chat.sendUserMessage('こんにちは');

    expect(assistantTexts(chat), contains('接続を新しくしました'));
    expect(chat.messages.first.text, 'こんにちは');
  });

  test('前の返事の文は、次の返事のエラーで消さない', () async {
    final chat = ChatProvider(
      ScriptedLlm.sequence([
        [
          {'type': 'text_chunk', 'text': '1回目の返事。'},
          {'type': 'chat_end'},
        ],
        [
          {'type': 'text_chunk', 'text': '2回目の途中。'},
          {'type': 'error', 'text': '失敗しました'},
        ],
      ]),
      unity,
      audioQueue: audio,
    );
    addTearDown(chat.dispose);

    await chat.sendUserMessage('1回目');
    await chat.sendUserMessage('2回目');

    expect(chat.messages.map((m) => m.text), ['1回目', '1回目の返事。', '2回目', '失敗しました'],
        reason: '消すのは失敗した返事の途中の文だけ');
  });
}
