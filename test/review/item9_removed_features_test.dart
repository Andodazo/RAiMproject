// 課題9: 展示モードと、駅アラームの録音機能（確認用）が残っていた
//
//   flutter test test/review/item9_removed_features_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source.dart';

/// 探す場所（このテスト自身がある test/review は除く）
Iterable<File> appSources() => [
      'lib',
      'test',
      'windows/runner',
      'android/app/src',
      'ios/Runner',
      'unity/raim_unity/raim/Assets/Scripts',
    ]
        .expand((dir) => filesUnder(dir, extensions: {
              '.dart', '.cs', '.cpp', '.h', '.kt', '.java', '.swift', '.plist', '.xml',
            }))
        .where((f) => !f.path.replaceAll('\\', '/').contains('test/review/'));

void main() {
  test('展示モードのコードが残っていない', () {
    final hits = findLines(
      appSources(),
      RegExp(r'exhibition|DemoAccountPolicy|demo_account_policy', caseSensitive: false),
    );
    expect(hits, isEmpty, reason: '展示モードの名残:\n${hits.join('\n')}');
  });

  test('展示用のファイルが消えている', () {
    for (final path in [
      'lib/services/demo_account_policy.dart',
      'test/demo_account_policy_test.dart',
    ]) {
      expect(File(path).existsSync(), isFalse, reason: '$path が残っている');
    }
  });

  test('駅アラームの録音（確認用）のコードが残っていない', () {
    final hits = findLines(
      appSources(),
      RegExp(r'StationRecord|station_rec|stationRecording', caseSensitive: false),
    );
    expect(hits, isEmpty, reason: '録音機能の名残:\n${hits.join('\n')}');
  });

  test('iOS で書類フォルダを「ファイル」アプリに見せる設定を外している', () {
    final plist = readSource('ios/Runner/Info.plist');
    expect(plist.contains('UIFileSharingEnabled'), isFalse,
        reason: '録音を取り出すための UIFileSharingEnabled が残っている');
    expect(plist.contains('LSSupportsOpeningDocumentsInPlace'), isFalse,
        reason: '録音を取り出すための LSSupportsOpeningDocumentsInPlace が残っている');
  });
}
