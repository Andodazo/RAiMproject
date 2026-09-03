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
