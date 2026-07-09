# RAiMproject ローカル変更まとめ

このファイルは、`RAiMproject` をクローンした時点から、このワークスペース内で加えたローカル変更をまとめるための台帳です。

このワークスペースは `raim_aws` 側で作成した Edge / Cognito 連携を Flutter クライアント側で検証し、担当者へ説明しやすくするためのものです。今後は認証以外の検証・UI調整・接続検証も増える想定なので、ファイル名は `LOCAL_CHANGES.md` とし、内容を項目別に整理します。

今後このワークスペースで構成や処理を更新した場合は、実装ファイルだけでなく、このファイルも一緒に更新してください。

## 変更方針

- このワークスペースの変更は、基本的に main へ push しないローカル検証変更として扱う。
- クライアント側に Cognito 連携の検証処理を追加する。
- 秘密情報はクライアントに持たせず、公開可能な Cognito App Client ID のみを設定する。
- Windows デスクトップでの検証を主対象にする。
- 認証以外の検証項目も、このファイルへ項目を増やして追記する。

## 認証

### 起動時認証

起動時に保存済みTokenを確認し、未認証ならCognito認証へ進むようにしました。

主な対象ファイル:

- `lib/main.dart`
- `lib/screens/splash_screen.dart`
- `lib/screens/login_screen.dart`
- `lib/providers/auth_provider.dart`
- `lib/services/auth_service.dart`
- `lib/services/token_storage.dart`
- `lib/models/auth_tokens.dart`

処理概要:

1. `SplashScreen` 起動
2. `AuthProvider.initialize()` を実行
3. `AuthService.loadValidTokens()` で保存済みTokenを確認
4. Tokenが有効なら `ChatScreen` へ進む
5. Tokenがない、またはRefresh不可なら `LoginScreen` へ進む

### Cognito / PKCE 認証

Cognito Managed Login と Authorization Code + PKCE の処理を追加しました。

主な対象ファイル:

- `lib/config/raim_config.dart`
- `lib/services/auth_service.dart`
- `lib/services/token_storage.dart`
- `lib/models/auth_tokens.dart`

設定している主な値:

- Cognito Domain
- Cognito App Client ID
- `raim://callback`
- Windows検証用 `http://localhost:3000/callback`
- Scope: `openid email phone`

Token保存:

- `flutter_secure_storage` を使用
- Access Token / ID Token / Refresh Token / 有効期限を保存
- PKCE の `code_verifier` と `state` は認証中だけ一時保存

### Windows用 localhost callback

Windowsでは `raim://callback` のOSプロトコル登録に頼らず、`http://localhost:3000/callback` をアプリ内の一時HTTPサーバーで受け取るようにしました。

主な対象ファイル:

- `lib/services/local_callback_server.dart`
- `lib/services/local_callback_server_io.dart`
- `lib/services/local_callback_server_stub.dart`
- `lib/services/auth_service.dart`

処理概要:

1. 認証開始前に `localhost:3000` で待ち受け開始
2. Cognito の `redirect_uri` に `http://localhost:3000/callback` を指定
3. ChromeでCognito / Google認証
4. callbackで受け取った `code` と `state` を検証
5. Token endpointへ交換リクエスト
6. Token保存後、チャット画面へ進む

### 認証用Chromeの枠無しフルスクリーン起動

Google OAuth がWebViewで止まる問題を避けるため、Windowsでは外部Chromeをkioskモードで起動するようにしました。

主な対象ファイル:

- `lib/services/browser_login_launcher.dart`
- `lib/services/browser_login_launcher_io.dart`
- `lib/services/browser_login_launcher_stub.dart`
- `lib/services/auth_service.dart`

Windowsでの起動方式:

- Chrome executable:
  - `C:\Program Files\Google\Chrome\Application\chrome.exe`
  - fallback: `C:\Program Files (x86)\Google\Chrome\Application\chrome.exe`
- 起動オプション:
  - `--kiosk`
  - `--user-data-dir=%LOCALAPPDATA%\RAiM\auth_chrome_profile`
  - `--lang=ja-JP`
  - `--accept-lang=ja-JP,ja`
  - `--no-first-run`
  - `--disable-translate`
  - `--disable-features=Translate`

補足:

- 認証完了後、callbackを受け取ったタイミングで、アプリから起動したChromeプロセスを閉じます。
- Chromeの通常利用プロファイルと分けるため、RAiM認証専用プロファイルを使っています。
- Cognito認証URLには `lang=ja` と `ui_locales=ja` を付け、認証画面を日本語表示へ寄せています。

### 認証後のアプリ前面復帰

ブラウザ認証後にRAiMアプリへ戻りやすくするため、Windowsネイティブ側にMethodChannelを追加しました。

主な対象ファイル:

- `lib/services/app_window_service.dart`
- `lib/providers/auth_provider.dart`
- `windows/runner/flutter_window.h`
- `windows/runner/flutter_window.cpp`

処理概要:

1. Token取得成功
2. Dart側から `raim_window` MethodChannel の `activate` を呼ぶ
3. Windows側で以下を実行
   - `ShowWindow(..., SW_RESTORE)`
   - `BringWindowToTop(...)`
   - `SetForegroundWindow(...)`
   - `SetFocus(...)`

### ログアウトして終了

ハンバーガーメニューに「ログアウトして終了」を追加しました。

主な対象ファイル:

- `lib/widgets/chat_input.dart`
- `lib/screens/chat_screen.dart`
- `lib/providers/auth_provider.dart`
- `lib/services/auth_service.dart`
- `lib/services/raim_server_service.dart`
- `lib/services/app_exit_service.dart`
- `lib/services/browser_login_launcher_io.dart`
- `android/app/src/main/kotlin/com/example/raim_prototype/MainActivity.kt`

処理概要:

1. ハンバーガーメニューを開く
2. 「ログアウトして終了」を選択
3. 確認ダイアログを表示
4. OKならWebSocketを切断
5. 保存済みTokenとPKCE一時情報を削除
6. Windowsでは `exit(0)` でアプリを終了

補足:

- 通常の `logout()` ではなく `logoutForExit()` を追加し、ログアウト直後にLoginScreenが起動して再認証が走らないようにしています。
- `RaimServerService.disconnect()` は二重呼び出しされても安全なように調整しています。
- Android では `SystemNavigator.pop()` だけだと認証に使ったブラウザへ戻ったり、アプリ履歴に残ったりするため、`raim_app_control` MethodChannel から `finishAndRemoveTask()` を呼んでホームへ戻すようにしています。
- Android debug 実行中に `flutter run` / PowerShell が待ち続けないよう、`finishAndRemoveTask()` 後に少し遅らせて Android プロセスも明示終了します。
- Android の認証ブラウザは、通常のChromeタブがローディング状態で残りにくいよう `LaunchMode.inAppBrowserView` を使います。

### Android / iOS callback設定

Windows検証が主対象ですが、Android / iOS側にも `raim://callback` の受け口を追加しています。

主な対象ファイル:

- `android/app/src/main/AndroidManifest.xml`
- `ios/Runner/Info.plist`

変更内容:

- Android:
  - `INTERNET` permission
  - `raim://callback` intent filter
- iOS:
  - URL Scheme `raim`

## WebSocket接続

現時点では CloudFront WebSocket 版の変更は未適用です。
LLM 接続は既存の RAiM WebSocket 実装を維持しており、アプリ起動時に `RaimServerService.connect()` を開始します。

主な対象ファイル:

- `lib/main.dart`
- `lib/screens/splash_screen.dart`
- `lib/services/raim_server_service.dart`

現在の処理概要:

1. アプリ起動時に `RaimServerService.connect()` を実行
2. `RaimServerService` は既存の WebSocket 接続先へ接続する
3. 接続失敗時は既存実装どおり自動再接続する

補足:

- CloudFront WebSocket 版は後で方針を決めてから別変更として対応する
- 現時点では `Authorization: Bearer <access_token>` 付与や CloudFront 用 `requestId` 追加は行っていない

## Windows表示・起動体験

### RAiM本体の枠無しフルスクリーン起動

Windows版RAiMアプリ本体を、タイトルバーなし・枠なし・モニター全体表示で起動するようにしました。

主な対象ファイル:

- `windows/runner/main.cpp`
- `windows/runner/win32_window.h`
- `windows/runner/win32_window.cpp`

処理概要:

1. 通常のFlutter Windowsウィンドウを作成
2. `EnterBorderlessFullscreen()` を呼ぶ
3. Window styleを `WS_POPUP` に変更
4. 起動モニターの `rcMonitor` 全体へリサイズ

## 依存関係追加

認証・Token保存・WebSocket用に依存関係を追加しています。

主な対象ファイル:

- `pubspec.yaml`
- `pubspec.lock`

追加・利用している主な依存:

- `app_links`
- `crypto`
- `flutter_secure_storage`
- `url_launcher`
- `uuid`
- `web_socket_channel`

## 作成・更新したドキュメント

- `FILES.md`
  - 既存構成と処理フローの説明
- `LOCAL_CHANGES.md`
  - このファイル
  - クローン時点からのローカル変更まとめ

## Android / Windows 両立対応

Windows と Android の両方で検証できるように、プラットフォームごとの表示・認証・終了処理を整理しました。
Android / iOS では Unity 埋め込み、Windows では Flutter の立ち絵表示を使う構成です。

変更した主なファイル:

- `pubspec.yaml`
- `pubspec.lock`
- `android/build.gradle.kts`
- `android/settings.gradle.kts`
- `android/app/build.gradle.kts`
- `android/unityLibrary/build.gradle`
- `lib/screens/login_screen.dart`
- `lib/screens/chat_screen.dart`
- `lib/services/embed_unity_bridge.dart`
- `lib/services/app_exit_service.dart`
- `lib/services/browser_login_launcher_io.dart`
- `android/app/src/main/kotlin/com/example/raim_prototype/MainActivity.kt`

変更内容:

- `android/unityLibrary` を参照できるように、Android Gradle の `include(":unityLibrary")` と `implementation(project(":unityLibrary"))` を設定
- `unityLibrary/libs` に含まれる Unity 側の jar / aar を解決するため、root Gradle に `flatDir` を設定
- ローカル環境にインストール済みの NDK `28.2.13676358` に app / unityLibrary 側の `ndkVersion` を揃えた
- `LoginScreen` から Windows 専用 `webview_windows` の direct import と埋め込み WebView 処理を除外
- `ChatScreen` は Android / iOS で `EmbedUnity`、Windows で `CharacterDisplay` を使うプラットフォーム分岐に整理
- `EmbedUnityBridge` は `sendToUnity` を使って Unity 側の `character.ReceiveEmotion` を呼ぶ
- Android 実機検証は `arm64-v8a` のみを対象にし、`arm64-v8a/libil2cpp.so` が存在する場合は `buildIl2Cpp` をスキップするように調整
- `android/unityLibrary/src/main/jniLibs/arm64-v8a` 配下の Unity 実行時ライブラリ（例: `libmain.so`, `libunity.so`, `lib_burst_generated.so`, `libil2cpp.so`）は Android 起動に必要なため保持
- Unity 側の C# / Scene / Prefab / Asset / Player Settings / `Il2CppOutputProject` などを更新した場合は、必要に応じて `arm64-v8a/libil2cpp.so` を再生成する
- Windows / Android とも外部ブラウザで Cognito 認証を開始する構成へ整理
- Android の「ログアウトして終了」は、保存済みToken削除後にホーム画面へ戻してからアプリタスクを履歴から除外する構成へ変更
- Android の認証ブラウザは Chrome の通常タブを残しにくくするため、Custom Tabs 相当の `LaunchMode.inAppBrowserView` へ変更

認証の戻り先:

- Windows: `http://localhost:3000/callback`
- Android / iOS: `raim://callback`

補足:

- Unity 埋め込みは `android/unityLibrary` の存在を前提にしています。Unity export を差し替える場合は、このフォルダを更新したうえで Android ビルドを確認してください。
- `buildIl2Cpp` は `arm64-v8a/libil2cpp.so` が無い場合だけ実行されます。Flutter 側の認証・WebSocket・UI変更だけであれば、通常は IL2CPP の再ビルドは不要です。
- 今回の変更は RAiM Edge / Cognito のクライアント検証を優先するためのローカル検証向け整理です。

## Git運用上の注意

このワークスペースの変更は、当初は検証・説明用のローカル差分として扱っていました。
本流へ push する場合は、ローカルで設定した exclude / skip-worktree によって変更が `git status` に出ない可能性があるため、push 対象を明示的に確認してください。

過去の方針:

- `RAiMproject` の変更は基本的にpushしない
- 通常の `git status` に出にくいよう、ローカルのexclude / skip-worktree運用を行っている

push する場合の注意:

- `.git/info/exclude` で除外したファイルは、必要に応じて除外設定を外す
- `git update-index --skip-worktree` した tracked file は、必要に応じて `--no-skip-worktree` に戻してから差分確認する
- `android/unityLibrary` 配下の `.so` はサイズが大きくなりやすいため、リポジトリ方針に合わせて Git 管理するか別配布にするか確認する

注意:

- 実装を本流へ取り込む場合は、このファイルを見ながら、必要な変更だけを改めてレビューしてください。
- Cognito の値は環境依存のため、本番・別環境へそのまま流用しないでください。
- Windows向けのChrome kiosk起動や `exit(0)` は検証用途に寄せた実装です。本番アプリ化する場合はUX方針に合わせて再検討してください。

## 今後更新する時のルール

このワークスペースで追加実装・設定変更・検証用の挙動変更をした場合は、以下を更新してください。

1. 変更した機能の節を追記または修正する
2. 対象ファイル一覧を更新する
3. 検証コマンドや確認結果があれば追記する
4. 本流へ取り込むべきか、ローカル検証専用かを明記する

担当者への説明や引き継ぎ時は、まずこのファイルと `FILES.md` を読むと全体像を追いやすいです。
