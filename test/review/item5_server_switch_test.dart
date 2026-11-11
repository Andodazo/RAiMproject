// 課題5: 配布ビルドでも開発用サーバーへの切り替えメニューが出る。
//        トークンを付ける相手かどうかを URL の部分一致で決めている
//
//   flutter test test/review/item5_server_switch_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/config/raim_config.dart';

import 'support/source.dart';

void main() {
  group('トークンを付ける相手（RaimConfig.isAwsUrl）', () {
    test('本番の接続先には付ける', () {
      expect(RaimConfig.isAwsUrl(RaimConfig.serverUrl), isTrue);
    });

    test('ホスト名に cloudfront.net を含むだけの別のサーバーには付けない', () {
      expect(RaimConfig.isAwsUrl('wss://cloudfront.net.example.com/dev'), isFalse);
      expect(RaimConfig.isAwsUrl('wss://evilcloudfront.net/dev'), isFalse);
    });

    test('パスやクエリに cloudfront.net があるだけのサーバーには付けない', () {
      expect(RaimConfig.isAwsUrl('wss://example.com/cloudfront.net'), isFalse);
      expect(RaimConfig.isAwsUrl('wss://example.com/dev?x=cloudfront.net'), isFalse);
    });

    test('URL として読めないものには付けない', () {
      expect(RaimConfig.isAwsUrl(''), isFalse);
      expect(RaimConfig.isAwsUrl('cloudfront.net'), isFalse);
    });
  });

  group('接続先URLの判定', () {
    test('ほかのファイルで URL の部分一致を使っていない', () {
      final hits = findLines(
        filesUnder('lib', extensions: {'.dart'}),
        RegExp(r'''contains\(\s*['"]cloudfront\.net['"]\s*\)'''),
      );
      expect(hits, isEmpty, reason: 'まだ部分一致で見ている所がある:\n${hits.join('\n')}');
    });
  });
}
