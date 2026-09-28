import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:raim_prototype/services/aws/aws_sigv4.dart';
import 'package:raim_prototype/services/aws/cognito_credentials_provider.dart';

/// Cognito への問い合わせ回数を数えながら、使い回しの動きを確かめる。
void main() {
  late int calls;
  late DateTime now;

  CognitoCredentialsProvider build({int status = 200}) {
    final client = MockClient((request) async {
      calls++;
      final target = request.headers['X-Amz-Target'];
      if (status != 200) return http.Response('{}', status);
      if (target == 'AWSCognitoIdentityService.GetId') {
        return http.Response(jsonEncode({'IdentityId': 'ap-northeast-1:abc'}), 200);
      }
      // 失効は now の1時間後（UNIX 秒）
      final exp = now.add(const Duration(hours: 1)).millisecondsSinceEpoch / 1000;
      return http.Response(
        jsonEncode({
          'IdentityId': 'ap-northeast-1:abc',
          'Credentials': {
            'AccessKeyId': 'ASIA$calls',
            'SecretKey': 'secret',
            'SessionToken': 'token',
            'Expiration': exp,
          },
        }),
        200,
      );
    });
    return CognitoCredentialsProvider(httpClient: client, clock: () => now);
  }

  setUp(() {
    calls = 0;
    now = DateTime.utc(2026, 9, 28, 12);
  });

  test('失効の5分前までは同じものを使い回す', () async {
    final p = build();
    final a = await p.getCredentials('id-token');
    now = now.add(const Duration(minutes: 50));
    final b = await p.getCredentials('id-token');
    expect(identical(a, b), isTrue);
    expect(calls, 2); // GetId + GetCredentialsForIdentity の1回分
  });

  test('失効が近づいたら取り直す', () async {
    final p = build();
    final a = await p.getCredentials('id-token');
    now = now.add(const Duration(minutes: 56));
    final b = await p.getCredentials('id-token');
    expect(identical(a, b), isFalse);
    expect(calls, 4);
  });

  test('失効時刻を UNIX 秒から読み取る', () async {
    final p = build();
    final c = await p.getCredentials('id-token');
    expect(c.expiration, DateTime.utc(2026, 9, 28, 13));
  });

  test('同時に呼ばれても問い合わせは1回', () async {
    final p = build();
    final results = await Future.wait([
      p.getCredentials('id-token'),
      p.getCredentials('id-token'),
      p.getCredentials('id-token'),
    ]);
    expect(identical(results[0], results[2]), isTrue);
    expect(calls, 2);
  });

  test('ID トークンが変わったら取り直す', () async {
    final p = build();
    await p.getCredentials('user-a');
    await p.getCredentials('user-b');
    expect(calls, 4);
  });

  test('clear の後は取り直す', () async {
    final p = build();
    await p.getCredentials('id-token');
    p.clear();
    await p.getCredentials('id-token');
    expect(calls, 4);
  });

  test('空の ID トークンは問い合わせずにエラー', () async {
    final p = build();
    await expectLater(p.getCredentials(' '), throwsFormatException);
    expect(calls, 0);
  });

  test('失敗した後は次の呼び出しで再挑戦できる', () async {
    var fail = true;
    final client = MockClient((request) async {
      calls++;
      if (fail) return http.Response('{}', 400);
      final target = request.headers['X-Amz-Target'];
      if (target == 'AWSCognitoIdentityService.GetId') {
        return http.Response(jsonEncode({'IdentityId': 'x'}), 200);
      }
      return http.Response(
        jsonEncode({
          'Credentials': {
            'AccessKeyId': 'a',
            'SecretKey': 's',
            'SessionToken': 't',
          },
        }),
        200,
      );
    });
    final p = CognitoCredentialsProvider(httpClient: client, clock: () => now);
    await expectLater(p.getCredentials('id-token'), throwsException);
    fail = false;
    final c = await p.getCredentials('id-token');
    expect(c.accessKeyId, 'a');
  });

  test('取得中に別の ID トークンで呼ばれたら、そちらは別に取りに行く', () async {
    final p = build();
    final a = p.getCredentials('user-a');
    final b = p.getCredentials('user-b');
    final results = await Future.wait([a, b]);
    expect(identical(results[0], results[1]), isFalse);
    expect(calls, 4);
  });

  test('取得中に clear されたら、届いた認証情報をキャッシュしない', () async {
    final p = build();
    final pending = p.getCredentials('id-token');
    p.clear();
    await pending;
    await p.getCredentials('id-token');
    expect(calls, 4);
  });

  test('Cognito の応答の Date ヘッダで時計のずれを補正する', () async {
    addTearDown(AwsClock.reset);
    final client = MockClient((request) async {
      final target = request.headers['X-Amz-Target'];
      // 端末より1時間進んだ時刻を返す
      final date = HttpDate.format(
        DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      if (target == 'AWSCognitoIdentityService.GetId') {
        return http.Response(
          jsonEncode({'IdentityId': 'x'}),
          200,
          headers: {'date': date},
        );
      }
      return http.Response(
        jsonEncode({
          'Credentials': {
            'AccessKeyId': 'a',
            'SecretKey': 's',
            'SessionToken': 't',
          },
        }),
        200,
        headers: {'date': date},
      );
    });
    final p = CognitoCredentialsProvider(httpClient: client, clock: () => now);
    await p.getCredentials('id-token');
    expect(
      AwsClock.offset.inMinutes,
      inInclusiveRange(59, 60),
    );
  });
}
