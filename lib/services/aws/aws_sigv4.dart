// lib/services/aws/aws_sigv4.dart
//
// AWS Signature Version 4 の署名に使う共通部品。
//
// 【なぜ自前で持つか】
// 以前は AwsImageService（S3 アップロード）の中にだけあった。
// Transcribe のストリーミングも同じ署名方式を使うため、ここへ切り出して
// 両方から使う。署名の手順は1か所で持つ方が、片方だけ直して
// 食い違う事故が起きない。
//
// 公式の手順:
// https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
//
// 【注意】
// ここに渡す認証情報（シークレットキー、セッショントークン）は
// ログに出さないこと。RaimLog にも渡さない。

import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:raim_prototype/services/raim_log.dart';

/// AWS 側の時刻に合わせた「今」。
///
/// 【なぜ要るか】
/// SigV4 の署名には端末の時刻が入る。AWS は自分の時刻と15分以上
/// ずれた署名を拒否する（S3 は RequestTimeTooSkewed の 403）。
/// PC の時計が狂っていると、画像のアップロードも Transcribe への接続も
/// 全部失敗し、しかも原因が分かりにくい。
///
/// AWS の応答には Date ヘッダが付くので、そこから端末とのずれを覚えて、
/// 署名に使う時刻を補正する。Cognito Identity への問い合わせは署名が
/// 要らず時計が狂っていても通るので、認証情報を取るたびに補正できる。
class AwsClock {
  AwsClock._();

  /// これより小さいずれは無視する。
  ///
  /// Date ヘッダは秒単位で、通信の往復ぶん遅れて届く。AWS は15分まで
  /// 許すので、1分程度のずれを追いかける必要はない。
  static const Duration tolerance = Duration(minutes: 1);

  static Duration _offset = Duration.zero;

  /// 端末の時計に足している補正。
  static Duration get offset => _offset;

  /// 補正済みの現在時刻（UTC）。
  static DateTime now() => DateTime.now().toUtc().add(_offset);

  /// HTTP の Date ヘッダ（`Tue, 29 Sep 2026 01:23:45 GMT`）から補正する。
  static void calibrateFromHttpDate(String? value, {DateTime? localNow}) {
    if (value == null || value.isEmpty) return;
    final DateTime server;
    try {
      server = HttpDate.parse(value);
    } catch (_) {
      return;
    }
    calibrate(server, localNow: localNow);
  }

  /// AWS 側の時刻 [server] から補正する。
  static void calibrate(DateTime server, {DateTime? localNow}) {
    final local = (localNow ?? DateTime.now()).toUtc();
    final diff = server.toUtc().difference(local);
    final next = diff.abs() < tolerance ? Duration.zero : diff;
    if (next == _offset) return;

    // 1秒単位の揺れで毎回ログが出ないよう、変わったときだけ出す
    if ((next - _offset).abs() >= tolerance || next == Duration.zero) {
      RaimLog.w(
        next == Duration.zero
            ? '[AwsClock] 端末の時計のずれが解消しました'
            : '[AwsClock] 端末の時計が AWS と ${next.inSeconds} 秒ずれています。'
                '署名の時刻を補正します',
      );
    }
    _offset = next;
  }

  @visibleForTesting
  static void reset() => _offset = Duration.zero;
}

/// Cognito Identity Pool から受け取る一時認証情報。
///
/// 有効期限はおおむね1時間。期限の少し前に取り直す。
class AwsCredentials {
  const AwsCredentials({
    required this.accessKeyId,
    required this.secretKey,
    required this.sessionToken,
    this.expiration,
  });

  final String accessKeyId;
  final String secretKey;
  final String sessionToken;

  /// 失効時刻（UTC）。不明なら null。
  final DateTime? expiration;

  /// [margin] 以内に失効するなら true。
  ///
  /// 取り出してから実際に使うまでに少し時間がかかるので、
  /// ぎりぎりのものは使わず取り直す。
  bool expiresWithin(Duration margin, {DateTime? now}) {
    final exp = expiration;
    if (exp == null) return false;
    return !(now ?? AwsClock.now()).add(margin).isBefore(exp);
  }

  /// 認証情報が文字列に出ないようにする（ログへの出力事故の防止）。
  @override
  String toString() => 'AwsCredentials(***)';
}

/// SigV4 の署名で使う関数をまとめたもの。
class AwsSigV4 {
  AwsSigV4._();

  static const String algorithm = 'AWS4-HMAC-SHA256';

  /// 空文字列の SHA-256。本文が無いリクエストの payload hash に使う。
  static final String emptyPayloadHash = sha256.convert(const []).toString();

  /// `20260928T123456Z` の形式。
  static String amzDate(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    final t = utc.toUtc();
    return '${t.year.toString().padLeft(4, '0')}${two(t.month)}'
        '${two(t.day)}T${two(t.hour)}${two(t.minute)}'
        '${two(t.second)}Z';
  }

  /// 署名用の鍵を作る。
  ///
  /// 日付・リージョン・サービスごとに鍵が変わるので、
  /// S3 と Transcribe で同じシークレットから別の鍵になる。
  static List<int> signingKey({
    required String secretKey,
    required String date,
    required String region,
    required String service,
  }) {
    final kDate = Hmac(sha256, utf8.encode('AWS4$secretKey'))
        .convert(utf8.encode(date))
        .bytes;
    final kRegion = Hmac(sha256, kDate).convert(utf8.encode(region)).bytes;
    final kService = Hmac(sha256, kRegion).convert(utf8.encode(service)).bytes;
    return Hmac(sha256, kService).convert(utf8.encode('aws4_request')).bytes;
  }

  /// 署名を計算する（16進文字列）。
  static String sign(List<int> signingKey, String stringToSign) =>
      Hmac(sha256, signingKey).convert(utf8.encode(stringToSign)).toString();

  static String hashHex(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// AWS の規則に沿った URI エンコード。
  ///
  /// Dart の Uri.encodeComponent は `!` `'` `(` `)` `*` をエンコードしないが、
  /// AWS は英数字と `-` `.` `_` `~` 以外をすべてエンコードする必要がある。
  /// 1文字でも食い違うと署名が一致しない。
  static String uriEncode(String value) {
    final bytes = utf8.encode(value);
    final buffer = StringBuffer();
    const hex = '0123456789ABCDEF';
    for (final byte in bytes) {
      final isUnreserved = (byte >= 0x41 && byte <= 0x5a) ||
          (byte >= 0x61 && byte <= 0x7a) ||
          (byte >= 0x30 && byte <= 0x39) ||
          byte == 0x2d ||
          byte == 0x2e ||
          byte == 0x5f ||
          byte == 0x7e;
      if (isUnreserved) {
        buffer.writeCharCode(byte);
      } else {
        buffer.write('%${hex[byte >> 4]}${hex[byte & 0x0f]}');
      }
    }
    return buffer.toString();
  }

  /// パスをエンコードする。`/` は区切りとして残す。
  static String uriEncodePath(String value) =>
      value.split('/').map(uriEncode).join('/');

  /// クエリ文字列を AWS の正規形にする（キーの昇順、両方エンコード）。
  static String canonicalQuery(Map<String, String> params) {
    final keys = params.keys.toList()..sort();
    return keys
        .map((k) => '${uriEncode(k)}=${uriEncode(params[k]!)}')
        .join('&');
  }

  /// 署名をクエリ文字列に入れた URL（署名付き URL）を作る。
  ///
  /// Transcribe の WebSocket はヘッダを付けられないため、この形で接続する。
  /// 署名するヘッダは host だけ。
  ///
  /// [host] にはポートも含めること（`example.com:8443`）。
  /// 接続時に送られる Host ヘッダとずれると署名が一致しない。
  static Uri presign({
    required String scheme,
    required String host,
    required String path,
    required String region,
    required String service,
    required AwsCredentials credentials,
    required Map<String, String> query,
    required Duration expires,
    DateTime? now,
    String payloadHash = '',
  }) {
    final time = (now ?? AwsClock.now()).toUtc();
    final date8601 = amzDate(time);
    final date = date8601.substring(0, 8);
    final scope = '$date/$region/$service/aws4_request';

    // セッショントークンも署名の対象に含める。
    // 一時認証情報では、これが無いと認証情報そのものが不正と判定される。
    final params = <String, String>{
      ...query,
      'X-Amz-Algorithm': algorithm,
      'X-Amz-Credential': '${credentials.accessKeyId}/$scope',
      'X-Amz-Date': date8601,
      'X-Amz-Expires': expires.inSeconds.toString(),
      'X-Amz-Security-Token': credentials.sessionToken,
      'X-Amz-SignedHeaders': 'host',
    };

    final canonicalRequest = [
      'GET',
      path,
      canonicalQuery(params),
      'host:$host\n',
      'host',
      payloadHash.isEmpty ? emptyPayloadHash : payloadHash,
    ].join('\n');

    final stringToSign = [
      algorithm,
      date8601,
      scope,
      hashHex(canonicalRequest),
    ].join('\n');

    final key = signingKey(
      secretKey: credentials.secretKey,
      date: date,
      region: region,
      service: service,
    );
    final signature = sign(key, stringToSign);

    // Uri(queryParameters:) に渡すと Dart 側で別の規則でエンコードし直され、
    // 署名した文字列と実際に送る文字列がずれる。組み立て済みの文字列を使う。
    return Uri.parse(
      '$scheme://$host$path?${canonicalQuery(params)}'
      '&X-Amz-Signature=$signature',
    );
  }
}
