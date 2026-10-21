// 課題8: 鍵ファイルが無いと、release ビルドが debug 鍵で署名されたまま作られていた
//
//   flutter test test/review/item8_release_signing_test.dart
//
// Gradle を動かすと時間がかかるので、build.gradle.kts を読んで確かめる。

import 'package:flutter_test/flutter_test.dart';

import 'support/source.dart';

void main() {
  final gradle = readSource('android/app/build.gradle.kts');

  test('key.properties が無いときに、ビルドを止める処理がある', () {
    expect(
      RegExp(r'throw\s+GradleException\s*\(|\berror\s*\(').hasMatch(gradle),
      isTrue,
      reason: 'release を作るときに鍵が無くても止めていない（GradleException を投げていない）',
    );
  });

  test('止めるのは release を作るときだけ（debug のビルドは止めない）', () {
    expect(
      RegExp(r'taskGraph|assembleRelease|bundleRelease|gradle\.startParameter')
          .hasMatch(gradle),
      isTrue,
      reason: 'どのビルドのときに止めるのかを見ていない（debug でも止まってしまう）',
    );
  });

  test('鍵ファイルの中身を Git に入れていない', () {
    for (final secret in ['storePassword=', 'keyPassword=']) {
      expect(gradle.contains(secret), isFalse, reason: 'build.gradle.kts に $secret が書かれている');
    }
  });
}
