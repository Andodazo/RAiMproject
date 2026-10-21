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

    test('開発用（Tailscale）には付けない', () {
      expect(RaimConfig.isAwsUrl(RaimConfig.localServerUrl), isFalse);
    });

    test('URL として読めないものには付けない', () {
      expect(RaimConfig.isAwsUrl(''), isFalse);
      expect(RaimConfig.isAwsUrl('cloudfront.net'), isFalse);
    });
  });

  group('切り替えメニュー（RaimConfig.enableServerSwitch）', () {
    test('ほかのファイルで URL の部分一致を使っていない', () {
      final hits = findLines(
        filesUnder('lib', extensions: {'.dart'}),
        RegExp(r'''contains\(\s*['"]cloudfront\.net['"]\s*\)'''),
      );
      expect(hits, isEmpty, reason: 'まだ部分一致で見ている所がある:\n${hits.join('\n')}');
    });

    test('スマホのメニューはフラグを見て隠している', () {
      final source = readSource('lib/widgets/chat_input.dart');
      expect(source, contains('RaimConfig.enableServerSwitch'),
          reason: 'chat_input.dart の接続先の切り替えがフラグを見ていない');
    });

    test('Windows のメニューはフラグを見て隠している', () {
      final source = readSource('lib/screens/windows_input_window.dart');
      expect(source, contains('RaimConfig.enableServerSwitch'),
          reason: 'windows_input_window.dart の接続先の切り替えがフラグを見ていない');
    });

    test('switchServer もフラグを見て止める（メニューを隠すだけにしない）', () {
      final source = readSource('lib/services/raim_server_service.dart');
      final body = methodBodyAfter(source, ' switchServer(');
      expect(body, isNotNull, reason: 'switchServer が見つからない');
      expect(body, contains('enableServerSwitch'),
          reason: 'switchServer の中でフラグを見ていない');
    });

    test('指定しないで release ビルドしたときは隠れる', () {
      final source = readSource('lib/config/raim_config.dart');
      final start = source.indexOf(RegExp(r'bool\s+enableServerSwitch'));
      expect(start, greaterThanOrEqualTo(0), reason: 'enableServerSwitch が無い');
      final declaration = source.substring(start, source.indexOf(';', start));
      expect(
        declaration.contains('dart.vm.product') ||
            declaration.contains('kReleaseMode') ||
            RegExp(r'defaultValue:\s*false').hasMatch(declaration),
        isTrue,
        reason: 'フラグを付けずに release ビルドするとメニューが出る（既定が true のまま）',
      );
    });
  });
}
