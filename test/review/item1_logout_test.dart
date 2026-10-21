// 課題1: ログアウトしても、前の人の会話・会話 ID・一覧・選んだ画像が残る
//
//   flutter test test/review/item1_logout_test.dart

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/conversation_thread.dart';
import 'package:raim_prototype/providers/chat_provider.dart';

import 'support/fakes.dart';
import 'support/source.dart';

void main() {
  late FakeRaimServer server;
  late ChatProvider chat;

  setUp(() {
    server = FakeRaimServer();
    chat = ChatProvider(server, FakeUnity(), audioQueue: FakeAudioQueue());
  });

  tearDown(() => chat.dispose());

  test('resetForSignOut で会話・会話 ID・一覧・読み込み中の表示が消える', () async {
    server.onThreadList = () async => [thread('thread-A'), thread('thread-B')];
    server.onThreadHistory = (id, before) async => history(id, ['やあ', 'こんにちは']);

    await chat.loadThreads();
    await chat.switchThread('thread-A');
    expect(chat.messages, isNotEmpty, reason: '前提: A の会話が出ている');
    expect(chat.threads, isNotEmpty, reason: '前提: 一覧が出ている');

    chat.resetForSignOut();

    expect(chat.messages, isEmpty, reason: '前の人の会話が残っている');
    expect(chat.currentThreadId, isNull, reason: '前の人の会話 ID が残っている');
    expect(chat.threads, isEmpty, reason: '前の人の会話一覧が残っている');
    expect(chat.threadError, isNull);
    expect(chat.isLoading, isFalse);
    expect(chat.isLoadingThreads, isFalse);
  });

  test('ログアウト前に読み始めた一覧が、ログアウト後に届いても出さない', () async {
    final gate = Completer<List<ThreadSummary>>();
    server.onThreadList = () => gate.future;

    final loading = chat.loadThreads();
    await settle();

    chat.resetForSignOut();
    gate.complete([thread('前の人の会話')]);
    await loading;

    expect(chat.threads, isEmpty, reason: '前の人の一覧が次の人の画面に出た');
  });

  test('ログアウト前に読み始めた一覧が、ログアウト後に失敗しても失敗の表示を出さない', () async {
    final gate = Completer<List<ThreadSummary>>();
    server.onThreadList = () => gate.future;

    final loading = chat.loadThreads();
    await settle();

    chat.resetForSignOut();
    gate.completeError(Exception('時間切れ'));
    await loading;

    expect(chat.threadError, isNull, reason: '前の人の読み込み失敗が次の人の画面に出た');
  });

  test('Windows のログアウトで、会話を消して選んだ画像も消している', () {
    final source = readSource('lib/screens/windows_input_window.dart');
    final bodies = methodBodiesContaining(source, '.logout()');
    expect(bodies, isNotEmpty, reason: 'ログアウトする処理が見つからない');
    expect(
      bodies.any((b) => b.contains('resetForSignOut(') && b.contains('clearImage(')),
      isTrue,
      reason: 'ログアウトする処理の中で resetForSignOut() と clearImage() を呼んでいない',
    );
  });

  test('スマホでアプリを終了できなかったときも、会話と選んだ画像を消している', () {
    final source = readSource('lib/screens/chat_screen.dart');
    final bodies = methodBodiesContaining(source, 'notifyLogoutFallback(');
    expect(bodies, isNotEmpty, reason: 'notifyLogoutFallback を呼ぶ処理が見つからない');
    expect(
      bodies.any((b) => b.contains('resetForSignOut(') && b.contains('clearImage(')),
      isTrue,
      reason: '終了できなかったときの処理で resetForSignOut() と clearImage() を呼んでいない',
    );
  });
}
