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

    final host = '${RaimConfig.imageBucketName}.s3.${RaimConfig.imageBucketRegion}.amazonaws.com';
    final canonicalUri = '/${AwsSigV4.uriEncodePath(key)}';
    final payloadHash = sha256.convert(bytes).toString();
    final now = DateTime.now().toUtc();
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

    final response = await http
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

    if (response.statusCode < 200 || response.statusCode >= 300) {
      RaimLog.e('[AwsImageService] S3 PutObject failed: ${response.statusCode}');
      // 権限エラーなら使い回している認証情報が古い可能性がある。
      // 次回は取り直す。
      if (response.statusCode == 403) _credentials.clear();
      throw Exception('画像をS3へアップロードできませんでした。');
    }
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
