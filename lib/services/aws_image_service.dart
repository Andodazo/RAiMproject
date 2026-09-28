import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:raim_prototype/config/raim_config.dart';
import 'package:raim_prototype/models/image_attachment.dart';
import 'package:raim_prototype/services/aws/aws_sigv4.dart';
import 'package:raim_prototype/services/aws/cognito_credentials_provider.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// Cognito Identity Poolの一時認証情報でS3へ画像をアップロードするサービス。
///
/// AWSの長期アクセスキーや秘密情報は保持せず、User PoolのID Tokenから
/// 短期認証情報を取得して、S3 PutObjectだけを実行します。
class AwsImageService {
  AwsImageService({CognitoCredentialsProvider? credentialsProvider})
      : _credentials =
            credentialsProvider ?? CognitoCredentialsProvider.instance;

  static const Duration _timeout = Duration(seconds: 20);

  /// Identity Pool の一時認証情報。Transcribe と共有してキャッシュする。
  final CognitoCredentialsProvider _credentials;

  Future<void> cleanupPendingImages(Iterable<PendingImage> images) async {
    for (final image in images) {
      await _deleteTemporaryFile(image.uploadPath);
    }
  }

  Future<List<UploadedImage>> uploadImages({
    required String idToken,
    required List<PendingImage> images,
    required String userSub,
    required String requestId,
  }) async {
    if (images.isEmpty) return const [];
    if (images.length > RaimConfig.maxImageCount) {
      throw const FormatException('画像は10枚まで添付できます。');
    }

    final credentials = await _credentials.getCredentials(idToken);
    final uploaded = <UploadedImage>[];

    try {
      for (var index = 0; index < images.length; index++) {
        final image = images[index];
        final imageId = 'image-$index';
        final key = _createImageKey(
          userSub: userSub,
          requestId: requestId,
          imageId: imageId,
          extension: image.extension,
        );

        await _putObject(
          credentials: credentials,
          key: key,
          image: image,
        );
        uploaded.add(UploadedImage(
          key: key,
          contentType: image.contentType,
          sizeBytes: image.sizeBytes,
        ));
      }
      return uploaded;
    } finally {
      // 圧縮済みの一時ファイルはS3への送信後に削除する。
      await cleanupPendingImages(images);
    }
  }

  Future<void> _putObject({
    required AwsCredentials credentials,
    required String key,
    required PendingImage image,
  }) async {
    final bytes = await _readFile(image.uploadPath);
    if (bytes.length != image.sizeBytes) {
      throw const FormatException('アップロード対象画像のサイズが一致しません。');
    }

    var response = await _signedPut(
      credentials: credentials,
      key: key,
      image: image,
      bytes: bytes,
    );

    // 端末の時計が15分以上ずれていると、S3 は署名を拒否する。
    // 応答に S3 側の時刻が入っているので、それに合わせて1回だけ送り直す。
    if (response.statusCode == 403 &&
        _s3Error(response.body).code == 'RequestTimeTooSkewed') {
      final serverTime = _s3ServerTime(response.body);
      if (serverTime != null) {
        AwsClock.calibrate(serverTime);
      } else {
        AwsClock.calibrateFromHttpDate(response.headers['date']);
      }
      RaimLog.w('[AwsImageService] 端末の時計がずれていたため送り直します');
      response = await _signedPut(
        credentials: credentials,
        key: key,
        image: image,
        bytes: bytes,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      // S3 はエラーの理由を XML の本文で返す。
      //   SignatureDoesNotMatch … 署名の組み立て違い
      //   AccessDenied          … Identity Pool のロールに権限が無い
      //   RequestTimeTooSkewed  … 端末の時計のずれ
      //   ExpiredToken          … 一時認証情報の期限切れ
      // 以前はステータスコードしか出しておらず、どれなのか分からなかった。
      final error = _s3Error(response.body);
      RaimLog.e(
        '[AwsImageService] S3 PutObject failed: '
        '${response.statusCode} ${error.code}',
      );
      // 説明文にはロールの ARN（アカウント ID 入り）が含まれることがあるので
      // debug のみ。画像の中身や認証情報は含まれない。
      if (error.message.isNotEmpty) {
        RaimLog.d('[AwsImageService] ${error.message}');
      }
      // 権限エラーなら使い回している認証情報が古い可能性がある。
      // 次回は取り直す。
      if (response.statusCode == 403) _credentials.clear();
      throw Exception('画像をS3へアップロードできませんでした。');
    }
  }

  Future<http.Response> _signedPut({
    required AwsCredentials credentials,
    required String key,
    required PendingImage image,
    required Uint8List bytes,
  }) {
    final host = '${RaimConfig.imageBucketName}.s3.${RaimConfig.imageBucketRegion}.amazonaws.com';
    final canonicalUri = '/${AwsSigV4.uriEncodePath(key)}';
    final payloadHash = sha256.convert(bytes).toString();
    // 端末の時計ではなく、AWS に合わせて補正した時刻で署名する
    final now = AwsClock.now();
    final amzDate = AwsSigV4.amzDate(now);
    final date = amzDate.substring(0, 8);
    final canonicalHeaders =
        'content-type:${image.contentType}\n'
        'host:$host\n'
        'x-amz-content-sha256:$payloadHash\n'
        'x-amz-date:$amzDate\n'
        'x-amz-security-token:${credentials.sessionToken}\n';
    const signedHeaders =
        'content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token';
    final canonicalRequest = [
      'PUT',
      canonicalUri,
      '',
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');
    final credentialScope =
        '$date/${RaimConfig.imageBucketRegion}/s3/aws4_request';
    final stringToSign = [
      AwsSigV4.algorithm,
      amzDate,
      credentialScope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');
    final signingKey = AwsSigV4.signingKey(
      secretKey: credentials.secretKey,
      date: date,
      region: RaimConfig.imageBucketRegion,
      service: 's3',
    );
    final signature = AwsSigV4.sign(signingKey, stringToSign);

    return http
        .put(
          // canonicalUriは署名にも使ったエンコード済みパスなので、
          // Uri.httpsで再エンコードしない。
          Uri.parse('https://$host$canonicalUri'),
          headers: {
            'Content-Type': image.contentType,
            'Host': host,
            'X-Amz-Content-Sha256': payloadHash,
            'X-Amz-Date': amzDate,
            'X-Amz-Security-Token': credentials.sessionToken,
            'Authorization':
                'AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature',
          },
          body: bytes,
        )
        .timeout(_timeout);
  }

  /// S3 のエラー XML から Code と Message を取り出す。
  ///
  /// SignatureDoesNotMatch の本文には StringToSign や CanonicalRequest も
  /// 入っているが、それらは取り出さない（ログに出さない）。
  static ({String code, String message}) _s3Error(String body) {
    String? tag(String name) =>
        RegExp('<$name>([^<]*)</$name>').firstMatch(body)?.group(1);
    return (
      code: tag('Code') ?? 'UnknownError',
      message: tag('Message') ?? '',
    );
  }

  /// RequestTimeTooSkewed の本文にある S3 側の時刻。
  static DateTime? _s3ServerTime(String body) {
    final raw = RegExp('<ServerTime>([^<]*)</ServerTime>').firstMatch(body)?.group(1);
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  String _createImageKey({
    required String userSub,
    required String requestId,
    required String imageId,
    required String extension,
  }) {
    _validatePathPart(userSub, 'sub');
    _validatePathPart(requestId, 'requestId');
    _validatePathPart(imageId, 'imageId');
    _validatePathPart(extension, 'extension');
    return 'temporary/users/$userSub/$requestId/$imageId.$extension';
  }

  void _validatePathPart(String value, String name) {
    if (value.isEmpty ||
        value.contains('/') ||
        value.contains('\\') ||
        value.contains('..') ||
        value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw FormatException('$nameの形式が不正です。');
    }
  }

  Future<Uint8List> _readFile(String path) async {
    return Uint8List.fromList(await File(path).readAsBytes());
  }

  Future<void> _deleteTemporaryFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 一時ファイル削除失敗はアップロード結果を覆さない。
    }
  }
}
