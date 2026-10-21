// 課題7: Unity が受け取ったメッセージを、会話の中身ごとログに出していた
//
//   flutter test test/review/item7_unity_log_test.dart
//
// Unity のコードは Flutter のテストでは動かせないので、ログを出す行を読んで確かめる。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source.dart';

/// Flutter や WebSocket から会話を受け取る C# のファイル
const scripts = [
  'unity/raim_unity/raim/Assets/Scripts/RAiMCharacterController.cs',
  'unity/raim_unity/raim/Assets/Scripts/SpeechBubbleController.cs',
];

void main() {
  test('受け取った JSON や本文を、そのままログに出していない', () {
    // Debug.Log の行で、受け取った文字列（json / message / text など）を
    // そのまま埋め込んでいるものを探す。e.Message（例外の説明）は対象外。
    final rawValue = RegExp(
      r'Debug\.Log[A-Za-z]*\(.*('
      r'\{\s*(json|message|text|fullText|full_text|rawMessage|raw|data\.text|chunk\.text)\s*\}'
      r'|\+\s*(json|message|text)\b'
      r')',
    );
    final hits = findLines(scripts.map((p) => File(p)), rawValue);
    expect(hits, isEmpty, reason: '会話の中身をログに出している行:\n${hits.join('\n')}');
  });

  test('対象のファイルがある', () {
    for (final path in scripts) {
      expect(File(path).existsSync(), isTrue, reason: '$path が無い');
    }
  });
}
