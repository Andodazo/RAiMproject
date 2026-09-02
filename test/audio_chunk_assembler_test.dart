import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/services/audio_chunk_assembler.dart';

void main() {
  group('LLMResponse audio part metadata', () {
    test('parses multipart fields', () {
      final response = LLMResponse.fromJson({
        'type': 'audio_chunk',
        'chunk_id': 'chunk-3',
        'part_index': 1,
        'part_count': 2,
        'is_last': true,
        'audio': 'audio',
      });

      expect(response.chunkId, 'chunk-3');
      expect(response.partIndex, 1);
      expect(response.partCount, 2);
      expect(response.isLast, isTrue);
    });

    test('keeps omitted multipart fields backward compatible', () {
      final response = LLMResponse.fromJson({
        'type': 'audio_chunk',
        'audio': 'audio',
      });

      expect(response.partIndex, isNull);
      expect(response.partCount, isNull);
      expect(response.isLast, isFalse);
    });
  });

  group('WavDataMerger', () {
    test('joins data chunks and rebuilds RIFF sizes', () {
      final merged = WavDataMerger.mergeBase64([
        _base64Wav(<int>[1, 2]),
        _base64Wav(<int>[3, 4, 5]),
      ]);

      expect(String.fromCharCodes(merged.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(merged.sublist(8, 12)), 'WAVE');
      expect(_readUint32(merged, 4), merged.length - 8);
      expect(_readUint32(merged, 40), 5);
      expect(merged.sublist(44), <int>[1, 2, 3, 4, 5]);
    });
  });

  group('AudioChunkAssembler', () {
    test('waits for out-of-order parts and emits exactly once', () {
      final received = <AssembledAudio>[];
      final assembler = AudioChunkAssembler(onAudioReady: received.add);

      assembler.add(AudioChunkPart(
        chunkId: 'chunk-0',
        partIndex: 1,
        partCount: 2,
        audioBase64: _base64Wav(<int>[3, 4]),
        format: 'wav',
        isLast: true,
      ));
      expect(received, isEmpty);

      assembler.add(AudioChunkPart(
        chunkId: 'chunk-0',
        partIndex: 0,
        partCount: 2,
        audioBase64: _base64Wav(<int>[1, 2]),
        format: 'wav',
      ));
      assembler.add(AudioChunkPart(
        chunkId: 'chunk-0',
        partIndex: 1,
        partCount: 2,
        audioBase64: _base64Wav(<int>[3, 4]),
        format: 'wav',
        isLast: true,
      ));

      expect(received, hasLength(1));
      expect(received.single.bytes.sublist(44), <int>[1, 2, 3, 4]);
    });

    test('accepts one-based part indexes', () {
      final received = <AssembledAudio>[];
      final assembler = AudioChunkAssembler(onAudioReady: received.add);

      assembler.add(AudioChunkPart(
        chunkId: 'chunk-0',
        partIndex: 2,
        partCount: 2,
        audioBase64: _base64Wav(<int>[2]),
        format: 'wav',
        isLast: true,
      ));
      assembler.add(AudioChunkPart(
        chunkId: 'chunk-0',
        partIndex: 1,
        partCount: 2,
        audioBase64: _base64Wav(<int>[1]),
        format: 'wav',
      ));

      expect(received, hasLength(1));
      expect(received.single.bytes.sublist(44), <int>[1, 2]);
    });

    test('preserves chunk order when a later chunk completes first', () {
      final received = <AssembledAudio>[];
      final assembler = AudioChunkAssembler(onAudioReady: received.add);

      assembler.add(AudioChunkPart(
        chunkId: 'chunk-0',
        partIndex: 0,
        partCount: 2,
        audioBase64: _base64Wav(<int>[1]),
        format: 'wav',
      ));
      assembler.add(AudioChunkPart(
        chunkId: 'chunk-1',
        partIndex: 0,
        partCount: 1,
        audioBase64: _base64Wav(<int>[2]),
        format: 'wav',
      ));
      expect(received, isEmpty);

      assembler.add(AudioChunkPart(
        chunkId: 'chunk-0',
        partIndex: 1,
        partCount: 2,
        audioBase64: _base64Wav(<int>[3]),
        format: 'wav',
        isLast: true,
      ));

      expect(received.map((audio) => audio.chunkId).toList(), <String?>[
        'chunk-0',
        'chunk-1',
      ]);
    });

    test('does not emit an incomplete chunk after timeout', () async {
      final received = <AssembledAudio>[];
      final assembler = AudioChunkAssembler(
        onAudioReady: received.add,
        partTimeout: const Duration(milliseconds: 10),
      );

      assembler.add(AudioChunkPart(
        chunkId: 'chunk-0',
        partIndex: 0,
        partCount: 2,
        audioBase64: _base64Wav(<int>[1]),
        format: 'wav',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(received, isEmpty);
      assembler.dispose();
    });

    test('plays a single audio without part_count immediately', () {
      final received = <AssembledAudio>[];
      final assembler = AudioChunkAssembler(onAudioReady: received.add);

      assembler.add(AudioChunkPart(
        chunkId: 'legacy',
        audioBase64: base64Encode(<int>[1, 2, 3]),
        format: 'wav',
      ));

      expect(received, hasLength(1));
      expect(received.single.bytes, <int>[1, 2, 3]);
    });
  });
}

String _base64Wav(List<int> data) {
  final bytes = <int>[
    ...'RIFF'.codeUnits,
    ..._uint32(36 + data.length),
    ...'WAVE'.codeUnits,
    ...'fmt '.codeUnits,
    ..._uint32(16),
    1, 0, // PCM
    1, 0, // mono
    0x44, 0xAC, 0, 0, // 44100 Hz
    0x88, 0x58, 1, 0, // byte rate
    2, 0, // block align
    16, 0, // bits per sample
    ...'data'.codeUnits,
    ..._uint32(data.length),
    ...data,
  ];
  return base64Encode(bytes);
}

List<int> _uint32(int value) => <int>[
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];

int _readUint32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);
