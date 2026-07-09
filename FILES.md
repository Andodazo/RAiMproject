# RAiMproject FILES

このファイルは、`RAiMproject` の既存構成と主要な処理フローを、担当者へ説明しやすくするための整理資料です。

現状のコードは Flutter クライアントを中心に、RAiM サーバーとの WebSocket 通信、チャット UI、画像添付、Unity キャラクター表示、VOICEVOX TTS をつなぐ検証用の構成になっています。

一部の Dart / C# ファイル内コメントは文字化けしていますが、ここでは実装内容から読み取れる役割を日本語で整理しています。

## 1. 全体像

RAiMproject は、大きく次の層に分かれています。

```text
ユーザー操作
  ↓
Flutter UI
  ↓
Provider による状態管理
  ↓
LLMService 実装
  ↓
RAiM サーバー / ローカル LLM
  ↓
応答を UI・Unity・TTS へ反映
```

現在の本線は `RaimServerService` を使う WebSocket 接続です。`MockLLMService` と `OllamaService` も残っていますが、主にテスト・代替実装として使える形です。

## 2. ルート直下の主なファイル・ディレクトリ

| パス | 役割 |
| --- | --- |
| `pubspec.yaml` | Flutter プロジェクトの依存関係、アセット、SDK バージョンを定義します。`provider`、`web_socket_channel`、`image_picker`、`audioplayers`、`flutter_embed_unity` などを利用しています。 |
| `pubspec.lock` | 実際に解決された依存パッケージのバージョンを固定します。 |
| `analysis_options.yaml` | Dart / Flutter の静的解析ルールを定義します。 |
| `README.md` | Flutter 新規プロジェクト生成時の標準 README です。現状では詳しい構成説明は入っていません。 |
| `lib/` | Flutter アプリ本体の Dart コードです。UI、状態管理、通信、TTS、Unity 連携が入っています。 |
| `assets/images/` | Flutter 側で表示する背景画像・感情別キャラクター画像を置いています。Windows / Web など Unity を直接埋め込まない場合の立ち絵表示に使います。 |
| `unity/` | Unity プロジェクト一式です。RAiM キャラクター表示と Flutter からの感情通知受信を担当します。 |
| `android/`, `ios/`, `macos/`, `linux/`, `windows/`, `web/` | Flutter が生成する各プラットフォーム向けのプロジェクトファイルです。 |
| `test/` | Flutter のテストコード置き場です。現状は標準の `widget_test.dart` が中心です。 |
| `メモ達/` | セットアップ、設計、実装メモ、Dart ガイド、TTS 比較などの補足ドキュメントです。 |

## 3. `lib/` 配下の構成

```text
lib/
  main.dart
  models/
    message.dart
    llm_response.dart
  providers/
    chat_provider.dart
    camera_provider.dart
  screens/
    chat_screen.dart
  services/
    llm_service.dart
    raim_server_service.dart
    camera_service.dart
    tts_service.dart
    unity_communicator.dart
    WindowsUnityBridge.dart
    embed_unity_bridge.dart
  widgets/
    character_display.dart
    chat_input.dart
    message_bubble.dart
    message_list.dart
```

## 4. 起動まわり

### `lib/main.dart`

Flutter アプリのエントリーポイントです。

主な処理は次の通りです。

1. `WidgetsFlutterBinding.ensureInitialized()` で Flutter の初期化を行います。
2. 実行プラットフォームに応じて Unity 連携方式を選びます。
   - Web / Windows など: `WindowsUnityBridge`
   - Android / iOS: `EmbedUnityBridge`
3. `UnityCommunicator.start()` を呼び、Unity 連携を開始します。
4. `RaimServerService` を作成し、RAiM サーバーへ WebSocket 接続を開始します。
5. `MultiProvider` で `ChatProvider` と `CameraProvider` を登録します。
6. `ChatScreen` を表示します。

現在の RAiM サーバー接続先は、`main.dart` 内の `_raimServerUrl` で指定されています。

```dart
const String _raimServerUrl = 'ws://100.81.35.109:8080';
```

同一 PC で検証する場合は、コメントとして残っている `ws://127.0.0.1:8080` に切り替える想定です。

## 5. モデル

### `lib/models/message.dart`

画面に表示する会話メッセージを表すモデルです。

| フィールド | 内容 |
| --- | --- |
| `text` | メッセージ本文 |
| `role` | `user` または `assistant` |
| `timestamp` | メッセージ作成時刻 |
| `emotion` | AI 応答に紐づく感情。例: `happy`, `sad`, `angry`, `surprised`, `neutral`, `caring` |
| `intensity` | 感情の強度 |

`MessageRole` により、ユーザー発話か AI 応答かを区別します。

### `lib/models/llm_response.dart`

RAiM サーバーや LLM から返ってくる JSON を Flutter 側で扱うためのモデルです。

対応している主な `type` は次の通りです。

| type | 意味 |
| --- | --- |
| `session_start` | サーバー側で会話セッションが開始された通知です。`session_id` を保持します。 |
| `filler_audio` | つなぎ発話です。UI の会話履歴には追加せず、Unity と TTS に流す想定です。 |
| `chat` | 通常の AI 応答です。画面表示、Unity 感情反映、TTS 発話の対象になります。 |
| `error` | エラー通知です。現状は判定用 getter があるものの、詳細な UI 表示処理は限定的です。 |

未定義フィールドや未知の `type` が来てもクラッシュしにくいよう、デフォルト値を持たせています。

## 6. 状態管理

### `lib/providers/chat_provider.dart`

チャット全体の状態管理を担当します。

主な責務は次の通りです。

- ユーザーと AI の会話履歴を保持する。
- 送信中かどうかを `isLoading` として保持する。
- `RaimServerService` の接続状態を購読し、UI 側へ通知する。
- ユーザー入力と画像データを `LLMService.sendMessage()` に渡す。
- サーバーから返ってきた `LLMResponse` を種類別に処理する。
- `chat` 応答を画面に追加する。
- `chat` / `filler_audio` の感情情報を Unity へ送り、TTS で読み上げる。

`ChatProvider` は `LLMService` 抽象に依存しているため、WebSocket 版の `RaimServerService`、ローカル Ollama 版の `OllamaService`、モック版の `MockLLMService` を差し替えられる設計です。

### `lib/providers/camera_provider.dart`

画像添付の状態管理を担当します。

主な責務は次の通りです。

- カメラまたはギャラリーから選択された画像のローカルパスを保持する。
- RAiM サーバーへ送信するための Base64 画像データを保持する。
- 画像プレビューの削除、送信後のクリアを行う。

内部処理は `CameraService` に委譲しています。

## 7. 画面・UI

### `lib/screens/chat_screen.dart`

チャット画面全体のレイアウトを担当します。

主な構成は次の通りです。

1. 背景画像を表示する。
2. 背景に暗めのオーバーレイを重ねる。
3. キャラクター層を表示する。
   - Android / iOS: `EmbedUnity` で Unity を埋め込みます。
   - Windows など: `CharacterDisplay` で Flutter 画像を表示します。
4. メッセージ一覧を表示する。
5. 入力欄、画像添付ボタン、メニュー、音量ボタンを配置する。

画面幅が `600px` 以上かどうかで、スマホ向け縦長レイアウトと PC 向け横長レイアウトを切り替えています。

### `lib/widgets/chat_input.dart`

入力欄と送信ボタン、画像添付 UI を担当します。

主な処理は次の通りです。

- 入力テキストを取得する。
- `CameraProvider` から選択済み画像の Base64 データを取得する。
- テキストも画像も空の場合は送信しない。
- `ChatProvider.sendUserMessage()` を呼ぶ。
- 送信後に入力欄と画像選択状態をクリアする。
- 画像追加方法として、カメラ撮影またはギャラリー選択のボトムシートを出す。

### `lib/widgets/message_list.dart`

`ChatProvider.messages` を購読し、会話履歴を一覧表示します。

送信中の場合は、末尾にローディング表示を追加します。

### `lib/widgets/message_bubble.dart`

1 件のメッセージを吹き出しとして表示します。

ユーザー発話は右寄せ、AI 応答は左寄せです。AI 応答に `emotion` がある場合は、補足として感情ラベルも表示します。

### `lib/widgets/character_display.dart`

Windows など、Unity を Flutter に直接埋め込まない場合のキャラクター表示を担当します。

`ChatProvider.messages` の最新 AI 応答から `emotion` を読み取り、次の画像に切り替えます。

| emotion | 表示画像 |
| --- | --- |
| `happy` | `assets/images/happy.png` |
| `sad` | `assets/images/sad.png` |
| `angry` | `assets/images/angry.png` |
| `surprised` | `assets/images/surprise.png` |
| `neutral`, `caring`, その他 | `assets/images/default.png` |

## 8. 通信・サービス

### `lib/services/llm_service.dart`

LLM 通信を抽象化するインターフェースと、代替実装をまとめたファイルです。

#### `LLMService`

`sendMessage()` を定義する抽象クラスです。

戻り値は `Stream<LLMResponse>` です。これは、1 回のユーザー入力に対して `filler_audio` と `chat` のように複数の応答が返る可能性を扱うためです。

#### `MockLLMService`

テスト用の簡易実装です。固定的な応答を返します。

#### `OllamaService`

ローカル Ollama の `/api/chat` に HTTP POST する実装です。

現状の本線ではありませんが、RAiM サーバーを使わずにローカル LLM 応答を試すための代替経路として残っています。

### `lib/services/raim_server_service.dart`

RAiM サーバーと WebSocket 通信する本線の `LLMService` 実装です。

主な責務は次の通りです。

- 起動時に WebSocket 接続を確立する。
- 接続状態を `RaimConnectionState` として管理する。
- サーバー切断時に自動再接続する。
- `session_start` を受け取ったら `session_id` を保持する。
- ユーザー入力、画像、`session_id` を JSON 化して送信する。
- サーバーからの複数応答を `Stream<LLMResponse>` として `ChatProvider` へ返す。

接続状態は次の 4 種類です。

| 状態 | 意味 |
| --- | --- |
| `connecting` | 接続中です。 |
| `connected` | 接続済みです。 |
| `disconnected` | 切断され、自動再接続中です。 |
| `offline` | 再接続を試し切り、休止状態になっています。次回送信時に再接続を試みます。 |

送信 payload の基本形は次の通りです。

```json
{
  "text": "ユーザー入力",
  "images": [
    {
      "data": "Base64画像データ",
      "media_type": "image/jpeg"
    }
  ],
  "session_id": "既存セッションID"
}
```

`images` と `session_id` は必要な場合のみ付与されます。

### `lib/services/camera_service.dart`

カメラ・ギャラリーから画像を取得し、送信用に加工します。

主な処理は次の通りです。

1. `image_picker` で画像を取得する。
2. ギャラリーの場合は複数画像選択に対応する。
3. 画像をデコードする。
4. 長辺が 1024px を超える場合はリサイズする。
5. JPEG quality 85 で圧縮する。
6. Base64 文字列へ変換する。
7. Flutter 表示用のローカルパスと送信用 Base64 を返す。

### `lib/services/tts_service.dart`

VOICEVOX を使った音声読み上げを担当します。

現在の接続先は次の通りです。

```dart
this.baseUrl = 'http://100.81.35.109:50021'
```

処理フローは次の通りです。

1. `/audio_query` にテキストと `speakerId` を送る。
2. 返ってきたクエリを `/synthesis` に送る。
3. 生成された WAV バイナリを `audioplayers` で再生する。

`ChatProvider` から `chat` または `filler_audio` を受け取ったときに呼ばれます。

## 9. Unity 連携

### `lib/services/unity_communicator.dart`

Flutter から Unity へ感情情報を送るための抽象インターフェースです。

実装差分を隠すために、次の 3 メソッドだけを公開しています。

- `start()`
- `sendEmotion({ text, emotion, intensity })`
- `stop()`

### `lib/services/WindowsUnityBridge.dart`

Windows 向けの Unity 連携です。

Flutter 側が `localhost:8765` で WebSocket サーバーとして起動し、Unity 側がクライアントとして接続します。

`sendEmotion()` が呼ばれると、次のような JSON を接続中の Unity クライアントへ配信します。

```json
{
  "type": "emotion_change",
  "text": "AI応答本文",
  "emotion": "happy",
  "intensity": 0.8
}
```

### `lib/services/embed_unity_bridge.dart`

Android / iOS 向けの Unity 連携です。

`flutter_embed_unity` の `sendToUnity()` を使い、Unity 内の GameObject に直接メッセージを送ります。

現在は次の呼び出しを行います。

```dart
sendToUnity("character", "ReceiveEmotion", emotion);
```

### `unity/raim_unity2022/Assets/Scripts/RAiMCharacterController.cs`

Unity 側で感情を受け取り、表示する Sprite を切り替える C# スクリプトです。

主な処理は次の通りです。

- Inspector で感情別 Sprite を設定する。
- `happy`, `sad`, `angry`, `surprised`, `neutral`, `caring` を Sprite に対応付ける。
- Flutter から `ReceiveEmotion()` または `ReceiveMessage()` を受け取る。
- Windows 版では `ws://localhost:8765` に WebSocket 接続し、Flutter から JSON を受け取る。
- 受け取った `emotion` に応じて `SpriteRenderer.sprite` を切り替える。

`unity/raim_unity/raim/Assets/Scripts/RAiMCharacterController.cs` にも同様のスクリプトがあります。Unity プロジェクトが複数置かれているため、どちらを実際の検証対象にするかは Unity 側の運用に合わせて確認が必要です。

## 10. 主要な処理フロー

### 10.1 アプリ起動フロー

```text
main()
  ↓
Flutter 初期化
  ↓
実行プラットフォーム判定
  ↓
UnityCommunicator を選択
  ├─ Windows / Web など: WindowsUnityBridge
  └─ Android / iOS: EmbedUnityBridge
  ↓
Unity 連携開始
  ↓
RaimServerService 作成
  ↓
RAiM サーバーへ WebSocket 接続開始
  ↓
Provider 登録
  ↓
ChatScreen 表示
```

### 10.2 テキスト送信フロー

```text
ユーザーが ChatInput に入力
  ↓
送信ボタン押下
  ↓
ChatInput._sendMessage()
  ↓
ChatProvider.sendUserMessage(text)
  ↓
ユーザーメッセージを画面履歴に追加
  ↓
RaimServerService.sendMessage()
  ↓
WebSocket で RAiM サーバーへ JSON 送信
  ↓
サーバーから LLMResponse を受信
  ↓
ChatProvider._handleResponse()
  ↓
chat の場合:
  ├─ MessageList に AI 応答を表示
  ├─ Unity へ emotion を送信
  └─ TTSService で読み上げ
```

### 10.3 画像付き送信フロー

```text
CAPTURE ボタン押下
  ↓
カメラ / ギャラリーを選択
  ↓
CameraProvider.pickAndStoreImage()
  ↓
CameraService.selectAndProcessImages()
  ↓
画像取得
  ↓
リサイズ・JPEG 圧縮・Base64 化
  ↓
ChatInput にプレビュー表示
  ↓
ユーザーが送信
  ↓
ChatProvider.sendUserMessage(text, images)
  ↓
RaimServerService.sendMessage()
  ↓
payload.images に Base64 画像を入れて WebSocket 送信
```

### 10.4 サーバー応答処理フロー

```text
RaimServerService が WebSocket メッセージ受信
  ↓
JSON を LLMResponse に変換
  ↓
type を判定
  ├─ session_start
  │   └─ session_id を保存し、画面には流さない
  ├─ filler_audio
  │   ├─ Unity へ emotion を送信
  │   └─ TTSService で読み上げ
  ├─ chat
  │   ├─ 会話履歴へ追加
  │   ├─ Unity へ emotion を送信
  │   └─ TTSService で読み上げ
  └─ その他
      └─ 現状はログ出力中心
```

### 10.5 Unity 反映フロー

```text
ChatProvider が emotion を受け取る
  ↓
UnityCommunicator.sendEmotion()
  ↓
実行環境により分岐
  ├─ Windows:
  │   ├─ WindowsUnityBridge が JSON を WebSocket 配信
  │   └─ Unity の RAiMCharacterController が受信
  └─ Android / iOS:
      ├─ EmbedUnityBridge が sendToUnity() を実行
      └─ Unity の RAiMCharacterController.ReceiveEmotion() が受信
  ↓
Unity 側で emotion に応じて Sprite 切り替え
```

### 10.6 TTS 読み上げフロー

```text
ChatProvider が chat / filler_audio を処理
  ↓
TTSService.speak(text)
  ↓
VOICEVOX /audio_query
  ↓
VOICEVOX /synthesis
  ↓
WAV バイナリ取得
  ↓
audioplayers で再生
```

## 11. 現状の接続先・ポート

| 用途 | 接続先 | 定義場所 |
| --- | --- | --- |
| RAiM サーバー WebSocket | `ws://100.81.35.109:8080` | `lib/main.dart` |
| ローカル RAiM サーバー候補 | `ws://127.0.0.1:8080` | `lib/main.dart` のコメント |
| Flutter → Unity Windows 用 WebSocket | `ws://localhost:8765` | `WindowsUnityBridge.dart` / Unity C# |
| VOICEVOX | `http://100.81.35.109:50021` | `lib/services/tts_service.dart` |
| Ollama | `http://localhost:11434` | `lib/services/llm_service.dart` |

## 12. 担当者へ説明するときの要点

- 画面の入口は `lib/main.dart`、実際の画面は `lib/screens/chat_screen.dart` です。
- 会話の状態は `ChatProvider` が中心です。
- RAiM サーバーとの通信は `RaimServerService` が担当します。
- 画像添付は `CameraProvider` と `CameraService` が担当します。
- AI 応答の `emotion` が、Flutter の立ち絵表示、Unity、TTS の起点になります。
- Windows では Flutter が Unity 向け WebSocket サーバーになり、Unity が接続します。
- Android / iOS では `flutter_embed_unity` 経由で Unity に直接送ります。
- `LLMService` 抽象を挟んでいるため、RAiM サーバー、Ollama、モックの切り替えがしやすい構成です。

## 13. 注意点

- コード内コメントの一部が文字化けしているため、今後の引き継ぎではコメントの再整理が必要です。
- `ChatInput` など一部ファイルには文字化けした文字列リテラルが含まれているため、ビルド確認時に構文エラーが出る可能性があります。
- `main.dart` の RAiM サーバー URL と `tts_service.dart` の VOICEVOX URL は固定 IP になっています。環境が変わる場合は差し替えが必要です。
- Unity プロジェクトが `unity/raim_unity2022/` と `unity/raim_unity/raim/` の 2 系統あります。どちらを正とするかは、実際に開いている Unity プロジェクトと合わせて確認してください。
- `session_start`、`filler_audio`、`chat` の複数応答を前提にしているため、サーバー側 JSON 形式を変更する場合は `LLMResponse` と `RaimServerService` の両方を確認してください。
