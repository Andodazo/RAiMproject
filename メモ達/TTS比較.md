# RAiM TTS技術比較・選定ドキュメント

## このドキュメントについて

RAiM プロジェクトで採用する TTS（Text-to-Speech、音声合成）の選定根拠と、検証対象の各エンジンの詳細をまとめたもの。

**現状のプロトタイプ**: VOICEVOX（春日部つむぎ、speaker=8）をローカル動作で統合済み

**最終方針**: VOICEVOX を本番採用、Irodori-TTS と uPiper は比較検証用として並行で試す

---

## 結論サマリー

| TTS | 採用状況 | 動作環境 | 月コスト | 用途 |
|---|---|---|---|---|
| **VOICEVOX** | ✅ 本番採用 | AWS Lambda(本番) / ローカル(開発) | $0〜30 | デモ・本番運用 |
| **Irodori-TTS** | 🔬 検証 | 自宅 RTX 4070 + Tailscale | $10〜20(電気代) | Voice Design 実験、比較資料 |
| **uPiper** | 🔬 検証 | iOS/Android 実機(Unity 6 必須) | $0 | モバイルオフライン動作検証 |

**選定理由**: VOICEVOX は知名度・コスト・安定性・キャラクター完成度のバランスが最良。他の2つは「比較した上で選んだ」根拠資料として位置付け。

---

## 1. VOICEVOX（本番採用）

### 概要

- 開発: ヒホ氏（コミュニティ）
- ライセンス: 各キャラごとに異なる（春日部つむぎは「VOICEVOX:春日部つむぎ」クレジット表記で商用利用可）
- 公式サイト: https://voicevox.hiroshiba.jp/
- Docker Hub: https://hub.docker.com/r/voicevox/voicevox_engine

### 技術仕様

- アーキテクチャ: VITS ベース、HTS音声合成
- 入力: 日本語テキスト
- 出力: WAV形式（22050Hz, 16bit）
- API: HTTP REST（localhost:50021）
- 言語サポート: 日本語のみ
- 動作: **CPU で実用速度**（GPU 不要）

### 音質評価

- **コミュニティ評価**: 国内 TTS で最高クラス
- キャラクター完成度: ◎（春日部つむぎ等は声優の声をベースに学習）
- 感情表現: 各キャラに「ノーマル/あまあま/ツンツン/セクシー」等のスタイル
- レイテンシ: 1〜2秒程度

### RAiM 採用済み話者候補

```
8  : 春日部つむぎ（プロトタイプ採用、元気なギャル風）
9  : 波音リツ（クール・低めな女性声）
10 : 雨晴はう（優しくおっとり）
20 : もち子さん（落ち着いたお姉さん）
46 : SAYO（落ち着いた大人）
52 : 夜語トバリ（ダウナーな大人の女性声）
54 : 夜桜よる（クールで知的なお姉さん）
74 : ミタマ（和風でミステリアス）
```

性格 A/B/C パターンに応じて話者を切り替える設計が可能。

### AWS デプロイ構成（本番）

#### 構成A: Lambda Web Adapter（LWA、推奨）

```
[モバイルアプリ]
    ↓ HTTPS
[API Gateway(response-streaming)]
    ↓
[Lambda(LWA)] ← VOICEVOX Docker そのまま動かす
```

- メリット: 従量課金、完全サーバーレス、Cold Start 受容可
- コスト: 月 $0〜数ドル（卒研デモ規模）
- 参考: Qiita「VOICEVOX EngineとLambda Web Adapterでサーバレスずんだもんを開発した話」

#### 構成B: EC2 + Docker

```bash
# EC2 t3.micro（無料枠も可）にて
docker run -d -p 50021:50021 voicevox/voicevox_engine:cpu-latest
```

- メリット: 常時稼働、Cold Start なし
- コスト: t3.micro で月 $8（無料枠なら $0）

#### 構成C: ECS Fargate

- メリット: スケーリング自動、運用楽
- コスト: 月 $15〜

### 既存実装（プロトタイプ）

```dart
// lib/services/tts_service.dart
class TTSService {
  final String baseUrl;  // http://localhost:50021
  final int speakerId;   // 8 = 春日部つむぎ
  
  Future<void> speak(String text) async {
    // Step 1: audio_query
    // Step 2: synthesis
    // Step 3: audioplayers で WAV 再生
  }
}
```

### メリット・デメリット

**メリット**
- 知名度高、卒研で「VOICEVOX 採用」がわかりやすい
- CPU で動作、AWS で激安運用可能
- キャラクター完成度が高い（声優ベース）
- Docker 公式イメージあり、デプロイ容易
- 商用利用も明確（クレジット表記のみ）

**デメリット**
- キャラクター固定（ライムのオリジナル声は作れない）
- 日本語のみ対応
- 感情表現は限定的（スタイル切替のみ）

---

## 2. Irodori-TTS（検証対象）

### 概要

- 開発: Aratako 氏（Chihiro Arata）
- 公開: 2026年3月
- ライセンス: MIT（倫理規定あり：なりすまし禁止等）
- GitHub: https://github.com/Aratako/Irodori-TTS
- Hugging Face: https://huggingface.co/Aratako/Irodori-TTS-500M-v2

### 技術仕様

- アーキテクチャ: **Rectified Flow Diffusion Transformer (RF-DiT)** + Flow Matching
- 入力: 日本語テキスト + 絵文字（感情制御）
- 出力: WAV形式
- API: Gradio Web UI + CLI、コミュニティ製 OpenAI 互換 API ラッパーあり
- 言語サポート: 日本語のみ
- 動作: **GPU 推奨**（CPU だと実用不可、5秒音声に 90秒）

### 音質評価

- コミュニティ評価: **「日本語に最強クラスの対応力」**（ブログ・X等）
- VOICEVOX に対する優位性: 自由度（ゼロショット声クローニング、Voice Design）
- 制限事項: 漢字読み精度が同規模他モデル比やや弱め（複雑な漢字はひらがな・カタカナ事前変換推奨）

### 3つのユースケース

#### A. リファレンス音声クローニング

10秒程度の参考音声を与えると、その声で新しいセリフを生成。
→ 「お気に入りの声をライムにしたい」場合に使える。

#### B. 絵文字による感情制御

40種類以上の絵文字をテキスト中に挿入することで感情・スタイルをコントロール。
例: 「こんにちは😊」「やめてよ😡」

→ **LLM 出力の emotion → 絵文字変換 → Irodori-TTS** という設計が綺麗に組める。

#### C. Voice Design（プロンプトで声質指定）

日本語プロンプトで声質を指定。
例: 「明るく知的な若い女性の声、20代後半、落ち着いた話し方」

→ **ライムの3つの性格パターンで別の声を設計可能**。
- A: 知的相棒 → 「落ち着いた知的な女性の声、20代後半」
- B: クール先輩 → 「クールでハスキーな女性の声、30代前半」
- C: ギャップ萌え → 「明るく元気な女性の声、20代前半」

### 動作環境

- Python 3.10 + uv
- PyTorch（CUDA 12.8 推奨）
- NVIDIA GPU（VRAM 8GB 以上推奨）
- RTX 5070 Ti: 5秒音声 → 約3秒で生成
- RTX 4070（自宅PC）: 同程度想定
- CPU: 5秒音声 → 約90秒（実用不可）

### インストール手順（自宅 RTX 4070）

```bash
# 1. クローン
git clone https://github.com/Aratako/Irodori-TTS.git
cd Irodori-TTS

# 2. 依存パッケージインストール（uv 必要）
uv sync

# 3. Gradio Web UI 起動
uv run python gradio_app.py --server-name 0.0.0.0 --server-port 7860

# 4. ブラウザで http://100.x.x.x:7860 にアクセス（Tailscale経由）
```

### AWS デプロイの検討結果

| 構成 | 月コスト | 採用判定 |
|---|---|---|
| EC2 g4dn.xlarge（NVIDIA T4） | 約 $380 | ❌ 卒研予算オーバー |
| EC2 g5.xlarge（NVIDIA A10G） | 約 $730 | ❌ 卒研予算オーバー |
| SageMaker GPU エンドポイント | 約 $400〜 | ❌ 卒研予算オーバー |
| ECS Fargate（CPU） | $30〜 | ❌ 動作するが遅すぎ実用不可 |
| Lambda + GPU | - | ❌ Lambda は GPU 非対応 |
| **EC2 スポット（g4dn）** | 約 $120〜250 | △ 中断リスクあり |
| **自宅 RTX 4070 + Tailscale** | 電気代のみ（約 $15） | ✅ 卒研期間中の現実解 |

**結論**: AWS では予算オーバー、自宅 PC ホストで卒研期間を乗り切る。

### コミュニティの活用事例

- VTuber: 個人開発者がローカル AI VTuber に組み込み
- ASMR・ボイスドラマ制作
- Open-LLM-VTuber に OpenAI 互換 API 経由で統合

### メリット・デメリット

**メリット**
- 日本語の自然さがコミュニティで高評価
- Voice Design でライムのオリジナル声を自由設計可能
- 絵文字感情制御が LLM 出力と相性◎
- MIT ライセンスで自由度が高い
- ゼロショット声クローニング機能

**デメリット**
- GPU 必須、AWS デプロイは予算オーバー
- 漢字読み精度がやや弱い（事前にひらがな・カタカナ変換が必要なことも）
- まだ若いプロジェクト（2026/03 リリース、サポート未知数）
- モバイル直接動作不可（サーバー必要）
- 倫理規定あり（なりすまし禁止、ディープフェイク禁止）

---

## 3. uPiper（検証対象）

### 概要

- 開発: ayutaz 氏（ようさん）
- ベース: piper-plus（同作者の Piper フォーク）
- ライセンス: Apache 2.0
- GitHub: https://github.com/ayutaz/uPiper

### 技術仕様

- アーキテクチャ: **VITS** → **MB-iSTFT-VITS2**（新世代）
- Unity AI Inference Engine（旧 Sentis）ベース
- 入力: 多言語テキスト（日/英/中/西/仏/葡/韓）
- 出力: Unity AudioClip
- 動作: **Unity 6 必須（6000.0.58f2 以上）**
- プラットフォーム: Windows/Mac/Linux/Android/iOS/WebGL

### 音質評価

- コミュニティ評価: 中〜中の上、軽量さが売り
- 作者本人の発信: 「精度向上中、まだ改善の余地あり」
- VOICEVOX には負ける（声質・キャラクター性で）
- VOICEVOX級の音質を期待すると物足りない可能性

### 主要モデル

- **multilingual-test-medium**: 多言語（6言語）対応、38MB
- **tsukuyomi-chan**: つくよみちゃんの声（日本語特化）
- **ja_JP-test-medium**: Prosody 対応の日本語モデル

### バージョン履歴（重要）

| バージョン | リリース | 内容 |
|---|---|---|
| v0.1.0 | 2025/09 | 初版、iOS なし |
| v0.2.0 | 2025/10 | **iOS 対応追加** |
| v1.0.0 | 2025/10 | 安定版 |
| v1.1.0 | 2026/01 | Prosody（韻律）対応 |
| **v1.2.0** | 2026/03 | **ネイティブOpenJTalk廃止 → 純C# G2P、ビルド楽に** |
| v1.3.0 | 2026/03 | WebGL対応 |
| v1.4.0 | 2026/03 | 7言語対応 |

**全バージョン Unity 6 必須**（旧バージョンに戻しても Unity 2022 では動かない）。

### RAiM 採用に向けた前提条件

1. **Unity 6 へのアップグレード必要**（現状 Unity 2022.3.22f1）
2. flutter_embed_unity の Unity 6 対応確認済み（公式に 6000.0/6000.3 LTS サポート）
3. 既存 RAiMCharacterController.cs と NativeWebSocket の Unity 6 動作検証必要

### インストール手順（Unity 6 環境想定）

```
# Package Manager で Git URL 追加
https://github.com/ayutaz/uPiper.git?path=Assets/uPiper

# 推奨バージョン: v1.2.0（純C#、プラットフォーム対応シンプル）
https://github.com/ayutaz/uPiper.git?path=Assets/uPiper#v1.2.0

# 必須サンプルインポート
- MeCab Dictionary Data
- Voice Models
- Basic TTS Demo

# Setup
uPiper > Setup > Install from Samples
uPiper > Setup > Check Setup Status
```

### Unity 統合コード例（イメージ）

```csharp
// RAiMCharacterController.cs に追加
using uPiper;

public class RAiMCharacterController : MonoBehaviour
{
    private PiperTTS piperTTS;
    private AudioSource audioSource;
    
    async void Start()
    {
        piperTTS = new PiperTTS();
        await piperTTS.InitializeAsync(modelPath);
    }
    
    public async void ReceiveMessage(string json)
    {
        var data = JsonUtility.FromJson<EmotionMessage>(json);
        ChangeEmotion(data.emotion);
        
        // text → 音声生成（uPiper）
        var audioClip = await piperTTS.GenerateAudioAsync(data.text);
        audioSource.clip = audioClip;
        audioSource.Play();
    }
}
```

### メリット・デメリット

**メリット**
- **モバイル(iOS/Android)で直接動作**（サーバー不要、完全オフライン）
- Unity 内部統合、Flutter→Unity の sendToUnity で text 渡すだけ
- 公式メンテ活発（v1.0→v1.4 進化スピード速い）
- 同作者の piper-plus も活発開発、長期サポート期待
- 卒研の「モバイルでオフライン動作する AI コンパニオン」アピール強い

**デメリット**
- **Unity 6 必須**（既存プロジェクトのアップグレード必要）
- 音質は VOICEVOX に劣る
- まだ品質改善中（作者本人が認めている）
- Unity AI Inference Engine 依存（モバイルでの実機性能要検証）
- v1.2.0 で Breaking Changes（同期API削除等）あり、アップグレード時注意

---

## TTS別の最終比較表

| 観点 | VOICEVOX | Irodori-TTS | uPiper |
|---|---|---|---|
| **音質** | ◎（キャラ性◎） | ◎（自然さ◎、自由度◎） | ○（軽量さ売り） |
| **日本語自然さ** | ◎ | ◎（コミュニティ評価高） | ○ |
| **キャラクター自由度** | ❌（固定） | ◎（Voice Design） | △（モデル数限定） |
| **感情表現** | △（スタイル切替） | ◎（絵文字40種類） | ○（Prosody対応） |
| **モバイル動作** | ❌（サーバー必要） | ❌（サーバー必要） | ✅（完全オフライン） |
| **GPU要否** | 不要（CPU OK） | 必須 | 不要（モバイルCPU） |
| **AWS デプロイコスト** | $0〜30/月 | $380〜/月 | $0（モバイル動作） |
| **動作プラットフォーム** | Win/Mac/Linux/Docker | PC のみ（GPU） | Win/Mac/Linux/Android/iOS/WebGL |
| **Unity 統合** | HTTP API 経由 | HTTP API 経由 | ✅ Unity 直接統合 |
| **ライセンス** | キャラごと（多くは商用OK） | MIT（倫理規定あり） | Apache 2.0 |
| **学習コスト** | 低 | 中（Python/uv） | 中（Unity 6アップグレード必要） |
| **プロジェクト成熟度** | ◎（数年運用実績） | △（2026/03リリース） | ○（v1.x 安定リリース済み） |
| **卒研インパクト** | ○（王道、わかりやすい） | ◎（最新技術、独自） | ◎（モバイルオフライン） |
| **本番採用適性** | ◎ | △（コスト） | ○（要 Unity 6） |

---

## RAiM での採用戦略

### 本番採用: VOICEVOX

**理由**:
1. コスト: AWS Lambda化で月$0〜30 で運用可能
2. 安定性: 数年の運用実績
3. キャラクター完成度: 春日部つむぎ等の声質が高品質
4. 知名度: 卒研・面接で説明しやすい
5. ライセンス: 商用利用も明確

**本番構成**:
```
[モバイルアプリ]
    ↓ HTTPS
[API Gateway + Lambda(LLM: Bedrock Gemma3)]
    ↓
[Lambda Web Adapter] → VOICEVOX Docker
    ↓ WAV ストリーミング
[モバイルアプリで再生]
```

### 検証 1: Irodori-TTS

**目的**:
- ライムの理想の声をデザインする実験
- 絵文字感情制御の有効性検証
- VOICEVOX との音質比較資料作成

**実施場所**: 自宅 RTX 4070 + Tailscale 経由
**期間**: 卒研期間中の任意のタイミング
**成果物**: 性格3パターン × 同じセリフの音声サンプル比較

### 検証 2: uPiper

**目的**:
- モバイルオフライン動作の可能性検証
- ネット接続不可環境でも動く設計の選択肢確認

**前提**: Unity 2022 → Unity 6 アップグレード（別ブランチで実験）
**実施タイミング**: Mac借りた iOS ビルド成功後
**成果物**: iOS/Android 実機でのオフライン動作デモ

### 卒研での説明ストーリー

> RAiM の音声合成について、3 つの選択肢（VOICEVOX、Irodori-TTS、uPiper）を技術的・コスト的に比較検討した。各 TTS で同一セリフの音声サンプルを生成し、定性的・定量的に評価した結果、本番採用は VOICEVOX とした。
> 
> 理由は以下の通り:
> 1. **コスト**: AWS Lambda Web Adapter による従量課金で月 $0〜30 程度の運用が可能
> 2. **安定性**: 公式 Docker イメージで数年の運用実績
> 3. **音質**: 声優ベースのキャラクター完成度が高く、AI コンパニオンに適した「ライムらしさ」を表現可能
> 4. **拡張性**: 100名以上の話者から選択可能、性格パターンに応じた切替も可能
> 
> Irodori-TTS は Voice Design による独自声設計の可能性を確認、卒研後の発展課題（オリジナル声設計）として位置付ける。uPiper はモバイルオフライン動作の選択肢として技術検証し、ネット接続不可時のフォールバックとしての可能性を残す。

---

## 補足: 開発フェーズと TTS の使い分け

| フェーズ | 環境 | TTS | 理由 |
|---|---|---|---|
| **プロトタイプ(現状)** | Windows ローカル | VOICEVOX ローカル | 実装最速、動作確認用 |
| **iOS/Android 検証** | 実機 | VOICEVOX（自宅サーバー、Tailscale経由） | 既存ロジック流用 |
| **本番デモ** | AWS Lambda | VOICEVOX（クラウド） | コスト最適、レイテンシ許容 |
| **Voice Design 実験** | 自宅 RTX 4070 | Irodori-TTS | 卒研の比較資料 |
| **モバイルオフライン検証** | iOS/Android 実機 | uPiper（Unity 6 別ブランチ） | フォールバック検証 |

---

## 変更履歴

- 初版（2026/05/19）: 3 TTS の比較ドキュメント作成、VOICEVOX 本番採用方針確定