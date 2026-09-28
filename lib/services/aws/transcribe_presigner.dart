// lib/services/aws/transcribe_presigner.dart
//
// Amazon Transcribe のストリーミング（WebSocket）に接続するための
// 署名付き URL を作る。
//
// WebSocket では接続時にヘッダを付けられないため、署名はクエリ文字列に
// 入れる。この URL を持っている人は誰でも Transcribe を呼べてしまうので、
// 有効期限は短くする（既定 60 秒。AWS の上限は 300 秒）。
// 期限は「接続を始めるまで」の期限で、接続後の会話は切れない。
//
// 公式の手順:
// https://docs.aws.amazon.com/transcribe/latest/dg/streaming-websocket.html

import 'package:raim_prototype/config/raim_config.dart';
import 'package:raim_prototype/services/aws/aws_sigv4.dart';

class TranscribePresigner {
  TranscribePresigner._();

  static const String service = 'transcribe';
  static const String path = '/stream-transcription-websocket';

  /// 接続先。ポート 8443 も署名の対象に含まれるので、ここで固定する。
  static String hostFor(String region) =>
      'transcribestreaming.$region.amazonaws.com:8443';

  static Uri presign({
    required AwsCredentials credentials,
    required int sampleRate,
    String region = RaimConfig.transcribeRegion,
    String languageCode = RaimConfig.transcribeLanguageCode,
    Duration expires = const Duration(seconds: 60),
    DateTime? now,
  }) {
    return AwsSigV4.presign(
      scheme: 'wss',
      host: hostFor(region),
      path: path,
      region: region,
      service: service,
      credentials: credentials,
      query: {
        'language-code': languageCode,
        'media-encoding': 'pcm',
        'sample-rate': sampleRate.toString(),
      },
      expires: expires,
      now: now,
    );
  }
}
