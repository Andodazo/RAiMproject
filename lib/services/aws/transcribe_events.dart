// lib/services/aws/transcribe_events.dart
//
// Transcribe のストリーミングでやり取りする中身。
//
// 送るもの:
//   AudioEvent … 16kHz / 16bit / モノラルの PCM をそのまま本文に入れる。
//                本文が空の AudioEvent が「話し終わり」の合図。
//
// 受け取るもの:
//   TranscriptEvent … 文字起こしの途中経過（IsPartial=true）と確定（false）
//   exception       … 権限不足、無音で15秒経過、同時接続数の超過 など
//
// 包み方（イベントストリーム形式）は event_stream.dart が受け持つ。

import 'dart:convert';
import 'dart:typed_data';

import 'package:raim_prototype/services/aws/event_stream.dart';

/// 送る音声を包む。
class TranscribeAudio {
  TranscribeAudio._();

  static const Map<String, String> _audioHeaders = {
    ':content-type': 'application/octet-stream',
    ':event-type': 'AudioEvent',
    ':message-type': 'event',
  };

  /// PCM を1件分の AudioEvent にする。
  ///
  /// 1回に送る量は 50〜200ms 程度が推奨。16kHz / 16bit なら
  /// 100ms = 3200 バイト。
  static Uint8List event(List<int> pcm) =>
      EventStreamEncoder.encode(_audioHeaders, pcm);

  /// 話し終わりの合図（本文が空の AudioEvent）。
  ///
  /// これを送ると Transcribe は残りを確定させて返し、接続を閉じる。
  static Uint8List endOfStream() => event(const []);
}

/// 受け取ったものの種類。
sealed class TranscribeEvent {
  const TranscribeEvent();

  /// 受け取ったメッセージを読む。
  ///
  /// 知らない種類のイベントは null（無視してよい）。
  /// 本文が JSON として読めないときは [FormatException]。
  static TranscribeEvent? parse(EventStreamMessage message) {
    switch (message.messageType) {
      case 'event':
        if (message.stringHeader(':event-type') != 'TranscriptEvent') {
          return null;
        }
        return TranscriptEvent._fromJson(_json(message.payload));

      case 'exception':
        final body = message.payload.isEmpty
            ? const <String, dynamic>{}
            : _json(message.payload);
        return TranscribeFailure(
          type: message.stringHeader(':exception-type') ?? 'UnknownException',
          message: body['Message']?.toString() ?? '',
        );

      case 'error':
        return TranscribeFailure(
          type: message.stringHeader(':error-code') ?? 'UnknownError',
          message: message.stringHeader(':error-message') ?? '',
        );

      default:
        return null;
    }
  }

  static Map<String, dynamic> _json(Uint8List payload) {
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is! Map) {
      throw const FormatException('Transcribe の応答が JSON オブジェクトではありません');
    }
    return decoded.map((k, v) => MapEntry(k.toString(), v));
  }
}

/// 文字起こしの結果。
///
/// 1回の TranscriptEvent に複数の結果が入ることがある。
/// 同じ [TranscriptResult.resultId] の結果は、話している間に
/// 途中経過として何度も届き、最後に確定版が1回届く。
class TranscriptEvent extends TranscribeEvent {
  const TranscriptEvent(this.results);

  final List<TranscriptResult> results;

  factory TranscriptEvent._fromJson(Map<String, dynamic> json) {
    final transcript = json['Transcript'];
    final raw = transcript is Map ? transcript['Results'] : null;
    if (raw is! List) return const TranscriptEvent([]);

    return TranscriptEvent([
      for (final r in raw)
        if (r is Map) TranscriptResult._fromJson(r),
    ]);
  }
}

class TranscriptResult {
  const TranscriptResult({
    required this.resultId,
    required this.text,
    required this.isPartial,
    required this.startTime,
    required this.endTime,
  });

  final String resultId;

  /// 最も確からしい候補の文字列。候補が無ければ空。
  final String text;

  /// true なら途中経過（あとで書き換わる）。
  final bool isPartial;

  /// 接続してからの秒数。
  final double startTime;
  final double endTime;

  factory TranscriptResult._fromJson(Map<dynamic, dynamic> json) {
    final alternatives = json['Alternatives'];
    var text = '';
    if (alternatives is List && alternatives.isNotEmpty) {
      final first = alternatives.first;
      if (first is Map) text = first['Transcript']?.toString() ?? '';
    }

    double seconds(Object? v) => v is num ? v.toDouble() : 0.0;

    return TranscriptResult(
      resultId: json['ResultId']?.toString() ?? '',
      text: text,
      isPartial: json['IsPartial'] == true,
      startTime: seconds(json['StartTime']),
      endTime: seconds(json['EndTime']),
    );
  }

  @override
  String toString() =>
      'TranscriptResult($resultId, partial=$isPartial, ${text.length}文字)';
}

/// Transcribe から返ったエラー。
///
/// 主な [type]:
/// - BadRequestException … 形式の誤り、または15秒間音声が届かなかった
/// - LimitExceededException … 同時接続数や時間の上限
/// - InternalFailureException / ServiceUnavailableException … AWS 側の一時的な問題
class TranscribeFailure extends TranscribeEvent implements Exception {
  const TranscribeFailure({required this.type, required this.message});

  final String type;
  final String message;

  /// 少し待てば直る可能性があるもの。
  bool get isTransient =>
      type == 'InternalFailureException' ||
      type == 'ServiceUnavailableException' ||
      type == 'LimitExceededException';

  @override
  String toString() => 'TranscribeFailure($type: $message)';
}
