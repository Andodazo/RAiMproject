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

  // ------------------------------------------------------------
  // RAiM サーバーの接続先
  // ------------------------------------------------------------
  //
  // 以前は main.dart / chat_input.dart / windows_input_window.dart の
  // 3箇所に同じ URL がハードコードされていた。片方だけ直して食い違う事故を
  // 避けるため、ここ1箇所に集約する。
  //
  // ビルド時に上書きできる:
  //   flutter run --dart-define=RAIM_SERVER_URL=ws://127.0.0.1:8080

  /// 既定の接続先（AWS）。
  static const String serverUrl = String.fromEnvironment(
    'RAIM_SERVER_URL',
    defaultValue: 'wss://d1403ont6098ah.cloudfront.net/dev',
  );

  /// 開発検証用のローカル/Tailscale 接続先。
  ///
  /// 接続先切り替えメニューは開発中だけの機能なので、
  /// 配布ビルドでは [enableServerSwitch] を false にして隠す。
  static const String localServerUrl = String.fromEnvironment(
    'RAIM_LOCAL_SERVER_URL',
    defaultValue: 'ws://100.81.35.109:8080',
  );

  /// 接続先切り替え UI を出すか。
  static const bool enableServerSwitch = bool.fromEnvironment(
    'RAIM_ENABLE_SERVER_SWITCH',
    defaultValue: true,
  );

  /// 接続先が AWS かどうか（Authorization ヘッダの付与判定に使う）。
  static bool isAwsUrl(String url) => url.contains('cloudfront.net');
}
