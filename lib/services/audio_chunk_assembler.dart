import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:raim_prototype/services/raim_log.dart';

/// 受信した音声パーツ1件。
class AudioChunkPart {
  const AudioChunkPart({
    required this.audioBase64,
    required this.format,
    this.chunkId,
    this.partIndex,
    this.partCount,
    this.isLast = false,
    this.isFirst = false,
  });

  final String? chunkId;
  final String audioBase64;
  final String format;
  final int? partIndex;
  final int? partCount;
  final bool isLast;
  final bool isFirst;
}

/// 再生可能な完成済み音声。
class AssembledAudio {
  const AssembledAudio({
    required this.bytes,
    required this.format,
    this.chunkId,
  });

  final Uint8List bytes;
  final String format;
  final String? chunkId;
}

typedef AudioReadyCallback = void Function(AssembledAudio audio);

/// 分割音声を保持し、完成した音声をchunk順に通知する。
///
/// multipartのaudioは「各パーツが完全なWAV」であることを前提にする。
/// 結合時は各WAVのdataチャンクだけを連結し、ヘッダーを再生成する。
class AudioChunkAssembler {
  AudioChunkAssembler({
    required this.onAudioReady,
    this.partTimeout = const Duration(seconds: 5),
    this.orderTimeout = const Duration(seconds: 5),
  });

  final AudioReadyCallback onAudioReady;
  final Duration partTimeout;
  final Duration orderTimeout;

  final Map<String, _PendingChunk> _pending = {};
  final Map<String, AssembledAudio> _ready = {};
  final Set<String> _skipped = {};
  final Set<String> _finalized = {};
  final List<String> _seenChunkIds = [];
  Timer? _orderTimer;
  String? _nextChunkId;
  bool _disposed = false;

  /// 音声パーツを追加する。
  void add(AudioChunkPart part) {
    if (_disposed || part.audioBase64.trim().isEmpty) return;

    final chunkId = part.chunkId?.trim();

    // part_countがないものは従来どおり単一音声として即時処理する。
    if (part.partCount == null) {
      _emitSingle(part, chunkId);
      return;
    }

    if (chunkId == null || chunkId.isEmpty) return;
    final partCount = part.partCount!;
    final partIndex = part.partIndex;

    // AWS実装差異に備え、part_indexは0始まり・1始まりの両方を受け付ける。
    // 0またはpart_countが届いた時点で基準を確定する。
    if (partCount <= 0 || partIndex == null || partIndex < 0 ||
        partIndex > partCount) {
      RaimLog.d(
        '[AudioChunkAssembler] invalid part metadata: '
        'chunkId=$chunkId partIndex=$partIndex partCount=$partCount',
      );
      return;
    }

    _registerChunk(chunkId, isFirst: part.isFirst);

    // 完成済み、またはタイムアウト・不正データとして処理済みのchunkは再処理しない。
    if (_finalized.contains(chunkId)) return;

    final current = _pending[chunkId];
    if (current != null && current.partCount != partCount) {
      // 同じchunk内でpart_countが変わった場合は不正なchunkとして破棄する。
      current.timer.cancel();
      _pending.remove(chunkId);
      _finalized.add(chunkId);
      _skipped.add(chunkId);
      _drainReady();
      return;
    }

    final pending = current ?? _PendingChunk(
      partCount: partCount,
      timer: Timer(partTimeout, () => _expire(chunkId)),
    );
    _pending[chunkId] = pending;

    final inferredBase = _inferIndexBase(
      partIndex: partIndex,
      partCount: partCount,
      isLast: part.isLast,
    );
    if (inferredBase != null) {
      if (pending.indexBase != null && pending.indexBase != inferredBase) {
        pending.timer.cancel();
        _pending.remove(chunkId);
        _finalized.add(chunkId);
        _skipped.add(chunkId);
        _drainReady();
        return;
      }
      pending.indexBase = inferredBase;
    }

    // 同じraw part_indexは重複として無視し、二重再生を防ぐ。
    if (pending.parts.containsKey(partIndex)) {
      RaimLog.d(
        '[AudioChunkAssembler] duplicate part ignored: '
        'chunkId=$chunkId partIndex=$partIndex',
      );
      return;
    }
    pending.parts[partIndex] = part.audioBase64;
    pending.isLast = pending.isLast || part.isLast;

    final normalizedParts = _normalizedParts(pending);
    final hasAllParts = normalizedParts.length == partCount &&
        Iterable<int>.generate(partCount).every(normalizedParts.containsKey);
    final lastIndex = normalizedParts.keys.isEmpty
        ? -1
        : normalizedParts.keys.reduce((a, b) => a > b ? a : b);
    // is_lastだけを根拠に欠落パーツを結合しない。
    // part_countと末尾インデックスが一致し、0から連続している場合のみ完成とする。
    final hasContiguousLast = pending.isLast &&
        lastIndex == partCount - 1 &&
        Iterable<int>.generate(partCount).every(normalizedParts.containsKey);

    if (!hasAllParts && !hasContiguousLast) {
      _drainReady();
      return;
    }

    pending.timer.cancel();
    _pending.remove(chunkId);
    _finalized.add(chunkId);

    try {
      final indexes = normalizedParts.keys.toList()..sort();
      final encodedParts = indexes.map((index) => normalizedParts[index]!);
      final bytes = WavDataMerger.mergeBase64(encodedParts);
      _ready[chunkId] = AssembledAudio(
        bytes: bytes,
        format: part.format,
        chunkId: chunkId,
      );
    } catch (_) {
      RaimLog.e('[AudioChunkAssembler] WAV assembly failed: chunkId=$chunkId');
      _skipped.add(chunkId);
    }

    _drainReady();
  }

  /// 保持中のパーツとタイマーをすべて破棄する。
  void reset() {
    for (final chunk in _pending.values) {
      chunk.timer.cancel();
    }
    _pending.clear();
    _ready.clear();
    _skipped.clear();
    _finalized.clear();
    _seenChunkIds.clear();
    _orderTimer?.cancel();
    _orderTimer = null;
    _nextChunkId = null;
  }

  void dispose() {
    _disposed = true;
    reset();
  }

  void _emitSingle(AudioChunkPart part, String? chunkId) {
    try {
      final normalized = _normalizeBase64(part.audioBase64);
      onAudioReady(AssembledAudio(
        bytes: Uint8List.fromList(base64Decode(normalized)),
        format: part.format,
        chunkId: chunkId?.isEmpty == true ? null : chunkId,
      ));
    } catch (_) {
      // 不正なBase64は再生対象から除外する。
      RaimLog.e('[AudioChunkAssembler] single audio decode failed');
    }
  }

  void _registerChunk(String chunkId, {required bool isFirst}) {
    if (!_seenChunkIds.contains(chunkId)) {
      _seenChunkIds.add(chunkId);
    }
    if (isFirst) {
      _nextChunkId = chunkId;
    } else {
      _nextChunkId ??= _initialChunkId(chunkId);
    }
  }

  void _expire(String chunkId) {
    final pending = _pending.remove(chunkId);
    pending?.timer.cancel();
    RaimLog.d('[AudioChunkAssembler] chunk timeout: chunkId=$chunkId');
    _finalized.add(chunkId);
    _skipped.add(chunkId);
    _drainReady();
  }

  void _drainReady() {
    if (_disposed) return;

    while (true) {
      final next = _nextChunkId;
      if (next == null) {
        if (_ready.isEmpty) return;
        _nextChunkId = _sortedIds(_ready.keys).first;
        continue;
      }

      if (_skipped.remove(next)) {
        _orderTimer?.cancel();
        _orderTimer = null;
        _nextChunkId = _nextIdAfter(next);
        continue;
      }

      final ready = _ready.remove(next);
      if (ready != null) {
        _orderTimer?.cancel();
        _orderTimer = null;
        onAudioReady(ready);
        _nextChunkId = _nextIdAfter(next);
        continue;
      }

      if (_pending.containsKey(next) || _hasLaterReady(next)) {
        _orderTimer ??= Timer(orderTimeout, () {
          _orderTimer = null;
          _skipped.add(next);
          _drainReady();
        });
      }
      return;
    }
  }

  bool _hasLaterReady(String chunkId) {
    return _ready.keys.any((id) => _compareChunkIds(id, chunkId) > 0);
  }

  int? _inferIndexBase({
    required int partIndex,
    required int partCount,
    required bool isLast,
  }) {
    if (partIndex == 0) return 0;
    if (partIndex == partCount) return 1;
    if (!isLast) return null;
    if (partIndex == partCount - 1) return 0;
    return null;
  }

  Map<int, String> _normalizedParts(_PendingChunk pending) {
    final base = pending.indexBase ?? 0;
    final normalized = <int, String>{};
    for (final entry in pending.parts.entries) {
      final index = entry.key - base;
      if (index >= 0 && index < pending.partCount) {
        normalized[index] = entry.value;
      }
    }
    return normalized;
  }

  String? _nextIdAfter(String chunkId) {
    final numeric = _numericChunkId(chunkId);
    if (numeric != null && _isSequenceId(numeric)) {
      final nextNumber = numeric.number + 1;
      final padded = nextNumber.toString().padLeft(numeric.digits, '0');
      return '${numeric.prefix}$padded';
    }

    final later = _sortedIds(_seenChunkIds.where((id) =>
        _compareChunkIds(id, chunkId) > 0));
    return later.isEmpty ? null : later.first;
  }

  String _initialChunkId(String chunkId) {
    final numeric = _numericChunkId(chunkId);
    if (numeric == null || !_isSequenceId(numeric) || numeric.number == 0) {
      return chunkId;
    }
    return '${numeric.prefix}${'0'.padLeft(numeric.digits, '0')}';
  }

  bool _isSequenceId(_NumericChunkId id) {
    final prefix = id.prefix.toLowerCase();
    return prefix.isEmpty || prefix.contains('chunk');
  }

  List<String> _sortedIds(Iterable<String> ids) {
    final result = ids.toList();
    result.sort(_compareChunkIds);
    return result;
  }

  int _compareChunkIds(String a, String b) {
    final left = _numericChunkId(a);
    final right = _numericChunkId(b);
    if (left != null && right != null && _isSequenceId(left) &&
        _isSequenceId(right) && left.prefix == right.prefix) {
      return left.number.compareTo(right.number);
    }
    return a.compareTo(b);
  }

  _NumericChunkId? _numericChunkId(String value) {
    final match = RegExp(r'^(.*?)(\d+)$').firstMatch(value);
    if (match == null) return null;
    return _NumericChunkId(
      prefix: match.group(1)!,
      number: int.parse(match.group(2)!),
      digits: match.group(2)!.length,
    );
  }

  String _normalizeBase64(String value) {
    final trimmed = value.trim();
    if (!trimmed.startsWith('data:')) return trimmed;
    final commaIndex = trimmed.indexOf(',');
    return commaIndex == -1 ? trimmed : trimmed.substring(commaIndex + 1);
  }
}

class _PendingChunk {
  _PendingChunk({required this.partCount, required this.timer});

  final int partCount;
  final Timer timer;
  final Map<int, String> parts = {};
  bool isLast = false;
  int? indexBase;
}

class _NumericChunkId {
  const _NumericChunkId({
    required this.prefix,
    required this.number,
    required this.digits,
  });

  final String prefix;
  final int number;
  final int digits;
}

/// 完全なWAVパーツからdataチャンクを取り出して1つのWAVへ再構成する。
class WavDataMerger {
  static Uint8List mergeBase64(Iterable<String> encodedParts) {
    final decodedParts = encodedParts
        .map((part) => Uint8List.fromList(base64Decode(_normalize(part))))
        .toList();
    if (decodedParts.isEmpty) {
      throw const FormatException('WAVパーツがありません');
    }

    // 通常は各パーツが完全なWAVだが、先頭パーツだけがWAVヘッダーを持ち、
    // 2個目以降がPCM断片として届く実装にも対応する。
    final first = _parse(decodedParts.first, allowTruncatedData: true);
    final waves = <_ParsedWav>[first];
    for (final bytes in decodedParts.skip(1)) {
      if (_looksLikeWav(bytes)) {
        waves.add(_parse(bytes));
      } else {
        waves.add(_ParsedWav(
          formatBytes: first.formatBytes,
          data: bytes,
        ));
      }
    }

    for (final wave in waves.skip(1)) {
      if (!_sameBytes(first.formatBytes, wave.formatBytes)) {
        throw const FormatException('WAVフォーマットが一致しません');
      }
    }

    final dataLength = waves.fold<int>(
      0,
      (sum, wave) => sum + wave.data.length,
    );
    final output = BytesBuilder(copy: false);
    output.add(_ascii('RIFF'));
    _writeUint32(output, 4 + 8 + first.formatBytes.length + 8 + dataLength);
    output.add(_ascii('WAVE'));
    output.add(_ascii('fmt '));
    _writeUint32(output, first.formatBytes.length);
    output.add(first.formatBytes);
    output.add(_ascii('data'));
    _writeUint32(output, dataLength);
    for (final wave in waves) {
      output.add(wave.data);
    }
    return output.toBytes();
  }

  static _ParsedWav _parse(
    Uint8List bytes, {
    bool allowTruncatedData = false,
  }) {
    if (bytes.length < 12 || _readAscii(bytes, 0, 4) != 'RIFF' ||
        _readAscii(bytes, 8, 4) != 'WAVE') {
      throw const FormatException('WAVヘッダーが不正です');
    }

    Uint8List? formatBytes;
    final data = BytesBuilder(copy: false);
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = _readAscii(bytes, offset, 4);
      final size = _readUint32(bytes, offset + 4);
      final dataStart = offset + 8;
      final dataEnd = dataStart + size;
      if (dataEnd > bytes.length) {
        if (!allowTruncatedData || id != 'data') {
          throw const FormatException('WAVチャンク長が不正です');
        }
        data.add(bytes.sublist(dataStart));
        break;
      }
      if (id == 'fmt ') {
        formatBytes ??= Uint8List.fromList(bytes.sublist(dataStart, dataEnd));
      } else if (id == 'data') {
        data.add(bytes.sublist(dataStart, dataEnd));
      }
      offset = dataEnd + (size.isOdd ? 1 : 0);
    }

    if (formatBytes == null || data.length == 0) {
      throw const FormatException('WAVにfmtまたはdataチャンクがありません');
    }
    return _ParsedWav(formatBytes: formatBytes!, data: data.toBytes());
  }

  static bool _looksLikeWav(Uint8List bytes) {
    return bytes.length >= 12 && _readAscii(bytes, 0, 4) == 'RIFF' &&
        _readAscii(bytes, 8, 4) == 'WAVE';
  }

  static String _normalize(String value) {
    final trimmed = value.trim();
    if (!trimmed.startsWith('data:')) return trimmed;
    final commaIndex = trimmed.indexOf(',');
    return commaIndex == -1 ? trimmed : trimmed.substring(commaIndex + 1);
  }

  static Uint8List _ascii(String value) => Uint8List.fromList(value.codeUnits);

  static String _readAscii(Uint8List bytes, int offset, int length) =>
      String.fromCharCodes(bytes.sublist(offset, offset + length));

  static int _readUint32(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static void _writeUint32(BytesBuilder output, int value) {
    output.add(Uint8List.fromList(<int>[
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ]));
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _ParsedWav {
  const _ParsedWav({required this.formatBytes, required this.data});

  final Uint8List formatBytes;
  final Uint8List data;
}
