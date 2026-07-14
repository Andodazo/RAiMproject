/// RAiM クライアント側で使う接続・認証設定です。
///
/// ここに置いている値は、Flutter アプリが直接利用してよい公開設定だけです。
/// API Gateway API Key、AWS Secret、Bedrock/Mantle の API Key などの秘密情報は
/// 絶対にクライアントへ持たせません。
class RaimConfig {
  /// Cognito Managed Login のドメイン。
  static const String cognitoDomain =
      'https://ap-northeast-1omfv9fgsg.auth.ap-northeast-1.amazoncognito.com';

  /// Cognito App Client ID。
  ///
  /// Flutter は公開クライアントなので、この App Client は Client Secret なしで
  /// 作成されている必要があります。
  static const String clientId = '3s1n1qe8vlsihh2j2dlcs4ecf5';

  /// Cognito ログイン後にアプリへ戻るための Deep Link。
  static const String redirectUri = 'raim://callback';

  /// Windows デスクトップ検証で使うローカルcallback URL。
  ///
  /// Google OAuth は埋め込み WebView で完走できないことがあるため、Windows では既定ブラウザで
  /// 認証し、このURLをアプリ内の一時HTTPサーバーで受け取ります。
  static const String windowsRedirectUri = 'http://localhost:3000/callback';

  /// Cognito へ要求する scope。
  static const String scope = 'openid email phone';
}
