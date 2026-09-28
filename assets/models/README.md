# Vosk 日本語モデル

ウェイクワード検知（`WakeWordService`）が使う音声モデルを置く。

## 入手

このディレクトリに `vosk-model-small-ja-0.22.zip`（約48MB）を置く。

```powershell
curl.exe -L -o assets/models/vosk-model-small-ja-0.22.zip `
  https://alphacephei.com/vosk/models/vosk-model-small-ja-0.22.zip
```

展開は不要。zip のまま置く。初回起動時に `ModelLoader` が
アプリ専用領域（`getApplicationSupportDirectory()/vosk`）へ展開し、
2回目以降は展開済みのものを使う。

## なぜ small なのか

ウェイクワード検知は文法モードで認識候補を数語に絞るため、
大型モデル（`vosk-model-ja-0.22`、約1GB）の強みである言語モデルが
ほぼ使われない。モバイルに 1GB は積めないことも踏まえ、
両プラットフォームで same にできる small を選んでいる。

自由発話の書き起こし（STT）は Amazon Transcribe が担当するので、
このモデルの語彙精度は問題にならない。

## ネイティブバイナリ

モデルとは別に、Vosk 本体のバイナリが必要。

```powershell
dart run vosk_flutter install -t windows
```

Android は vosk_flutter に同梱されているので不要。
