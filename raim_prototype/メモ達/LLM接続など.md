# RAiM プロトタイプ実装まとめ 第2回（LLM接続〜キャラ設定〜会話履歴）

## このドキュメントについて

第1回（プロトタイプUI骨格完成）の続き。デスクトップに戻って、実際のLLMに繋いで動かせる状態にした記録。

合わせて読むドキュメント：
- `RAiM_技術設計まとめ.md` — プロジェクト全体の設計
- `Flutter_プロジェクト構造の解説.md` — Flutterの基本構造
- `RAiM_プロトタイプ実装まとめ.md` — 第1回（UI骨格まで）

---

## 今、何が動いているか

「**実際のGemma 3 12B に繋いで、文脈を保ったまま自然に対話できる AI コンパニオン**」が動く状態。

### 動作確認できること

1. テキスト入力に対して、ローカル LLM（Gemma 3 12B IT）が応答
2. 応答は JSON 形式で `{"text": ..., "emotion": ..., "intensity": ...}` で返ってくる
3. 過去の会話履歴を踏まえた文脈ある返答ができる
4. 感情パラメータを付けて応答してくる（happy/sad/angry/surprised/neutral/caring）
5. Tailscale 経由で、学校のノート PC から自宅 PC の Ollama を叩く準備済み（学校側のセットアップ後）

### まだできていないこと

- Unity との連携（3Dキャラ描画）
- 音声入出力（STT、TTS）
- 画像入力
- 認証・履歴永続化（本番化フェーズ）

---

## 今回追加した技術要素

### 1. Ollama インストール

ローカル LLM 実行環境。
- バージョン: 最新（Ollama 0.24.0 で動作確認）
- モデル: `gemma3:12b`（約8GB、4bit量子化）
- 動作場所: 自宅デスクトップ（RTX 4070）

### 2. Tailscale セットアップ

自宅PCのOllamaを学校から叩くためのVPN。
- 自宅デスクトップでTailscaleインストール済み
- 「Run unattended」設定済み（再起動後も自動接続）
- Tailscale IPメモ済み
- 環境変数 `OLLAMA_HOST=0.0.0.0:11434` 設定済み（外部アクセス許可）
- 学校ノートPCへの導入は今後

### 3. Flutter 側に OllamaService 実装

`LLMService` インターフェースの実装として、実Ollamaに HTTP リクエストする `OllamaService` クラスを追加。
`MockLLMService` から `OllamaService` への切り替えは main.dart の1行変更のみ。

### 4. 会話履歴対応

`ChatProvider` から `LLMService.sendMessage` に履歴を渡すようにシグネチャ変更。
直近10往復（20メッセージ）を毎回送信することで、LLM が文脈を保てる。

### 5. キャラ性格パターン切り替え機能

3つの性格パターン（A: 知的相棒 / B: クール先輩 / C: ギャップ萌え）を1行変更で切り替えられる構造を実装。
キャラ作り込みフェーズで使う。

### 6. LLMパラメータ調整機能

`temperature` と `top_p` を3パターンのコメントアウトで切り替えられる構造を実装。
応答の「ランダム性・個性」を試行錯誤できる。

---

## 主要な学習ポイント

### Dart の factory コンストラクタ

JSON からオブジェクトを生成する Dart の慣習パターン。
`LLMResponse.fromJson(json)` のように、クラス名から直接呼べる。
詳細は `Dart_factoryコンストラクタの解説.md` 参照。

### 依存性注入（Dependency Injection）

`ChatProvider` は `LLMService` インターフェースだけを知っていて、中身（Mock/Ollama/Bedrock）は外から注入される設計。
これにより、main.dart の1行を変えるだけで全実装を切り替えられる。

```dart
// プロトタイプ（Mock）
ChatProvider(MockLLMService())

// 開発中（ローカル Ollama）
ChatProvider(OllamaService())

// 学校から自宅PC（Tailscale 経由）
ChatProvider(OllamaService(baseUrl: 'http://100.x.x.x:11434'))

// 本番（AWS Bedrock 経由）
ChatProvider(BedrockService())
```

### LLM はステートレス

LLM は前回の会話を覚えていない。会話履歴を保ちたいなら、毎回履歴を送信する必要がある。
本番でコスト最適化するには、プロンプトキャッシュ・ファインチューニング・履歴要約などのテクニックを使う。

---

## ファイル構成（前回からの差分）

```
lib/
├── main.dart                          ← 「ChatProvider(OllamaService())」に変更
├── models/
│   ├── message.dart
│   └── llm_response.dart
├── services/
│   └── llm_service.dart               ← OllamaService追加、history引数追加
├── providers/
│   └── chat_provider.dart             ← sendUserMessageに変更、履歴渡す処理追加
├── screens/
│   └── chat_screen.dart
└── widgets/
    ├── message_list.dart
    ├── message_bubble.dart
    └── chat_input.dart                ← sendUserMessageを呼ぶように変更
```

`pubspec.yaml` に `http: ^1.2.0` 追加済み。

---

## システムプロンプトの構造

`OllamaService` 内で、システムプロンプトを3つのパートに分割している：

```
_commonProfile（共通プロフィール）
    + 性格パターン（A/B/C のいずれか）
    + _outputFormat（JSON出力指示）
```

### 共通プロフィール（_commonProfile）

性格に関わらず常に適用される、ライムの基本情報：

```
あなたの基本情報：
- 名前: ライム（表記: RAiM、"i"を小文字で書くのは"Ai"の文字を名前に込めているため）
- ユーザーの相棒であり、友達であり、雑談相手
- ユーザーと一緒に勉強や作業をしたり、雑談で疲れを癒したりする存在
- ユーザーが写真や出来事を共有してくれたら、一緒に感動・反応する
- ユーザーと共通の興味（ゲーム、アニメ、技術、音楽など）を持つ
```

### 性格パターン

3つから切り替え可能：

| パターン | 一人称 | 二人称 | 口調 | 特徴 |
|---|---|---|---|---|
| A: 知的相棒 | 私 | あなた | 丁寧・敬語ベース | 落ち着いた秘書っぽさ |
| B: クール先輩 | 私 | きみ・名前 | 砕けた口調 | 親しみやすい同年代感 |
| C: ギャップ萌え | 私 | あなた | 普段クール | 好きな話題で素が出る |

性格パターン切り替えは `_personalityA` / `_personalityB` / `_personalityC` を `personality` 変数に代入することで切り替え。

### 出力形式（_outputFormat）

JSON 形式で `text + emotion + intensity` を返すよう指示。
emotion は 6種類（happy/sad/angry/surprised/neutral/caring）から選択。

---

## LLM パラメータ（試行錯誤用）

`OllamaService.sendMessage` 内で、3パターンのプリセットをコメントアウト切り替えで用意：

| パターン | temperature | top_p | 特徴 |
|---|---|---|---|
| 1: 控えめ | 0.3 | 0.9 | 決定的、安定、JSONも崩れにくい |
| 2: バランス（標準） | 0.8 | 0.9 | 自然で個性的、推奨 |
| 3: クリエイティブ | 1.1 | 0.95 | 予測不能、生き生き、JSON崩れリスク |

学校で同じ質問を3パターンで投げ比べると、パラメータの効果が体感できる。

---

## キャラ設定について

### 確定している部分

- 名前：ライム（表記: RAiM）
- 名前の由来：「Ai」（AI）の文字を入れたかったので "i" を小文字に
- 見た目：シルバー＋ライムグリーンの髪、フォーマル寄りのスーツ、青い瞳
- ユーザーとの関係性：友達・先輩・相棒・雑談相手（複合）

### 未確定の部分

- 一人称、二人称、口調 → 性格パターンA/B/Cで試行錯誤中
- 性格の核 → 班員の意見も聞きつつ詰めていく
- 過去設定、価値観、口癖 → キャラの軸が決まったら追加

### キャラ作り込みの進め方

1. プロトタイプ段階：3パターン試して、感触で方向性を選ぶ
2. 班員と共有：来週見せて意見をもらう
3. 軸が決まったら：プロンプトに細かい振る舞いを追加（口癖、好きな話題、苦手な反応など）
4. ファインチューニング段階（フェーズ4）：1000件以上の対話データで学習させ、モデルにキャラを焼き込む

---

## 動作の流れ（実装の全体像）

ユーザーが「FF14が好きなんだ」と入力した時の処理：

```
[ChatInput]
   ↓ context.read<ChatProvider>().sendUserMessage("FF14が好きなんだ")
   ↓
[ChatProvider]
   1. ユーザーメッセージを履歴に追加
   2. notifyListeners() で UI に「ユーザー側メッセージ」を即表示
   3. isLoading = true で「考え中...」表示
   4. 直近20件の履歴を切り出す
   5. _llmService.sendMessage("FF14が好きなんだ", history: 履歴) を呼ぶ
   ↓
[OllamaService]
   1. システムプロンプト + 履歴 + 最新入力 を messages 配列に組み立て
   2. options（temperature, top_p）を付ける
   3. http://localhost:11434/api/chat に POST
   ↓
[Ollama / Gemma 3 12B IT]
   推論実行（1〜3秒）
   ↓
[Ollama → OllamaService]
   レスポンスの JSON 文字列を 2回 jsonDecode
   LLMResponse オブジェクトに変換
   ↓
[OllamaService → ChatProvider]
   LLMResponse を返す
   ↓
[ChatProvider]
   1. LLM 応答を履歴に追加
   2. isLoading = false
   3. notifyListeners() で UI 更新
   ↓
[MessageList → MessageBubble]
   「FF14がお好きなんですね…」を左側に表示、感情ラベル付き
```

---

## 環境セットアップ手順（再現用）

### 1. Ollama インストール

1. https://ollama.com からインストーラ DL
2. インストール後、PowerShellで確認: `ollama --version`
3. 環境変数 `OLLAMA_HOST=0.0.0.0:11434` を設定（外部アクセス許可、Tailscale経由で叩くために必要）
4. Windows ファイアウォール: ポート 11434 (TCP) の受信を許可
5. Ollama 再起動

### 2. モデルダウンロード

```bash
ollama pull gemma3:12b
```

約8GB、回線速度により15分〜1時間。

### 3. Tailscale セットアップ

1. https://tailscale.com でアカウント作成
2. デスクトップにインストール、ログイン
3. システムトレイから「Preferences」→「Run unattended」にチェック
4. Tailscale IP（100.x.x.x）をメモ

学校ノートPCからは：
1. 同じく Tailscale インストール、同じアカウントでログイン
2. Flutter の main.dart で `baseUrl: 'http://100.x.x.x:11434'` 指定

### 4. Flutter プロジェクト

```bash
cd プロジェクトディレクトリ
flutter pub get
flutter run -d chrome
```

---

## 次回やること

### 短期（次回作業）

- Unity 連携準備
  - Unity プロジェクト作成
  - 立ち絵切り替えシーン作成
  - WebSocket クライアント実装（C#）
- Flutter 側に WebSocket サーバー機能追加
  - `services/unity_bridge.dart` 作成
  - 感情パラメータを Unity に送信
- 立ち絵差分の準備（喜怒哀楽の6パターン PNG）

### 中期

- STT（sherpa-onnx）統合 → 音声入力対応
- TTS（uPiper）統合 → Unity 側に組み込み
- 口パク（音声波形に応じた口の動き）

### 長期

- Bedrock 移行（プロンプトはほぼ流用、エンドポイントを変えるだけ）
- ファインチューニング（キャラの作り込み）
- RAG（長期記憶、画像認識結果の保存）

---

## トラブルシューティング

### Ollama に繋がらない

- `ollama serve` が起動してるか確認
- 環境変数 `OLLAMA_HOST` が反映されてるか: `echo $env:OLLAMA_HOST`
- PowerShell を再起動して環境変数を再読み込み

### Tailscale 経由で繋がらない

- 自宅 PC の Tailscale が「running」状態か
- Windows ファイアウォールでポート 11434 開放してるか
- `OLLAMA_HOST=0.0.0.0:11434` で `0.0.0.0` になってるか（`localhost` だと外部アクセス不可）

### Flutter エラー

- `flutter pub get` 実行
- 「ChatProvider に sendMessage がない」エラー: `sendUserMessage` にメソッド名変更したので、呼ぶ側も合わせる
- ホットリスタート（`R` キー）で状態リセット

### LLM の応答が変

- temperature を 0.3 程度に下げる
- システムプロンプトを見直す
- format: 'json' を指定してるか確認
- 会話履歴が長すぎる場合: 直近10件くらいに絞る

---

## 変更履歴

- 第1回 (`RAiM_プロトタイプ実装まとめ.md`): MockLLMServiceでUI骨格完成
- 第2回 (本ドキュメント): 実LLM接続、会話履歴対応、キャラ性格パターン、LLMパラメータ調整