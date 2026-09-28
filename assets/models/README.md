# Vosk 日本語モデル

ウェイクワード検知（`WakeWordService`）が使う音声モデルを置く。

## 置いてあるもの

`vosk-model-small-ja-0.22.zip`（約47MB）をリポジトリに含めている。
clone すればそのまま使えるので、個別にダウンロードする必要はない。

元の配布元:
https://alphacephei.com/vosk/models/vosk-model-small-ja-0.22.zip

展開はしない。zip のまま置く。初回起動時に `ModelLoader` が
アプリ専用領域（`getApplicationSupportDirectory()/vosk`）へ展開し、
2回目以降は展開済みのものを使う。

GitHub は 50MB を超えるファイルで警告、100MB で拒否する。
大きいモデル（`vosk-model-ja-0.22`、約1GB）に差し替える場合は
リポジトリに入れられないので、Git LFS か別の配布方法を検討すること。

## なぜ small なのか

ウェイクワード検知は文法モードで認識候補を数語に絞るため、
大型モデル（`vosk-model-ja-0.22`、約1GB）の強みである言語モデルが
ほぼ使われない。モバイルに 1GB は積めないことも踏まえ、
両プラットフォームで同じにできる small を選んでいる。

自由発話の書き起こし（STT）は Amazon Transcribe が担当するので、
このモデルの語彙精度は問題にならない。

## ネイティブバイナリ

モデルとは別に、Vosk 本体のバイナリが必要。

```powershell
dart run vosk_flutter install -t windows
```

Android は vosk_flutter に同梱されているので不要。
