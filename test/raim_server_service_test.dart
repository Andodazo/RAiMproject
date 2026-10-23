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
          socket.add(jsonEncode(reply));
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
}
