/// RAiM クライアント側で使う接続・認証設定です。
///
/// ここに置いている値は、Flutter アプリが直接利用してよい公開設定だけです。
/// API Gateway API Key、AWS Secret、Bedrock/Mantle の API Key などの秘密情報は
/// 絶対にクライアントへ持たせません。
class RaimConfig {
  /// Cognito User Pool / Identity Pool / 画像バケットのリージョン。
  static const String cognitoRegion = 'ap-northeast-1';
  static const String identityPoolRegion = 'ap-northeast-1';
  static const String imageBucketRegion = 'ap-northeast-1';

  /// 既存のCognito User Pool ID。
  static const String userPoolId = 'ap-northeast-1_OMFV9fgsG';

  /// 認証済みユーザー用のCognito Identity Pool。
  static const String identityPoolId =
      'ap-northeast-1:dafca2b0-ea69-4346-b292-3a60e144496d';

  /// 画像アップロード先のS3バケット。
  static const String imageBucketName = 'raim-images-dev-123456789012';

  /// Amazon Transcribe（音声の文字起こし）。
  ///
  /// Identity Pool の認証済みロールに
  /// transcribe:StartStreamTranscriptionWebSocket の権限が必要。
  /// 東京リージョンは日本語のストリーミングに対応している。
  static const String transcribeRegion = 'ap-northeast-1';
  static const String transcribeLanguageCode = 'ja-JP';

  /// 1回に送れる画像の枚数。
  ///
  /// サーバー（Edge Lambda の MAX_IMAGE_COUNT）の既定値と合わせる。
  /// 以前はここが10枚でサーバーが4枚だったため、5枚以上だとアップロードしたあとで
  /// 断られていた。画像は1枚ごとにモデルへの入力が増え、料金も返事の遅さも増えるので4枚にする。
  /// 増やすときは、サーバーの MAX_IMAGE_COUNT も同じ値にすること。
  static const int maxImageCount = 4;

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
  ///
  /// 指定が無いときは、debug / profile では出し、release では出さない。
  /// （tools/release.ps1 を通さない flutter build apk / ipa でも隠れるように）
  static const bool enableServerSwitch = bool.fromEnvironment(
    'RAIM_ENABLE_SERVER_SWITCH',
    defaultValue: !bool.fromEnvironment('dart.vm.product'),
  );

  /// 接続先が AWS かどうか（Authorization ヘッダの付与判定に使う）。
  ///
  /// 以前は URL に 'cloudfront.net' が含まれるかで見ていたため、
  /// 'cloudfront.net.example.com' のような別のホストにもトークンを送り得た。
  /// ホスト名で比べる。
  static bool isAwsUrl(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    final defaultHost = Uri.tryParse(serverUrl)?.host.toLowerCase() ?? '';
    return host == defaultHost || host.endsWith('.cloudfront.net');
  }
}
