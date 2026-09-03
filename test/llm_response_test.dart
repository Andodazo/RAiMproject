import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/llm_response.dart';

/// サーバーから届く JSON の解釈が壊れないことを確かめる。
///
/// ここが壊れると、応答が途中で打ち切られたり、
/// 1件の型違いでメッセージ全体が捨てられたりする。
void main() {
  group('LLMResponse.fromJson', () {
    test('type が無いメッセージは unknown になり、終端扱いにならない', () {
      final response = LLMResponse.fromJson({'text': 'こんにちは'});

      expect(response.type, 'unknown');
      expect(response.isChat, isFalse);
      expect(response.isChatEnd, isFalse);
      expect(response.isError, isFalse);
    });

    test('type が文字列でなくても例外を投げず unknown になる', () {
      final response = LLMResponse.fromJson({'type': 123});

      expect(response.type, 'unknown');
    });

    test('estimated_seconds が小数でも int として読める', () {
      final response = LLMResponse.fromJson({
        'type': 'tool_call',
        'estimated_seconds': 3.0,
      });

      expect(response.estimatedSeconds, 3);
    });

    test('文字列であるべき項目が別の型でも落ちない', () {
      final response = LLMResponse.fromJson({
        'type': 'text_chunk',
        'text': 42,
        'chunk_id': false,
        'is_first': 'yes',
      });

      expect(response.text, '');
      expect(response.chunkId, isNull);
      expect(response.isFirst, isFalse);
    });

    test('通常の text_chunk は今まで通り読める', () {
      final response = LLMResponse.fromJson({
        'type': 'text_chunk',
        'text': 'おはよう',
        'chunk_id': 'req-1_chunk_0',
        'is_first': true,
        'is_filler': false,
      });

      expect(response.isTextChunk, isTrue);
      expect(response.text, 'おはよう');
      expect(response.chunkId, 'req-1_chunk_0');
      expect(response.isFirst, isTrue);
      expect(response.isFiller, isFalse);
    });

    test('旧形式の chat は終端として扱われる', () {
      final response = LLMResponse.fromJson({'type': 'chat', 'text': 'やあ'});

      expect(response.isChat, isTrue);
    });
  });
}
