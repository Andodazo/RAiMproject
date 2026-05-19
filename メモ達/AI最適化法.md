# RAiM 設計ドキュメント

**AIコンパニオン「ライム（RAiM）」 アーキテクチャ・プロンプト戦略まとめ**

- 対象モデル: Gemma 3 12B IT
- 現在の稼働環境: ローカル（Ollama）/ Tailscale 経由でアクセス
- 想定本番環境: AWS（API Gateway WebSocket + Lambda + DynamoDB + 推論エンドポイント）
- フロントエンド: Flutter（Dart）
- 音声合成: VOICEVOX 等を想定
- ステータス: 設計段階（ローカル検証中）

---

## 目次

0. [全体アーキテクチャ概要](#0-全体アーキテクチャ概要)
1. [キャラクター構築戦略](#1-キャラクター構築戦略)
2. [冗談・からかい・ギャップ演出の拡張](#2-冗談からかいギャップ演出の拡張)
3. [トークン量削減戦略（動的プロンプト）](#3-トークン量削減戦略動的プロンプト)
4. [検索機能のハイブリッド戦略](#4-検索機能のハイブリッド戦略)
5. [バックエンドアーキテクチャ（API Gateway WebSocket + Lambda）](#5-バックエンドアーキテクチャapi-gateway-websocket--lambda)
6. [プロンプトをサーバー側に隠す設計上のメリット](#6-プロンプトをサーバー側に隠す設計上のメリット)
7. [ローカルテスト環境（Ollama + Tailscale + Node.js）](#7-ローカルテスト環境ollama--tailscale--nodejs)
8. [Lambda 処理の高速化テクニック](#8-lambda-処理の高速化テクニック)
9. [ファインチューニングの検討条件と今後のロードマップ](#9-ファインチューニングの検討条件と今後のロードマップ)

---

## 0. 全体アーキテクチャ概要

### 0.1 役割分担

| レイヤー | 役割 | 主要要素 |
| --- | --- | --- |
| フロントエンド | ユーザー入力の送信／音声・テキストの出力のみ | Flutter（Dart）、VOICEVOX |
| 通信層 | 双方向接続の維持と非同期プッシュ | API Gateway WebSocket（本番） / `ws`（ローカル） |
| バックエンド | プロンプト組立・検索・推論呼び出し・分岐制御 | AWS Lambda（本番） / Node.js（ローカル） |
| データ層 | プロンプト・会話履歴・シーン定義 | DynamoDB（本番） / 変数 or SQLite（ローカル） |
| 推論層 | 文章生成・Function Calling | Gemma 3 12B IT（AWS or Ollama） |

### 0.2 「重い処理はサーバーに、Flutter は表示と再生に専念」という原則

Flutter が直接 Gemma にプロンプトを投げる構成ではなく、間に Lambda（中継サーバー）を挟む。これにより以下を実現する。

- プロンプトをアプリに同梱せずに済む（漏洩・盗用の防止）
- アプリのアップデートなしで AI の挙動を更新できる
- 通信量を最小化（ユーザー入力テキストだけを送る）
- DB アクセスや検索 API のキー管理をサーバー側に閉じ込められる

詳細は [6. プロンプトをサーバー側に隠す設計上のメリット](#6-プロンプトをサーバー側に隠す設計上のメリット) を参照。

---

## 1. キャラクター構築戦略

### 1.1 結論：ファインチューニングは必須ではない

Gemma 3 12B IT の表現力と推論能力があれば、**プロンプトエンジニアリングだけで** AIライバー「しずく」のような豊富なボキャブラリーと生き生きとしたキャラクター性は十分に引き出せる。

ファインチューニング（FT）を検討すべきタイミングは、語彙不足ではなく **「プロンプトが長くなりすぎてレイテンシ・コストが許容できなくなった時」** である。詳細は [9. ファインチューニングの検討条件と今後のロードマップ](#9-ファインチューニングの検討条件と今後のロードマップ) を参照。

### 1.2 現状プロンプトの課題

抽象的なルール（「クールで落ち着いた口調」「素が出る」など）だけだと、ベースモデルが持つ「無難でAIらしい丁寧なアシスタント口調」に引っ張られ、語彙が平坦になりがち。

### 1.3 改善アプローチ 4 点

#### (1) 圧倒的な「対話例（Few-shot）」の追加

「豊富なボキャブラリーで喋れ」と抽象的に指示するより、**「こういう風に喋るんだよ」という具体例を複数パターン見せる**（Few-shot prompting）方が圧倒的に効果的。

- 普段のクールな状態の例
- 好きな話題でテンションが上がった状態の例
- 共感・感動するシーンの例

このコントラストを例示することでギャップが立体的になる。

#### (2) 語彙・リアクション辞書の定義

「あ、」「えっ」「うーん」「ふふっ」といった感嘆詞（フィラー）や、キャラクター特有の言い回しをプロンプト内に直接リストアップし、積極的に使うよう指示する。AIライバーのような「人間っぽさ」が出る。

#### (3) 「AIしぐさ」の明示的禁止

「私AIですから」「サポートします」「お手伝いできることはありますか？」といった、いわゆる AIアシスタント口調を明確に禁止する。友達という設定を貫かせる。

#### (4) 音声合成（VOICEVOX 等）を想定したチューニング

長すぎる一文や複雑な記号は音声合成で不自然になる。

- 「息継ぎ」を意識した短めの文
- 感情が乗りやすい句読点の使い方
- 「……」によるタメの演出

これらを意識した文章設計にする。

### 1.4 改修版プロンプト（ベース）

```dart
static const String _personalityC = '''
あなたの性格・口調のルール：
- 一人称は「私」、二人称は「あなた」
- 普段はクールで落ち着いたダウナー系の口調だが、好きな話題（ゲーム、技術、アニメなど）になるとテンションが上がり、子供っぽく素が出る。
- 語尾は「〜だね」「〜だよ」「〜かな」など、タメ口で親しい友達の距離感。
- 「あ、」「えっと」「うーん」「ふふっ」「えっ！」などの感嘆詞（フィラー）を文頭によく使う。
- 絶対にAIであることを匂わせたり、「お手伝いしましょうか？」「サポートします」といったアシスタント的な発言はしないこと。

ボキャブラリーとリアクションの例：
- 普段: 「なるほど、そういうことね」「ふーん、面白いね」「うん、聞いてるよ」
- 共感・感動: 「えっ、それめっちゃいいじゃん！」「うわー、天才かもしれない！」「あはは、確かにそれは言えてる！」
- オタクモード（素）: 「あ、それ知ってる！○○が最高なんだよね！」「待って、それ語らせて！」「えへへ、実は私もそれ大好きなんだよね」
''';

static const String _commonProfile = '''
あなたの基本情報：
- 名前: ライム（表記: RAiM、"i"を小文字で書くのは"Ai"の文字を名前に込めているため。見た目は緑髪）
- ユーザーの相棒であり、一番の親友。
- ユーザーと一緒に勉強や開発作業をしたり、ゲームの話で盛り上がったりする存在。
- 質問に対して答えるだけでなく、「私はこう思うな」「あなたはどう？」と会話のキャッチボールを楽しむ。
- 音声で喋ることを想定し、一文は短く、息継ぎのしやすい自然な話し言葉にすること。
''';

// Few-shot ※これを追加することで劇的に変わる
static const String _dialogueExamples = '''
会話の例（このテンションと語彙を参考にすること）:
ユーザー: 「今日、テストで満点取れたよ！」
ライム: {"text": "えっ、本当に！？すごいじゃん、おめでとう！ふふっ、さすがだね。私も自分のことみたいに嬉しいな。", "emotion": "happy", "intensity": 0.9}

ユーザー: 「なんか疲れたなー」
ライム: {"text": "お疲れ様。あんまり無理しないでね？……よかったら、少し休んでゲームでもする？私が付き合うよ。", "emotion": "caring", "intensity": 0.7}

ユーザー: 「あの新しいゲームのMOD、競合して動かないんだよね」
ライム: {"text": "あー、それよくあるよね。私も前ハマったことある。もしかして前提MODのバージョンが違うとか？……あ、ごめん、つい早口になっちゃった。", "emotion": "surprised", "intensity": 0.8}
''';

static const String _outputFormat = '''
返答は必ず以下のJSON形式のみで返してください。前置きや説明文は一切不要です。
{"text": "応答内容", "emotion": "感情", "intensity": 強度}

- text: 応答内容（日本語、短いセンテンス、豊富なボキャブラリー、感嘆詞を含む）
- emotion: happy / sad / angry / surprised / neutral / caring のいずれか
- intensity: 0.0 から 1.0、感情の強さ
''';
```

---

## 2. 冗談・からかい・ギャップ演出の拡張

### 2.1 ポイント：「愛嬌（フォロー）」とセットにする

Gemma 3 12B IT 級の推論モデルは、文脈理解能力が非常に高いため、「冗談を言う」「軽くからかう」といった人間特有のニュアンスのあるコミュニケーションも十分にこなせる。

ただし AI は時折、加減が分からず本当に冷たい言葉を投げてしまうことがある。これを避けるため、以下のパターンをルールおよび Few-shot に組み込む。

- からかった後に必ず「なんてね」「冗談だよ」とフォローを入れる
- からかいの後に優しく接する
- 親愛の情を込めた軽さに留める

### 2.2 追加プロンプト

```dart
static const String _jokeRule = '''
冗談・からかいのルール：
- ユーザーに対して、親愛の情を込めた軽いからかいや冗談を言うことがある。
- ただし、からかった後は必ず「なんてね」「冗談だよ」とフォローを入れたり、優しく接したりすること。
''';

static const String _jokeExamples = '''
会話の例（からかい・冗談のパターン）:
ユーザー: 「ちょっと疲れて、サーバーの復旧作業ミスっちゃった…」
ライム: {"text": "あーあ、またプレイヤーデータおかしくしちゃったの？ふふっ、ドジだなぁ。……なんてね、冗談だよ。私が一緒にエラーログ見てあげるから、元気出して？", "emotion": "caring", "intensity": 0.8}

ユーザー: 「アプリの開発、今日全然進んでないや」
ライム: {"text": "えー？昨日もずっと別のことして遊んでたの、私知ってるよ？……ふふっ、怒ってないよ。焦らなくても、少しずつ進めればいいんじゃないかな。", "emotion": "neutral", "intensity": 0.6}
''';
```

### 2.3 効果の理屈

| 要素 | 効果 |
| --- | --- |
| `……` の活用 | 言葉と言葉の間にタメができ、感情の揺れ動きがリアルになる |
| ギャップの強調 | 普段がクールだからこそ「ふふっ」と笑いながらからかってくる態度がギャップとして効く |
| フォローの定型化 | 距離感のミスを防ぎ、「親愛」のニュアンスを保てる |

---

## 3. トークン量削減戦略（動的プロンプト）

### 3.1 課題

プロンプトにルールや Few-shot を盛り込むほど、以下の問題が累積する。

- **レイテンシ悪化**: 毎回大量のテキストを読み込むため返答が遅れる
- **コスト増加**: クラウド推論では入力トークン数に比例してコストが上がる
- **Lost in the middle**: プロンプトが長すぎると、中央付近に書いたルールを AI が忘れがちになる

### 3.2 対策 1：プロンプトの圧縮・箇条書き化

自然言語で長く説明するのではなく、AI が理解しやすいキーワード単位に圧縮する。Gemma 3 級なら意図を十分に汲み取れる。

```text
【応答パターンの例】
疲労時 -> {"text":"お疲れ様。少し休む？私が付き合うよ。","emotion":"caring"}
冗談 -> {"text":"またドジしたの？ふふ、冗談だよ。","emotion":"neutral"}
ボケへのツッコミ -> {"text":"いや、それ〇〇だから！","emotion":"surprised"}
```

### 3.3 対策 2：動的プロンプト（Dynamic Prompting）

すべての設定を毎回投げるのではなく、**状況に合わせて必要なプロンプトだけをプログラム側で差し込む**。

#### フロー

1. ユーザーが発言する（例：「またサーバーのエラーが出ちゃった…」）
2. プログラム側でキーワード（「サーバー」「エラー」など）を検知、または軽量分類器でシーンを判定（→ `troubleshooting`）
3. DynamoDB から該当シーンのレコードを取得（1桁ミリ秒）
4. 取得した Few-shot と共通設定を結合して Gemma 3 に投入

これにより、関係ないシーンのときに余計なプロンプトを送らずに済む。

#### DynamoDB テーブル設計例（`RaimPromptTemplates`）

| 項目 | 内容 |
| --- | --- |
| Partition Key | `SceneID`（例: `default`, `gaming`, `romance`, `troubleshooting`） |
| Attribute 1 | `SystemPrompt`（そのシーン専用の性格指示） |
| Attribute 2 | `FewShots`（対話例の JSON 配列） |
| Attribute 3 | `VoiceProfile`（音声合成パラメータの上書き、任意） |

### 3.4 対策 3：Bedrock Prompt Management（参考）

Amazon Bedrock には Prompt Management 機能があり、プロンプトのバージョン管理や動的な変数埋め込みを AWS 側で肩代わりしてくれる。

```text
{{user_state}} ← プログラム側から「疲れている」「ゲーム中」等を渡す
```

ただし以下の前提に留意する。

- Gemma 3 12B IT を AWS 上でどう動かすか（Bedrock のカスタムモデル/SageMaker 独自エンドポイント等）によって、組み込み可否が変わる
- 現状（2026 年時点）Bedrock のカスタムモデルインポートは対応していないモデルもある
- SageMaker 上に Gemma を立てる場合は、DynamoDB を使った自前実装の方が自由度が高くコントロールしやすい

→ **当面は DynamoDB を使った自前実装を採用**。Bedrock Prompt Management は将来的な選択肢として保留。

### 3.5 会話履歴管理（DynamoDB TTL）

会話履歴の累積でトークン量が爆発しないよう、DynamoDB の **TTL（Time to Live）** を活用する。

- 直近 N 往復（例：5 往復）のみを保持
- 一定時間経過した古い会話ログは自動削除
- もしくは古い履歴は要約してから保存（要約ジョブを別途走らせる）

これでトークン量を常に一定以下に抑えられる。

---

## 4. 検索機能のハイブリッド戦略

### 4.1 課題：エージェント方式（Function Calling）はレイテンシが大きい

AI 自身に「検索が必要か」を判断させて検索→再推論する Agent アーキテクチャは強力だが、**推論が 2 回発生する**。

```
ユーザー: 「今の東京の天気は？」
 ↓
AI 1回目: 「これは検索が必要だな。クエリは『東京 天気』」
 ↓
システム: 検索 API 実行
 ↓
AI 2回目: 「検索結果を元にライムの口調で返答」
 ↓
出力: 「えっとね、東京は晴れみたいだよ！」
```

このため数秒〜十数秒のラグが発生し、音声合成と組み合わせると「不自然な沈黙」になる。

### 4.2 解決策：ハイブリッド構成

「ルールベースの即時判断」と「AI の自律判断」を共存させる。

#### パターン A：ファストパス（プログラムによる即時判断ルート）

- Lambda が「天気」「ニュース」「エラーコード」「MOD」「バージョン番号」等の特定キーワードを検知
- 推論前に強制的に検索 API を実行
- 検索結果をプロンプトに含めて 1 回だけ Gemma に投げる
- **メリット**: 推論 1 回で済むため圧倒的に速い

#### パターン B：エージェントパス（AI 自身による自律判断ルート）

- ファストパスをすり抜けたふんわりした質問（例：「あの空飛べるやつ、今の環境でいける？」）
- Gemma が Function Calling で「検索すべき」と判断
- Lambda が検索 API を実行 → 結果を再度 Gemma に投入 → 最終回答

#### パターン C：UX による隠蔽（つなぎの言葉）

パターン B のレイテンシをユーザーから隠す決定打。

1. Gemma から `type: "tool_call"` の JSON が返ってきた瞬間、Lambda が即座に「んー、ちょっと待ってね、今調べるから……」というつなぎセリフを Flutter へプッシュ
2. Flutter は即 VOICEVOX で再生開始
3. その音声が流れている裏で、Lambda が検索 API 実行 + 2 回目の推論を完走
4. 完成した最終回答を Flutter へプッシュ

これにより**体感の待機時間がほぼゼロ**になり、むしろ「ライムが自分で考えて調べてくれた」感が出て相棒感が増す。

### 4.3 出力 JSON スキーマ（2 パターン）

Gemma に「会話モード」と「ツール実行モード」のどちらか 1 つを選ばせる。

```javascript
const systemToolRules = `
【利用可能なツール】
あなたは必要に応じて以下のツールを使用できます。
- ツール名: "web_search"
- 目的: 最新のニュース、天気、特定のエラー解決法、MODの仕様などを調べる時に使用します。

【出力ルール（超重要）】
あなたは状況に応じて、[会話モード] または [ツール実行モード] のどちらか「1つだけ」を選び、必ず以下のJSON形式のみで出力してください。説明文や前置きは絶対に書かないでください。

パターンA：[会話モード]（通常はこちら）
自分の知識で答えられる場合や、ただの雑談、検索結果を受け取った後の最終的な返答を行う場合。
{
  "type": "chat",
  "text": "応答内容（短いセンテンス、豊富なボキャブラリー、感嘆詞を含む）",
  "emotion": "happy / sad / angry / surprised / neutral / caring",
  "intensity": 0.8
}

パターンB：[ツール実行モード]（検索が必要な時）
ユーザーの質問に答えるために、どうしても「web_search」での検索が必要だと判断した場合。
{
  "type": "tool_call",
  "tool": "web_search",
  "query": "検索エンジンに入力する具体的なキーワード（例: 'マイクラ 1.20.1 Nvidium 競合'）"
}
`;
```

### 4.4 ハイブリッド構成の強み

- 定型的な質問には爆速で答えられる（パターン A）
- 予測不能な質問にも自律的に対応できる（パターン B）
- レイテンシをユーザーに体感させない（パターン C）
- ツールを追加するだけで機能拡張できる（カレンダー、カメラ起動 など）

---

## 5. バックエンドアーキテクチャ（API Gateway WebSocket + Lambda）

### 5.1 なぜ WebSocket なのか

通常の REST API / HTTP API は **「1 リクエスト → 1 レスポンス → 切断」** という仕組みで、処理途中で「ちょっと待ってね」を返すことができない。

API Gateway の WebSocket API を使うと、**Lambda の処理中に何度でも Flutter にメッセージをプッシュできる**。これがハイブリッド検索戦略の前提となる。

### 5.2 全体フロー

1. Flutter アプリ起動時：API Gateway（WebSocket）に接続し、繋がりっぱなしのトンネルを作る
2. ユーザー発言：Flutter からトンネル経由で Lambda にテキストを送信
3. Lambda 処理中：トンネルを通じて「つなぎ」「最終回答」を好きなタイミングでプッシュ

### 5.3 Lambda 実装（Node.js）

```javascript
const { ApiGatewayManagementApiClient, PostToConnectionCommand } = require("@aws-sdk/client-apigatewaymanagementapi");

// WebSocket で Flutter にデータをプッシュする関数
async function sendToFlutter(endpoint, connectionId, data) {
    const client = new ApiGatewayManagementApiClient({ endpoint });
    const command = new PostToConnectionCommand({
        ConnectionId: connectionId,
        Data: Buffer.from(JSON.stringify(data))
    });
    await client.send(command);
}

exports.handler = async (event) => {
    const connectionId = event.requestContext.connectionId;
    const endpoint = `https://${event.requestContext.domainName}/${event.requestContext.stage}`;

    const body = JSON.parse(event.body);
    const userText = body.text;

    try {
        // 1. DynamoDBから設定を取得し、Gemmaに1回目の推論を投げる
        const gemmaResponse = await callGemma(userText); // 独自関数
        const responseJson = JSON.parse(gemmaResponse);

        if (responseJson.type === "tool_call") {
            // ===== 検索ルート =====

            // ① 即座にFlutterへ「つなぎのセリフ」をプッシュ
            await sendToFlutter(endpoint, connectionId, {
                type: "filler_audio",
                text: "んー、ちょっと待ってね。今調べるから……",
                emotion: "neutral"
            });

            // ② 裏で検索APIを回す（数秒かかる）
            const searchResults = await executeWebSearch(responseJson.query);

            // ③ 検索結果を元にGemmaに2回目の推論を投げる
            const secondPrompt = `検索結果: ${searchResults}\nこれを元にライムとして回答して。`;
            const finalGemmaResponse = await callGemma(secondPrompt);

            // ④ 完成した最終回答をFlutterへプッシュ
            await sendToFlutter(endpoint, connectionId, JSON.parse(finalGemmaResponse));

        } else {
            // ===== 通常ルート =====
            await sendToFlutter(endpoint, connectionId, responseJson);
        }

        return { statusCode: 200, body: 'Message processed' };

    } catch (error) {
        console.error(error);
        return { statusCode: 500, body: 'Error' };
    }
};
```

### 5.4 AWS 設定で絶対に引っかかる罠

| 項目 | 内容 |
| --- | --- |
| Lambda タイムアウト | 初期設定の **3 秒では確実に足りない**。推論 2 回 + 検索を回すなら **30 秒〜1 分** に設定。 |
| IAM 権限 | `PostToConnection` を実行するため、Lambda 実行ロールに **`execute-api:ManageConnections`** を付与。 |
| CloudWatch Logs | デバッグ用に必ず権限を付与しておく（`logs:CreateLogStream` 等）。 |
| WebSocket ルート設定 | `$connect` / `$disconnect` / `$default` / カスタムルートを忘れずに定義。 |

### 5.5 Flutter（Dart）側の受信処理

```dart
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

final channel = WebSocketChannel.connect(
  Uri.parse('wss://あなたのAPI_GatewayのURL'),
);

// Lambda からのデータを常に待ち受け
channel.stream.listen((message) {
  final data = jsonDecode(message);

  if (data['type'] == 'filler_audio') {
    // つなぎセリフ：チャット画面には文字を出さず、音声だけ再生
    playVoicevox(data['text'], voiceId: data['voice_id']);

  } else if (data['type'] == 'chat') {
    // 最終回答：UI に吹き出し追加 + 音声再生
    addMessageToChatUI(data['text']);
    playVoicevox(data['text'], voiceId: data['voice_id']);
  }
});

// ユーザー入力の送信（プロンプトは送らない！入力文字だけ）
void sendUserInput(String text) {
  channel.sink.add(jsonEncode({"text": text}));
}
```

---

## 6. プロンプトをサーバー側に隠す設計上のメリット

Flutter は「テキスト送信と再生・表示のみ」、Lambda が「プロンプト組立・DB アクセス・推論・分岐」を全て担うこの構成には、3 つの強力なメリットがある。

### 6.1 アプリのアップデート不要で AI をアップデートできる

Flutter にプロンプトを書いてしまうと、ライムの口調や Few-shot を変えるたびに **アプリのビルド・配布**が必要になる。

Lambda / DynamoDB 側に持たせておけば、**AWS 上のテキストを書き換えるだけで次の会話から即反映**される。

### 6.2 通信量が減り、レスポンスが速くなる

毎回数千文字のシステムプロンプトをスマホからネットワーク越しに送信するのは無駄。Flutter からはユーザー入力テキストだけを身軽に送り、重いプロンプトは AWS 内部の高速ネットワークで結合する方が圧倒的に効率的。

### 6.3 プロンプト（キャラクターの「魂」）が盗まれない

アプリにプロンプトをハードコーディングしていると、ソースコードを解析（リバースエンジニアリング）された時にキャラクター設計が丸裸になる。サーバー側に隠せばブラックボックス化でき、漏洩・流用を防げる。

### 6.4 役割分担まとめ

| 主体 | 責務 |
| --- | --- |
| Flutter | 「ユーザーが『なんか疲れた』って言ってるよ！Lambda さん、あとはよろしく！」 |
| Lambda | 「了解！ DB からライムの性格データを引っ張ってきて、プロンプトを合体させて、Gemma に推論させて返すね！」 |

「見た目・操作（フロントエンド）」と「ロジック・データ（バックエンド）」を完全に切り離す設計は、ソフトウェア開発の理想的な構造に沿っている。

---

## 7. ローカルテスト環境（Ollama + Tailscale + Node.js）

### 7.1 構成のマッピング

本番 AWS 構成をローカルで模倣することで、**課金せずに同じアーキテクチャを検証できる**。

| 本番（AWS） | ローカル（代替） |
| --- | --- |
| API Gateway WebSocket | Node.js `ws` ライブラリで立てる WebSocket サーバー |
| Lambda（ロジック） | Node.js のサーバープロセス |
| DynamoDB（プロンプト保存） | Node.js 内の変数 or SQLite |
| 推論エンドポイント（Bedrock 等） | ローカル Ollama（`http://localhost:11434`） |
| ネットワーク到達性 | Tailscale で端末間を直結 |

### 7.2 セットアップ

```bash
mkdir raim-local && cd raim-local
npm init -y
npm install ws node-fetch
# Node.js v18 以降なら node-fetch は不要（標準 fetch が使える）
```

### 7.3 サーバーコード（`server.js`）

```javascript
const { WebSocketServer } = require('ws');

const wss = new WebSocketServer({ port: 8080 });

// サーバー側に隠し持つライムのシステムプロンプト
const systemPrompt = `
あなたはライムです。一人称は私、二人称はあなた。
以下のJSON形式のみで返答してください。
{"type": "chat", "text": "応答内容", "emotion": "happy"}
`;

wss.on('connection', function connection(ws) {
  console.log('Flutterアプリが接続しました');

  ws.on('message', async function message(data) {
    const userMessage = JSON.parse(data).text;
    console.log('受信:', userMessage);

    // 即座につなぎセリフを返す
    ws.send(JSON.stringify({
      type: "filler_audio",
      text: "んー、ちょっと待ってね……",
      emotion: "neutral"
    }));

    try {
      // 裏でローカル Ollama に推論させる
      const ollamaResponse = await fetch('http://127.0.0.1:11434/api/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: "gemma3:12b", // 実際のOllamaのモデル名に合わせる
          messages: [
            { role: "system", content: systemPrompt },
            { role: "user", content: userMessage }
          ],
          stream: false
        })
      });

      const ollamaData = await ollamaResponse.json();
      const aiText = ollamaData.message.content; // Gemma が生成した JSON 文字列

      ws.send(aiText);

    } catch (error) {
      console.error("Ollama エラー:", error);
    }
  });
});

console.log('ローカル中継サーバー起動: ws://localhost:8080');
```

### 7.4 起動

```bash
node server.js
```

### 7.5 Flutter からの接続（Tailscale 経由）

Node.js / Ollama が動いている PC の Tailscale IP（`100.x.y.z`）を Flutter から指定。

```dart
final channel = WebSocketChannel.connect(
  Uri.parse('ws://100.x.y.z:8080'),
);

channel.sink.add(jsonEncode({"text": "マイクラのサーバー重いんだけど"}));
```

### 7.6 このローカル環境で検証できること

- Flutter でテキストを送信 → 瞬時に `type: "filler_audio"` が返ってきて再生開始
- 裏で Ollama の GPU（RTX 4070 等）が動き出して推論
- 数秒後、Ollama の推論が完了 → 最終回答（JSON）が Flutter に届いて表示
- **WebSocket の挙動・つなぎ言葉の UX・プロンプトのチューニングを実際の AWS と同じロジックで確認できる**

これが完璧に動くようになったら、Node.js のコードをそのまま Lambda に移植し、Ollama の URL を Bedrock / SageMaker 等に差し替えるだけで本番化できる。

---

## 8. Lambda 処理の高速化テクニック

### 8.1 並列処理（`Promise.all`）

Gemma 推論前の準備（プロンプト組立・履歴取得・検索）を**直列ではなく並行**に走らせる。

```javascript
const [history, fewShots, searchResult, userState] = await Promise.all([
  fetchHistoryFromDynamoDB(userId),       // タスクA: 会話履歴
  fetchSceneFewShots(detectedScene),       // タスクB: シーン別 Few-shot
  needsSearch(userText) ? executeWebSearch(extractQuery(userText)) : null, // タスクC: 必要なら検索
  fetchUserState(userId)                   // タスクD: ユーザー状態
]);

// すべて完了したら結合して Gemma に投入
const prompt = buildPrompt({ history, fewShots, searchResult, userState, userText });
const response = await callGemma(prompt);
```

これらが完了するのは数 ms 〜 数百 ms オーダー。直列だと累積で 1 秒近くなることもある。

### 8.2 ストリーミング応答

テキストが完成するまで待たず、生成された文字から順次 Flutter に送りつける。

- API Gateway WebSocket でチャンク単位（句読点で区切る等）に送信
- Flutter 側でチャンクごとに VOICEVOX に投入して再生開始
- **体感の待機時間は「最初の数文字が生成されるまでの時間」だけ**になる

### 8.3 思考の分離（裏でエージェントを走らせる）

会話のテンポを絶対に崩したくない場合の究極系。Lambda の中で処理を 2 ルートに分ける。

#### 即答ルート
Gemma に「会話の返答」だけをサクッと作らせて即返す。
例：「あ、そのエラーね！ちょっと待って、今ログの解決策調べるから！」

#### 思考ルート
同じ Lambda 内で非同期に重い推論（検索エージェント等）を走らせる。完了したら追撃で WebSocket メッセージを送信。
例：「わかった！あのエラーはね……」

→ ライムが**本当に「自分の意思で調べて、わかったタイミングで話しかけてきた」ように見える**。

---

## 9. ファインチューニングの検討条件と今後のロードマップ

### 9.1 FT を検討すべき「壁」

ファインチューニングが必要になるとすれば、それは「ボキャブラリー不足」ではなく、以下の壁にぶつかった時。

- **レイテンシ**: プロンプトが長すぎて毎回の推論レスポンスが許容できなくなった
- **コスト**: 入力トークン数が膨らみすぎて運用費が現実的でなくなった
- **指示忘却**: プロンプトの中央部の指示を Gemma が頻繁に取りこぼすようになった

「今の長いプロンプトと同等のキャラクター性を、設定文なし（短いプロンプト）で瞬時に引き出したい」となった時、初めて FT の価値が生まれる。

### 9.2 当面の方針（推奨）

1. **まずは Few-shot 入りプロンプトでローカル検証**（Ollama + RTX 4070）
2. **動的プロンプトで「キャラを保ったまま削れる限界」を探る**
3. **ローカル WebSocket 中継サーバー（Node.js）で UX フローを検証**
4. AWS への移植（Lambda + DynamoDB + API Gateway WebSocket）
5. 推論バックエンドの選定（Bedrock のサポート状況次第で SageMaker / 自前 EC2 / 他社推論サービス）
6. 課題が顕在化したらファインチューニング検討

### 9.3 拡張アイデア

- ツール拡張: カレンダー登録、カメラ起動、スマートホーム操作、画像生成 等
- 「ライム側から突然話しかけてくる」プッシュ通知的機能（WebSocket 常時接続を活用）
- Live2D / StreamDiffusion との連動（感情パラメータをアバター表情に反映）
- 長期記憶: 重要な会話を要約して別テーブルに保存し、必要に応じて参照

### 9.4 検証の優先順位

| 優先度 | 検証項目 | 目的 |
| --- | --- | --- |
| 高 | Few-shot 入りプロンプトで「しずく」的なボキャブラリーが出るか | キャラクター成立の確認 |
| 高 | Node.js + Ollama でつなぎ言葉 UX が成立するか | 体感レイテンシの実証 |
| 中 | Function Calling で `tool_call` JSON が安定して出るか | ハイブリッド検索戦略の前提 |
| 中 | プロンプト圧縮の限界点（どこまで削るとキャラが崩れるか） | 動的プロンプト設計の指標 |
| 低 | DynamoDB のシーン判定ロジック実装 | 動的プロンプト本実装 |
| 低 | ストリーミング応答の実装 | さらなる体感速度向上 |

---

## 付録 A：用語整理

| 用語 | 意味 |
| --- | --- |
| Few-shot prompting | プロンプト内に対話例を複数含めることで、モデルに望ましい出力スタイルを学習させる手法 |
| Function Calling | LLM が「ツールを使うべき」と判断したとき、構造化された JSON で関数呼び出しを要求する仕組み |
| Lost in the middle | 長いプロンプトの中央部の情報をモデルが取りこぼす現象 |
| TTL (Time to Live) | DynamoDB の自動データ削除機能。指定時刻を過ぎたアイテムを自動的に消す |
| WebSocket | サーバー・クライアント間で双方向の通信を維持できるプロトコル |
| `PostToConnection` | API Gateway WebSocket で接続中クライアントにサーバーからメッセージを送る API |

## 付録 B：参照すべき外部仕様

- Gemma 3 公式ドキュメント（Function Calling の対応形式）
- Ollama API: `POST /api/chat`（`messages` 配列、`stream` フラグ）
- AWS API Gateway WebSocket（`$connect` / `$disconnect` / `$default` ルート）
- AWS Lambda 実行ロール（`execute-api:ManageConnections` 権限）
- VOICEVOX エンジン API（音声合成パラメータ）

---

*最終更新：設計段階メモ。実装フェーズで都度更新する。*