// レビュー課題のテストで使う偽物。
//
// 本物は通信したり音を鳴らしたりするので、テストでは代わりにこれを渡す。
// 使っていないメソッドは noSuchMethod で受け流す（呼ばれたら例外になる）。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:raim_prototype/models/conversation_thread.dart';
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/services/audio_play_queue.dart';
import 'package:raim_prototype/services/llm_service.dart';
import 'package:raim_prototype/services/raim_server_service.dart';
import 'package:raim_prototype/services/unity_communicator.dart';

/// 音を鳴らさない音声キュー。reset された回数だけ数える。
class FakeAudioQueue implements AudioPlayQueue {
  int resetCount = 0;

  @override
  final ValueNotifier<bool> playing = ValueNotifier<bool>(false);

  @override
  Future<void> reset() async {
    resetCount++;
  }

  @override
  void stopAfterCurrent() {}

  @override
  void Function(String? tag)? onItemStarted;

  @override
  void Function(String? tag)? onItemFinished;

  @override
  void enqueueBytes({
    required Uint8List bytes,
    String format = 'wav',
    String? tag,
  }) {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Unity の代わり。sendError で送られた文を覚えておく。
class FakeUnity implements UnityCommunicator {
  final List<String> errors = [];

  // @override は付けない。課題4に取りかかる前は UnityCommunicator に sendError が無く、
  // 付けると「上書きしていないのに @override」という警告になるため。
  // ignore: annotate_overrides
  void sendError({required String message}) {
    errors.add(message);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    // void のメソッド（sendEmotions など）は何もしない
    return null;
  }
}

/// 決めた順に返事を流す会話サービス。
///
/// [ScriptedLlm.new] は毎回同じ返事、[ScriptedLlm.sequence] は送るたびに次の返事を流す。
class ScriptedLlm implements LLMService {
  ScriptedLlm(List<Map<String, dynamic>> script) : _scripts = [script];

  ScriptedLlm.sequence(List<List<Map<String, dynamic>>> scripts)
      : _scripts = scripts;

  final List<List<Map<String, dynamic>>> _scripts;
  int calls = 0;

  @override
  Stream<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
    List<Map<String, dynamic>>? images,
    String? requestId,
    String? threadId,
  }) async* {
    final script = _scripts[calls < _scripts.length ? calls : _scripts.length - 1];
    calls++;
    for (final json in script) {
      await Future<void>.delayed(Duration.zero);
      yield LLMResponse.fromJson(json);
    }
  }
}

/// RaimServerService の代わり（一覧・履歴だけ）。
///
/// ChatProvider は `is RaimServerService` で一覧・履歴を使うか決めるので、
/// implements で同じ型にしておく。
class FakeRaimServer implements RaimServerService {
  /// 一覧を返す処理。テストごとに差し替える
  Future<List<ThreadSummary>> Function() onThreadList =
      () async => const <ThreadSummary>[];

  /// 履歴を返す処理。テストごとに差し替える
  Future<ThreadHistory?> Function(String threadId, int? beforeIndex)
      onThreadHistory = (threadId, beforeIndex) async => null;

  /// 会話の返事
  List<Map<String, dynamic>> script = const [];

  final StreamController<RaimConnectionState> _states =
      StreamController<RaimConnectionState>.broadcast();

  @override
  RaimConnectionState get state => RaimConnectionState.connected;

  @override
  Stream<RaimConnectionState> get stateStream => _states.stream;

  @override
  Future<List<ThreadSummary>> fetchThreadList() => onThreadList();

  @override
  Future<ThreadHistory?> fetchThreadHistory(
    String threadId, {
    int? beforeIndex,
  }) =>
      onThreadHistory(threadId, beforeIndex);

  @override
  Stream<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
    List<Map<String, dynamic>>? images,
    String? requestId,
    String? threadId,
  }) =>
      ScriptedLlm(script).sendMessage(userInput);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 待っている非同期の処理を先に進める（Completer で止めたところまで）
Future<void> settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 履歴を作る
ThreadHistory history(
  String threadId,
  List<String> texts, {
  int startIndex = 0,
  bool hasMore = false,
}) {
  return ThreadHistory(
    threadId: threadId,
    title: threadId,
    messages: [
      for (var i = 0; i < texts.length; i++)
        ThreadMessage(
          role: i.isEven ? 'user' : 'assistant',
          text: texts[i],
          createdAt: '2026-10-01T00:00:0${i % 10}Z',
        ),
    ],
    startIndex: startIndex,
    hasMore: hasMore,
    totalMessages: startIndex + texts.length,
  );
}

/// 一覧の1件を作る
ThreadSummary thread(String id) => ThreadSummary(
      threadId: id,
      title: id,
      updatedAt: '2026-10-01T00:00:00Z',
      turnCount: 1,
    );
