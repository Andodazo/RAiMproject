import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/aws/aws_sigv4.dart';
import 'package:raim_prototype/services/aws/transcribe_presigner.dart';

/// AWS の署名が公式実装と同じ結果になることを確かめる。
///
/// 期待値は AWS のドキュメントに載っている例と、AWS 公式の Python
/// ライブラリ（botocore）で同じ入力から作った署名。
/// 1文字でもずれると AWS に 403 で弾かれ、原因の特定が難しいので、
/// 実際に接続する前にここで確かめる。
void main() {
  group('AwsSigV4.signingKey', () {
    test('AWS ドキュメントの例と一致する', () {
      final key = AwsSigV4.signingKey(
        secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
        date: '20120215',
        region: 'us-east-1',
        service: 'iam',
      );
      expect(
        key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d',
      );
    });
  });

  group('AwsSigV4.uriEncode', () {
    test('英数字と - . _ ~ はそのまま', () {
      expect(AwsSigV4.uriEncode('aZ09-._~'), 'aZ09-._~');
    });

    test('それ以外は大文字の16進でエンコードする', () {
      // Dart の Uri.encodeComponent は ! ( ) * をエンコードしないが、
      // AWS はエンコードを要求する
      expect(AwsSigV4.uriEncode('a b!()*'), 'a%20b%21%28%29%2A');
      expect(AwsSigV4.uriEncode('+/='), '%2B%2F%3D');
    });

    test('日本語は UTF-8 のバイトごとにエンコードする', () {
      expect(AwsSigV4.uriEncode('日'), '%E6%97%A5');
    });

    test('パスは / を残す', () {
      expect(AwsSigV4.uriEncodePath('a b/c'), 'a%20b/c');
    });
  });

  group('AwsSigV4.amzDate', () {
    test('UTC の基本形式で出す', () {
      expect(
        AwsSigV4.amzDate(DateTime.utc(2026, 9, 28, 1, 2, 3)),
        '20260928T010203Z',
      );
    });
  });

  test('空の本文のハッシュ', () {
    expect(
      AwsSigV4.emptyPayloadHash,
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });

  group('TranscribePresigner', () {
    // セッショントークンに + / = を含めているのは、
    // エンコード漏れがあると署名がずれるのを確かめるため
    const credentials = AwsCredentials(
      accessKeyId: 'ASIAEXAMPLEKEY123456',
      secretKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
      sessionToken: 'IQoJb3JpZ2luX2VjEXAMPLE+/tok=en==',
    );

    final uri = TranscribePresigner.presign(
      credentials: credentials,
      sampleRate: 16000,
      region: 'ap-northeast-1',
      languageCode: 'ja-JP',
      expires: const Duration(seconds: 60),
      now: DateTime.utc(2026, 9, 28, 12, 34, 56),
    );

    test('botocore と同じ署名になる', () {
      expect(
        uri.queryParameters['X-Amz-Signature'],
        'e0e73893a595f7e5d09e7dde726fc3aacd7aab0b03b2b589dc2d5f6ccaada359',
      );
    });

    test('接続先は 8443 番ポートの WebSocket', () {
      expect(uri.scheme, 'wss');
      expect(uri.host, 'transcribestreaming.ap-northeast-1.amazonaws.com');
      expect(uri.port, 8443);
      expect(uri.path, '/stream-transcription-websocket');
    });

    test('必要なパラメータが入っている', () {
      final q = uri.queryParameters;
      expect(q['language-code'], 'ja-JP');
      expect(q['media-encoding'], 'pcm');
      expect(q['sample-rate'], '16000');
      expect(q['X-Amz-Expires'], '60');
      expect(q['X-Amz-Date'], '20260928T123456Z');
      expect(q['X-Amz-SignedHeaders'], 'host');
      expect(
        q['X-Amz-Credential'],
        'ASIAEXAMPLEKEY123456/20260928/ap-northeast-1/transcribe/aws4_request',
      );
      // エンコードして送り、受け取った側で元に戻ること
      expect(q['X-Amz-Security-Token'], 'IQoJb3JpZ2luX2VjEXAMPLE+/tok=en==');
    });
  });

  group('AwsCredentials', () {
    final now = DateTime.utc(2026, 9, 28, 12);

    test('失効まで余裕があれば取り直さない', () {
      final c = AwsCredentials(
        accessKeyId: 'a',
        secretKey: 's',
        sessionToken: 't',
        expiration: now.add(const Duration(minutes: 30)),
      );
      expect(c.expiresWithin(const Duration(minutes: 5), now: now), isFalse);
    });

    test('失効が近ければ取り直す', () {
      final c = AwsCredentials(
        accessKeyId: 'a',
        secretKey: 's',
        sessionToken: 't',
        expiration: now.add(const Duration(minutes: 3)),
      );
      expect(c.expiresWithin(const Duration(minutes: 5), now: now), isTrue);
    });

    test('文字列にしても秘密の値が出ない', () {
      const c = AwsCredentials(
        accessKeyId: 'AKIA-SECRET',
        secretKey: 'SECRET',
        sessionToken: 'TOKEN',
      );
      expect(c.toString(), isNot(contains('SECRET')));
      expect(c.toString(), isNot(contains('TOKEN')));
    });
  });

  group('AwsClock', () {
    final local = DateTime.utc(2026, 9, 29, 12);

    tearDown(AwsClock.reset);

    test('AWS の時刻とのずれを覚える', () {
      // 端末が20分遅れている
      AwsClock.calibrate(
        local.add(const Duration(minutes: 20)),
        localNow: local,
      );
      expect(AwsClock.offset, const Duration(minutes: 20));
    });

    test('1分未満のずれは無視する', () {
      AwsClock.calibrate(
        local.add(const Duration(seconds: 40)),
        localNow: local,
      );
      expect(AwsClock.offset, Duration.zero);
    });

    test('ずれが直ったら補正をやめる', () {
      AwsClock.calibrate(
        local.add(const Duration(minutes: 20)),
        localNow: local,
      );
      AwsClock.calibrate(local, localNow: local);
      expect(AwsClock.offset, Duration.zero);
    });

    test('HTTP の Date ヘッダから読み取る', () {
      AwsClock.calibrateFromHttpDate(
        'Tue, 29 Sep 2026 12:30:00 GMT',
        localNow: local,
      );
      expect(AwsClock.offset, const Duration(minutes: 30));
    });

    test('読めない Date ヘッダは無視する', () {
      AwsClock.calibrateFromHttpDate('not a date', localNow: local);
      AwsClock.calibrateFromHttpDate(null, localNow: local);
      expect(AwsClock.offset, Duration.zero);
    });
  });
}
