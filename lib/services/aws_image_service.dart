import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:raim_prototype/config/raim_config.dart';
import 'package:raim_prototype/models/image_attachment.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// Cognito Identity Poolの一時認証情報でS3へ画像をアップロードするサービス。
///
/// AWSの長期アクセスキーや秘密情報は保持せず、User PoolのID Tokenから
/// 短期認証情報を取得して、S3 PutObjectだけを実行します。
class AwsImageService {
  static const Duration _timeout = Duration(seconds: 20);

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

    final credentials = await _getCredentials(idToken);
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

  Future<_AwsCredentials> _getCredentials(String idToken) async {
    if (idToken.trim().isEmpty) {
      throw const FormatException('画像アップロードにはID Tokenが必要です。');
    }

    final loginProvider =
        'cognito-idp.${RaimConfig.cognitoRegion}.amazonaws.com/${RaimConfig.userPoolId}';
    final logins = <String, String>{loginProvider: idToken};

    final getId = await _identityRequest(
      target: 'GetId',
      body: {
        'IdentityPoolId': RaimConfig.identityPoolId,
        'Logins': logins,
      },
    );
    final identityId = getId['IdentityId'] as String?;
    if (identityId == null || identityId.isEmpty) {
      throw const FormatException('Cognito Identity IDを取得できませんでした。');
    }

    final credentialsResponse = await _identityRequest(
      target: 'GetCredentialsForIdentity',
      body: {
        'IdentityId': identityId,
        'Logins': logins,
      },
    );
    final raw = credentialsResponse['Credentials'];
    if (raw is! Map) {
      throw const FormatException('一時AWS認証情報を取得できませんでした。');
    }

    final accessKeyId = raw['AccessKeyId'] as String?;
    final secretKey = raw['SecretKey'] as String?;
    final sessionToken = raw['SessionToken'] as String?;
    if ([accessKeyId, secretKey, sessionToken].any(
      (value) => value == null || value.isEmpty,
    )) {
      throw const FormatException('一時AWS認証情報の形式が不正です。');
    }

    return _AwsCredentials(
      accessKeyId: accessKeyId!,
      secretKey: secretKey!,
      sessionToken: sessionToken!,
    );
  }

  Future<Map<String, dynamic>> _identityRequest({
    required String target,
    required Map<String, dynamic> body,
  }) async {
    final response = await http
        .post(
          Uri.parse(
            'https://cognito-identity.${RaimConfig.identityPoolRegion}.amazonaws.com/',
          ),
          headers: {
            'Content-Type': 'application/x-amz-json-1.1',
            'X-Amz-Target': 'AWSCognitoIdentityService.$target',
          },
          body: jsonEncode(body),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      RaimLog.e('[AwsImageService] Cognito Identity request failed: $target ${response.statusCode}');
      throw Exception('S3アップロード用の認証情報を取得できませんでした。');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('Cognito Identityの応答を解釈できませんでした。');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<void> _putObject({
    required _AwsCredentials credentials,
    required String key,
    required PendingImage image,
  }) async {
    final bytes = await _readFile(image.uploadPath);
    if (bytes.length != image.sizeBytes) {
      throw const FormatException('アップロード対象画像のサイズが一致しません。');
    }

    final host = '${RaimConfig.imageBucketName}.s3.${RaimConfig.imageBucketRegion}.amazonaws.com';
    final canonicalUri = '/${_uriEncodePath(key)}';
    final payloadHash = sha256.convert(bytes).toString();
    final now = DateTime.now().toUtc();
    final amzDate = _formatAmzDate(now);
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
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');
    final signingKey = _signingKey(
      secretKey: credentials.secretKey,
      date: date,
      region: RaimConfig.imageBucketRegion,
    );
    final signature = Hmac(sha256, signingKey)
        .convert(utf8.encode(stringToSign))
        .toString();

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

  List<int> _signingKey({
    required String secretKey,
    required String date,
    required String region,
  }) {
    final kDate = Hmac(sha256, utf8.encode('AWS4$secretKey'))
        .convert(utf8.encode(date))
        .bytes;
    final kRegion = Hmac(sha256, kDate).convert(utf8.encode(region)).bytes;
    final kService = Hmac(sha256, kRegion).convert(utf8.encode('s3')).bytes;
    return Hmac(sha256, kService)
        .convert(utf8.encode('aws4_request'))
        .bytes;
  }

  String _formatAmzDate(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year.toString().padLeft(4, '0')}${two(value.month)}'
        '${two(value.day)}T${two(value.hour)}${two(value.minute)}'
        '${two(value.second)}Z';
  }

  String _uriEncodePath(String value) => value
      .split('/')
      .map(_uriEncode)
      .join('/');

  String _uriEncode(String value) {
    final bytes = utf8.encode(value);
    final buffer = StringBuffer();
    const hex = '0123456789ABCDEF';
    for (final byte in bytes) {
      final isUnreserved =
          (byte >= 0x41 && byte <= 0x5a) ||
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
}

/// 認証情報は短時間だけ保持し、ログへ出さない。
class _AwsCredentials {
  final String accessKeyId;
  final String secretKey;
  final String sessionToken;

  const _AwsCredentials({
    required this.accessKeyId,
    required this.secretKey,
    required this.sessionToken,
  });
}
