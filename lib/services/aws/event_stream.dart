// lib/services/aws/event_stream.dart
//
// AWS のイベントストリーム形式の組み立てと読み取り。
//
// Transcribe のストリーミングは WebSocket の上でこの形式を使う。
// 送る音声も、返ってくる文字起こしも、1件ずつこの形で包まれている。
//
//   ┌──────────── prelude（12バイト）────────────┐
//   │ 全体の長さ(4) │ ヘッダの長さ(4) │ CRC32(4) │
//   ├─────────────────────────────────────────┤
//   │ ヘッダ（名前・型・値 の並び）                │
//   ├─────────────────────────────────────────┤
//   │ 本文（音声の PCM や JSON）                  │
//   ├─────────────────────────────────────────┤
//   │ ここまで全体の CRC32(4)                     │
//   └─────────────────────────────────────────┘
//
// 数値はすべてビッグエンディアン。
// 仕様: https://docs.aws.amazon.com/transcribe/latest/dg/streaming-setting-up.html
//
// 【なぜ自前で持つか】
// Dart 向けの AWS SDK には Transcribe のストリーミングが無い。
// 形式は小さいので、依存を増やすより自分で持つ方が見通しがよい。

import 'dart:convert';
import 'dart:typed_data';

/// CRC32（IEEE 802.3、zlib と同じ）。
class Crc32 {
  Crc32._();

  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      }
      table[n] = c;
    }
    return table;
  }

  /// [bytes] の [start] から [end] の手前までの CRC32。
  static int of(List<int> bytes, [int start = 0, int? end]) {
    final stop = end ?? bytes.length;
    var c = 0xFFFFFFFF;
    for (var i = start; i < stop; i++) {
      c = _table[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

/// イベントストリームの1件。
class EventStreamMessage {
  EventStreamMessage({required this.headers, required this.payload});

  /// ヘッダ。値の型はヘッダの型番号で決まる:
  /// bool / int / Uint8List / String / DateTime（UTC）/ String（UUID の16進）
  final Map<String, Object> headers;

  final Uint8List payload;

  /// 文字列ヘッダを取り出す。無いか文字列でなければ null。
  String? stringHeader(String name) {
    final value = headers[name];
    return value is String ? value : null;
  }

  /// `event` / `exception` / `error` のどれか。
  String get messageType => stringHeader(':message-type') ?? '';
}

/// イベントストリームの組み立て。
class EventStreamEncoder {
  EventStreamEncoder._();

  static const int _typeString = 7;

  /// 文字列ヘッダだけのメッセージを組み立てる。
  ///
  /// 送る側（音声）では文字列ヘッダしか使わないので、それだけに対応する。
  /// ヘッダは Map の順番どおりに並ぶ。
  static Uint8List encode(Map<String, String> headers, List<int> payload) {
    final headerBytes = BytesBuilder(copy: false);
    for (final entry in headers.entries) {
      final name = entry.key;
      final n = utf8.encode(name);
      final v = utf8.encode(entry.value);
      if (n.isEmpty || n.length > 255) {
        throw ArgumentError.value(name, 'headers', 'ヘッダ名の長さが不正です');
      }
      if (v.length > 0xFFFF) {
        throw ArgumentError.value(name, 'headers', 'ヘッダの値が長すぎます');
      }
      headerBytes
        ..addByte(n.length)
        ..add(n)
        ..addByte(_typeString)
        ..addByte(v.length >> 8)
        ..addByte(v.length & 0xFF)
        ..add(v);
    }
    final h = headerBytes.takeBytes();

    final total = 12 + h.length + payload.length + 4;
    final out = Uint8List(total);
    final view = ByteData.sublistView(out);

    view.setUint32(0, total);
    view.setUint32(4, h.length);
    view.setUint32(8, Crc32.of(out, 0, 8));
    out.setRange(12, 12 + h.length, h);
    out.setRange(12 + h.length, total - 4, payload);
    view.setUint32(total - 4, Crc32.of(out, 0, total - 4));
    return out;
  }
}

/// イベントストリームの読み取り。
///
/// WebSocket では通常1フレームに1件ずつ届くが、分割や連結されても
/// 読めるように、足りない分は次の [add] まで持っておく。
class EventStreamDecoder {
  /// これより大きいものは壊れているとみなす。
  /// Transcribe の応答は数 KB なので十分に大きい。
  static const int maxMessageLength = 16 * 1024 * 1024;

  static const int _preludeLength = 12;
  static const int _minMessageLength = _preludeLength + 4;

  Uint8List _pending = Uint8List(0);

  /// 読み切れずに持っているバイト数。
  int get pendingLength => _pending.length;

  /// 受け取ったバイト列を足して、読み切れたメッセージを返す。
  ///
  /// 壊れたデータは [FormatException]。その後の続きは読めないので、
  /// 呼び出し側は接続を切ること。
  List<EventStreamMessage> add(List<int> chunk) {
    if (chunk.isEmpty) return const [];

    if (_pending.isEmpty) {
      _pending = Uint8List.fromList(chunk);
    } else {
      final joined = Uint8List(_pending.length + chunk.length)
        ..setRange(0, _pending.length, _pending)
        ..setRange(_pending.length, _pending.length + chunk.length, chunk);
      _pending = joined;
    }

    final messages = <EventStreamMessage>[];
    var offset = 0;
    while (_pending.length - offset >= _preludeLength) {
      final view = ByteData.sublistView(_pending, offset);
      final total = view.getUint32(0);
      _checkPrelude(_pending, offset, total);
      if (_pending.length - offset < total) break;

      messages.add(decode(Uint8List.sublistView(_pending, offset, offset + total)));
      offset += total;
    }

    _pending = offset == 0
        ? _pending
        : Uint8List.fromList(Uint8List.sublistView(_pending, offset));
    return messages;
  }

  /// 持っている途中のデータを捨てる。
  void reset() => _pending = Uint8List(0);

  /// ちょうど1件分のバイト列を読む。
  static EventStreamMessage decode(Uint8List bytes) {
    if (bytes.length < _minMessageLength) {
      throw const FormatException('イベントストリームが短すぎます');
    }
    final view = ByteData.sublistView(bytes);
    final total = view.getUint32(0);
    final headersLength = view.getUint32(4);

    _checkPrelude(bytes, 0, total);
    if (total != bytes.length) {
      throw const FormatException('イベントストリームの長さが一致しません');
    }
    if (_preludeLength + headersLength + 4 > total) {
      throw const FormatException('ヘッダの長さが不正です');
    }
    if (view.getUint32(total - 4) != Crc32.of(bytes, 0, total - 4)) {
      throw const FormatException('イベントストリームの CRC が一致しません');
    }

    final headersEnd = _preludeLength + headersLength;
    final headers = _readHeaders(bytes, _preludeLength, headersEnd);
    final payload = Uint8List.fromList(
      Uint8List.sublistView(bytes, headersEnd, total - 4),
    );
    return EventStreamMessage(headers: headers, payload: payload);
  }

  static void _checkPrelude(Uint8List bytes, int offset, int total) {
    if (total < _minMessageLength || total > maxMessageLength) {
      throw FormatException('イベントストリームの長さが不正です: $total');
    }
    final view = ByteData.sublistView(bytes, offset);
    if (view.getUint32(8) != Crc32.of(bytes, offset, offset + 8)) {
      throw const FormatException('イベントストリームの prelude CRC が一致しません');
    }
  }

  static Map<String, Object> _readHeaders(Uint8List bytes, int start, int end) {
    final view = ByteData.sublistView(bytes);
    final headers = <String, Object>{};
    var p = start;

    void need(int n) {
      if (p + n > end) {
        throw const FormatException('ヘッダが途中で切れています');
      }
    }

    while (p < end) {
      need(1);
      final nameLength = bytes[p++];
      need(nameLength);
      final name = utf8.decode(Uint8List.sublistView(bytes, p, p + nameLength));
      p += nameLength;

      need(1);
      final type = bytes[p++];
      final Object value;
      switch (type) {
        case 0:
          value = true;
        case 1:
          value = false;
        case 2:
          need(1);
          value = view.getInt8(p);
          p += 1;
        case 3:
          need(2);
          value = view.getInt16(p);
          p += 2;
        case 4:
          need(4);
          value = view.getInt32(p);
          p += 4;
        case 5:
          need(8);
          value = view.getInt64(p);
          p += 8;
        case 6:
          need(2);
          final length = view.getUint16(p);
          p += 2;
          need(length);
          value = Uint8List.fromList(Uint8List.sublistView(bytes, p, p + length));
          p += length;
        case 7:
          need(2);
          final length = view.getUint16(p);
          p += 2;
          need(length);
          value = utf8.decode(Uint8List.sublistView(bytes, p, p + length));
          p += length;
        case 8:
          need(8);
          value = DateTime.fromMillisecondsSinceEpoch(
            view.getInt64(p),
            isUtc: true,
          );
          p += 8;
        case 9:
          need(16);
          value = Uint8List.sublistView(bytes, p, p + 16)
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          p += 16;
        default:
          throw FormatException('未知のヘッダ型です: $type');
      }
      headers[name] = value;
    }
    return headers;
  }
}
