// lib/services/aws/cognito_credentials_provider.dart
//
// Cognito Identity Pool から AWS の一時認証情報を受け取る。
//
// User Pool の ID トークンを渡すと、Identity Pool の「認証済みロール」の
// 権限を持った一時認証情報（約1時間有効）が返る。
// 端末に長期のアクセスキーを置かずに、S3 や Transcribe を直接呼べる。
//
//   ID トークン → GetId → IdentityId
//   ID トークン + IdentityId → GetCredentialsForIdentity → 一時認証情報
//
// 【使い回し】
// 以前は S3 にアップロードするたびに2往復していた。Transcribe は
// 話しかけるたびに使うので、失効の5分前までは同じものを使い回す。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:raim_prototype/config/raim_config.dart';
import 'package:raim_prototype/services/aws/aws_sigv4.dart';
import 'package:raim_prototype/services/raim_log.dart';

class CognitoCredentialsProvider {
  CognitoCredentialsProvider({
    http.Client? httpClient,
    DateTime Function()? clock,
  })  : _http = httpClient ?? http.Client(),
        // 失効時刻は AWS 側の時刻で返るので、比べる側も AWS に合わせる。
        // 端末の時計が進んでいると、まだ使えるものを捨て続けることになる。
        _clock = clock ?? AwsClock.now;

  /// アプリ全体で1つ使う。キャッシュを共有するため。
  static final CognitoCredentialsProvider instance =
      CognitoCredentialsProvider();

  static const Duration _timeout = Duration(seconds: 20);

  /// 失効までこの時間を切っていたら取り直す。
  static const Duration refreshMargin = Duration(minutes: 5);

  final http.Client _http;
  final DateTime Function() _clock;

  AwsCredentials? _cached;
  String? _cachedForToken;

  /// 取得中のもの。同時に呼ばれても Cognito へは1回だけ問い合わせる。
  Future<AwsCredentials>? _inFlight;

  /// [_inFlight] をどの ID トークンで取りに行っているか。
  String? _inFlightToken;

  /// [clear] のたびに増える。
  ///
  /// 取得中に clear（ログアウト）されたとき、あとから届いた認証情報を
  /// キャッシュに入れないために使う。
  int _generation = 0;

  /// 一時認証情報を返す。
  ///
  /// [idToken] が前回と違う（別のユーザーでログインし直した）場合は
  /// キャッシュを使わない。
  Future<AwsCredentials> getCredentials(String idToken) {
    if (idToken.trim().isEmpty) {
      return Future.error(
        const FormatException('AWS の認証情報の取得には ID トークンが必要です。'),
      );
    }

    final cached = _cached;
    if (cached != null &&
        _cachedForToken == idToken &&
        !cached.expiresWithin(refreshMargin, now: _clock())) {
      return Future.value(cached);
    }

    // 取得中のものは、同じ ID トークンで取りに行っているときだけ使う。
    // 以前はトークンを見ておらず、ログインし直した直後に
    // 前のユーザーの認証情報を受け取ることがあった。
    final inFlight = _inFlight;
    if (inFlight != null && _inFlightToken == idToken) return inFlight;

    final generation = _generation;
    late final Future<AwsCredentials> future;
    future = _fetch(idToken).then((credentials) {
      if (generation == _generation) {
        _cached = credentials;
        _cachedForToken = idToken;
      }
      return credentials;
    }).whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
        _inFlightToken = null;
      }
    });
    _inFlight = future;
    _inFlightToken = idToken;
    return future;
  }

  /// キャッシュを捨てる。ログアウト時や、AWS に権限エラーで弾かれたときに呼ぶ。
  void clear() {
    _generation++;
    _cached = null;
    _cachedForToken = null;
    _inFlight = null;
    _inFlightToken = null;
  }

  Future<AwsCredentials> _fetch(String idToken) async {
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
    final identityId = getId['IdentityId'];
    if (identityId is! String || identityId.isEmpty) {
      throw const FormatException('Cognito Identity ID を取得できませんでした。');
    }

    final response = await _identityRequest(
      target: 'GetCredentialsForIdentity',
      body: {
        'IdentityId': identityId,
        'Logins': logins,
      },
    );
    final raw = response['Credentials'];
    if (raw is! Map) {
      throw const FormatException('一時 AWS 認証情報を取得できませんでした。');
    }

    final accessKeyId = raw['AccessKeyId'];
    final secretKey = raw['SecretKey'];
    final sessionToken = raw['SessionToken'];
    if (accessKeyId is! String ||
        secretKey is! String ||
        sessionToken is! String ||
        accessKeyId.isEmpty ||
        secretKey.isEmpty ||
        sessionToken.isEmpty) {
      throw const FormatException('一時 AWS 認証情報の形式が不正です。');
    }

    return AwsCredentials(
      accessKeyId: accessKeyId,
      secretKey: secretKey,
      sessionToken: sessionToken,
      expiration: _parseExpiration(raw['Expiration']),
    );
  }

  /// Cognito の Expiration は UNIX 秒（小数あり）で返る。
  DateTime? _parseExpiration(Object? value) {
    if (value is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (value * 1000).round(),
      isUtc: true,
    );
  }

  Future<Map<String, dynamic>> _identityRequest({
    required String target,
    required Map<String, dynamic> body,
  }) async {
    final response = await _http
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

    // Cognito Identity の GetId / GetCredentialsForIdentity は署名が要らない。
    // 端末の時計が狂っていても通るので、ここで AWS との時刻のずれを覚えて
    // S3 や Transcribe の署名に使う。
    AwsClock.calibrateFromHttpDate(response.headers['date']);

    if (response.statusCode != 200) {
      // 何が起きたかはエラーの種類で分かる（NotAuthorizedException なら
      // ID トークンの期限切れや Identity Pool の設定違い、など）。
      // 以前はステータスコードしか出しておらず、原因を追えなかった。
      final error = _awsJsonError(response.body);
      RaimLog.e(
        '[CognitoCredentials] $target に失敗しました: '
        '${response.statusCode} ${error.type}',
      );
      // 説明文はトークンの一部やプールの ID を含むことがあるので debug のみ
      if (error.message.isNotEmpty) {
        RaimLog.d('[CognitoCredentials] ${error.message}');
      }
      throw Exception('AWS の認証情報を取得できませんでした。');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('Cognito Identity の応答を解釈できませんでした。');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  /// AWS の JSON 形式のエラー（`{"__type": "...", "message": "..."}`）を読む。
  static ({String type, String message}) _awsJsonError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        // __type は "com.amazonaws...#NotAuthorizedException" の形で
        // 来ることもあるので、# より後ろだけにする。
        final rawType = decoded['__type']?.toString() ?? '';
        final type = rawType.contains('#')
            ? rawType.substring(rawType.lastIndexOf('#') + 1)
            : rawType;
        final message =
            (decoded['message'] ?? decoded['Message'])?.toString() ?? '';
        return (type: type.isEmpty ? 'UnknownError' : type, message: message);
      }
    } catch (_) {
      // JSON でなければ種類は分からない
    }
    return (type: 'UnknownError', message: '');
  }
}
