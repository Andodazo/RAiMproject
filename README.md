# RAiM

日本工学院八王子専門学校 ITスペシャリスト科の卒業研究プロジェクト。

AI コンパニオン「ライム」のクライアントアプリです。Windows ではデスクトップ
マスコットとして常駐し、モバイルではチャットアプリとして動きます。

サーバー側は別リポジトリ（`raim_aws`）にあります。

## 対応プラットフォーム

| プラットフォーム | 状態 |
|---|---|
| Windows | 対応。デスクトップマスコット + 入力小窓 |
| Android | 対応。チャット画面 + Unity 埋め込み |
| iOS | 対応。チャット画面 + Unity 埋め込み |
| Web / macOS / Linux | 非対応。ビルドは通るがマスコットは動かない |

## 構成

```
lib/
  config/       接続先などの設定
  models/       サーバーとやり取りする JSON のモデル
  providers/    画面に見せる状態（ChangeNotifier）
  screens/      画面
  services/     WebSocket・認証・音声・Unity 連携
  widgets/      部品
unity/          Unity プロジェクト（マスコット本体）
test/           ユニットテスト
```

主な流れは、`RaimServerService` が AWS と WebSocket でつながり、
`ChatProvider` が受け取ったメッセージを画面と `AudioPlayQueue`、
そして Windows では Unity へ振り分ける、という形です。

## 開発環境の準備

Flutter SDK と、Windows 版をビルドするなら Visual Studio の
「C++ によるデスクトップ開発」が必要です。

```bash
flutter pub get
flutter run -d windows
```

Unity 側を変更したときは、Unity Editor で
`unity/raim_unity/raim` を開いてビルドし、
`unity/raim_unity/builds/Windows/raim.exe` を更新してください。

### 接続先の切り替え

既定は AWS です。ビルド時に上書きできます。

```bash
flutter run --dart-define=RAIM_SERVER_URL=ws://127.0.0.1:8080
```

## 確認

```bash
flutter analyze
flutter test
```

## ログについて

`print` / `debugPrint` は使わず、`RaimLog` を通してください。
会話本文・画像・トークン・URL はログに出しません。長さや件数だけを出します。
release ビルドでは error 以外は出力されません。

## 配布（リリース）

配布ページ: https://andodazo.github.io/RAiMproject/

開いた端末に合わせて Windows 版（zip）か Android 版（APK）のボタンが出ます。
ファイル本体は GitHub Releases に置いていて、ページは常に最新の版を指します。
iOS は Apple の有料登録が無いと配れないため、ページには載せていません
（`flutter run --release` でケーブルから入れる。無料の署名は7日で切れる）。

### 新しい版を出す

1. `pubspec.yaml` の `version` を上げる（例: `1.0.0+1` → `1.0.1+2`）。
   `+` の後ろの数字は Android の上書きインストールの判定に使うので、毎回必ず増やす
2. コミットして push する
3. Windows の PowerShell でリポジトリ直下から実行する

```powershell
.\tools\release.ps1            # dist\ に作るだけ（中身を確かめたいとき）
.\tools\release.ps1 -Publish   # 作って GitHub Releases に公開する
```

公開すると配布ページは自動で新しい版になります。使う側は同じボタンから
入れ直すだけです（Android は上書き、Windows はフォルダを差し替え。
どちらもログイン状態と設定は残る）。

`-SkipWindows` / `-SkipAndroid` で片方だけ作れますが、配布ページは
「最新の版」のファイルしか見ないので、公開するときは両方そろえてください。

### 事前に必要なもの

- `android\key.properties` と配布用の keystore。
  **鍵をなくすと、配った APK に上書きできなくなる**（全員アンインストールが必要になる）ので
  keystore はリポジトリの外にバックアップしておく
- `android\unityLibrary`（Unity から Android 向けに Export）
- `unity\raim_unity\builds\Windows\raim.exe`（Unity の Windows ビルド）
- GitHub CLI（`winget install GitHub.cli` → `gh auth login`）

### アプリを更新しなくていい変更

人格プロンプト、ツール、天気・検索の挙動など、サーバー（`raim_aws`）側の変更は
Lambda にデプロイした時点で全員に反映されます。アプリを出し直すのは
Flutter / Unity 側を変えたときだけです。

### 配布ページの設定（最初の1回だけ）

GitHub の Settings → Pages → Source を「Deploy from a branch」、
Branch を `main` / `/docs` にする。ページの中身は `docs/index.html`。
