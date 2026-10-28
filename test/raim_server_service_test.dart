// RaimServerService のアクセストークンの期限まわりのテスト。
//
// サーバーは、接続したときのトークンの期限が切れると TOKEN_EXPIRED を返して切断する。
// 手元に小さな WebSocket サーバーを立てて、つなぎ直して送り直すかを確かめる。
// （ws:// の接続先なのでトークンは付かない。送り直しの流れだけを見る）

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/services/raim_server_service.dart';

/// テスト用の JWT（署名は見ないので中身だけ）
String _jwt(Map<String, dynamic> payload) {
  String part(Map<String, dynamic> map) =>
      base64Url.encode(utf8.encode(jsonEncode(map))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part(payload)}.sig';
}

/// 届いた要求ごとに、何を返すかを決められる WebSocket サーバー。
class _FakeEdge {
  late HttpServer _server;

  /// これまでに張られた接続の数
  int connections = 0;

  /// 届いた要求（接続の番号と中身）
  final received = <(int, Map<String, dynamic>)>[];

  /// 接続の番号と要求を受け取り、返すメッセージを返す。
  /// 返したあと接続を切るなら close を true にする。
  late ({List<Map<String, dynamic>> replies, bool close}) Function(
      int connection, Map<String, dynamic> request) onRequest;

  String get url => 'ws://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      final connection = ++connections;
      socket.listen((raw) async {
        final body = jsonDecode(raw as String) as Map<String, dynamic>;
        received.add((connection, body));
        final result = onRequest(connection, body);
        for (final reply in result.replies) {
          // 本物のサーバーと同じく、要求の requestId を付けて返す
          // （テストで別の ID を返したいときは reply 側に書く）
          socket.add(jsonEncode({'requestId': body['requestId'], ...reply}));
        }
        if (result.close) await socket.close();
      });
    });
  }

  Future<void> stop() => _server.close(force: true);
}

const _expired = {
  'type': 'error',
  'code': 'TOKEN_EXPIRED',
  'message': 'Access token has expired. Please reconnect.',
};

void main() {
  group('トークンの期限を読む', () {
    test('JWT の exp を読める', () {
      final token = _jwt({'sub': 'u1', 'exp': 1700000000});
      expect(
        RaimServerService.tokenExpiry(token),
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
    });

    test('JWT でなければ null', () {
      expect(RaimServerService.tokenExpiry('abc'), isNull);
      expect(RaimServerService.tokenExpiry('a.b.c'), isNull);
      expect(RaimServerService.tokenExpiry(_jwt({'sub': 'u1'})), isNull);
    });

    test('期限の3分前につなぎ直す', () {
      final now = DateTime(2026, 10, 23, 12);
      expect(
        RaimServerService.tokenRefreshDelay(
          now.add(const Duration(minutes: 60)),
          now: now,
        ),
        const Duration(minutes: 57),
      );
    });

    test('もう3分を切っていたら予約しない（つなぎ直しを繰り返さない）', () {
      final now = DateTime(2026, 10, 23, 12);
      expect(
        RaimServerService.tokenRefreshDelay(
          now.add(const Duration(minutes: 2)),
          now: now,
        ),
        isNull,
      );
    });

    test('TOKEN_EXPIRED のエラーだけを期限切れとみなす', () {
      expect(
        RaimServerService.isTokenExpiredError(LLMResponse.fromJson(_expired)),
        isTrue,
      );
      expect(
        RaimServerService.isTokenExpiredError(LLMResponse.fromJson(
            {'type': 'error', 'code': 'INTERNAL_ERROR', 'message': 'x'})),
        isFalse,
      );
    });
  });

  group('TOKEN_EXPIRED で切られたとき', () {
    late _FakeEdge edge;
    late RaimServerService service;

    setUp(() async {
      edge = _FakeEdge();
      await edge.start();
      service = RaimServerService(
        serverUrl: edge.url,
        requestTimeout: const Duration(seconds: 5),
      );
      await service.connect();
    });

    tearDown(() async {
      await service.dispose();
      await edge.stop();
    });

    test('つなぎ直して同じ文を送り直し、エラーを出さずに返事を受け取る', () async {
      edge.onRequest = (connection, request) => connection == 1
          ? (replies: [_expired], close: true)
          : (
              replies: [
                {'type': 'text_chunk', 'text': 'おはよう'},
                {'type': 'chat_end'},
              ],
              close: false,
            );

      final responses = await service.sendMessage('おはよう').toList();

      expect(responses.map((r) => r.type), ['text_chunk', 'chat_end']);
      expect(edge.connections, 2);
      expect(edge.received.map((r) => r.$1), [1, 2]);
      expect(edge.received.map((r) => r.$2['text']), ['おはよう', 'おはよう']);
    });

    test('送り直しても断られたら、エラーを渡して終わる（繰り返さない）', () async {
      edge.onRequest =
          (connection, request) => (replies: [_expired], close: true);

      final responses = await service.sendMessage('おはよう').toList();

      expect(responses, hasLength(1));
      expect(RaimServerService.isTokenExpiredError(responses.single), isTrue);
      expect(edge.received, hasLength(2));
    });

    test('スレッド一覧も、つなぎ直して取り直す', () async {
      edge.onRequest = (connection, request) => connection == 1
          ? (replies: [_expired], close: true)
          : (
              replies: [
                {
                  'type': 'thread_list',
                  'threads': [
                    {'threadId': 't1', 'title': '天気の話'},
                  ],
                },
              ],
              close: false,
            );

      final threads = await service.fetchThreadList();

      expect(threads.map((t) => t.threadId), ['t1']);
      expect(edge.connections, 2);
    });
  });

  group('別の要求への応答を受け取らない（X-03）', () {
    late _FakeEdge edge;
    late RaimServerService service;

    setUp(() async {
      edge = _FakeEdge();
      await edge.start();
      service = RaimServerService(
        serverUrl: edge.url,
        requestTimeout: const Duration(seconds: 5),
      );
      await service.connect();
    });

    tearDown(() async {
      await service.dispose();
      await edge.stop();
    });

    test('画像が無くても requestId を付けて送る', () async {
      edge.onRequest = (connection, request) => (
            replies: [
              {'type': 'chat_end'},
            ],
            close: false,
          );

      await service.sendMessage('やあ').toList();

      final requestId = edge.received.single.$2['requestId'] as String;
      expect(RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(requestId), isTrue);
    });

    test('話しかけは type: greeting で送り、本文も画像も付けない', () async {
      edge.onRequest = (connection, request) => (
            replies: [
              {'type': 'text_chunk', 'text': 'おはよ'},
              {'type': 'chat_end'},
            ],
            close: false,
          );

      final replies = await service.sendGreeting(threadId: 'thread-1').toList();

      final sent = edge.received.single.$2;
      expect(sent['type'], 'greeting');
      expect(sent['text'], isEmpty);
      expect(sent.containsKey('images'), isFalse);
      expect(sent['threadId'], 'thread-1');
      expect(replies.map((r) => r.type), ['text_chunk', 'chat_end']);
    });

    test('別の requestId の返事は読み飛ばし、自分の返事だけを受け取る', () async {
      edge.onRequest = (connection, request) => (
            replies: [
              {'type': 'text_chunk', 'text': '別の会話', 'requestId': 'other'},
              {'type': 'chat_end', 'requestId': 'other'},
              {'type': 'text_chunk', 'text': '自分の返事'},
              {'type': 'chat_end'},
            ],
            close: false,
          );

      final responses = await service.sendMessage('やあ').toList();

      expect(responses.map((r) => r.text).where((t) => t.isNotEmpty),
          ['自分の返事']);
    });

    test('サーバーがやり直した回の分は表示しない（最初に見た回だけ）', () async {
      edge.onRequest = (connection, request) => (
            replies: [
              {'type': 'text_chunk', 'text': 'こんに', 'attempt': 1},
              {'type': 'text_chunk', 'text': 'こんにちは', 'attempt': 2},
              {'type': 'chat_end', 'attempt': 2},
              {'type': 'text_chunk', 'text': 'ちは', 'attempt': 1},
              {'type': 'chat_end', 'attempt': 1},
            ],
            close: false,
          );

      final responses = await service.sendMessage('やあ').toList();

      expect(responses.map((r) => r.attempt), [1, 1, 1]);
      expect(responses.where((r) => r.isTextChunk).map((r) => r.text),
          ['こんに', 'ちは']);
    });

    test('履歴は、頼んだスレッドの分だけを受け取る', () async {
      edge.onRequest = (connection, request) => (
            replies: [
              {'type': 'thread_history', 'threadId': 't-other', 'messages': []},
              {
                'type': 'thread_history',
                'threadId': 't1',
                'messages': [
                  {'role': 'user', 'text': 'やあ', 'createdAt': 'x'},
                ],
              },
            ],
            close: false,
          );

      final history = await service.fetchThreadHistory('t1');

      expect(history?.threadId, 't1');
    });

    test('自分の要求へのエラーなら、待たずに失敗にする', () async {
      edge.onRequest = (connection, request) => (
            replies: [
              {'type': 'error', 'code': 'THREAD_NOT_FOUND', 'message': 'x'},
            ],
            close: false,
          );

      await expectLater(
        service.fetchThreadHistory('t1'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
