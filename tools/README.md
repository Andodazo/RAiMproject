# tools

駅アラームの駅データを作るための Python スクリプト。アプリの実行には不要。

## 必要なもの
- Python 3.10 以上（追加のパッケージは不要）
- 展開した Vosk モデル（`assets/models/vosk-model-small-ja-0.22.zip` を展開したもの）
- station_database（CC BY 4.0）
  ```
  git clone --depth 1 https://github.com/Seo-4d696b75/station_database.git
  ```

## 駅名が Vosk で表せるか調べる
```
python tools/station_vocab_check.py --model <展開したモデル> --stations station_database/out/main/station.csv
python tools/station_vocab_check.py --model <展開したモデル> --stations station_database/out/main/station.csv --only 新宿,放出,八戸
```

## アプリ用の駅データを作り直す
駅の新設・廃止を反映したいときや、Vosk のモデルを替えたときに実行する。
```
python tools/build_station_data.py --model <展開したモデル> --src station_database/out/main --out assets/stations/stations.json
```

## 仕組み
Vosk の文法には、モデルの辞書（`graph/words.txt`）にある語しか入れられない。
辞書に無い語は **警告なしに無視される**。

駅名は漢字のままだと辞書の読みになり、特殊な読みの駅でずれる（放出 → ほうしゅつ）。
そこで **よみがなを、辞書にあるひらがなの語に分けて並べる**（しんじゅく → `しん じゅく`）。
文法モードでは語の区切りは認識にほとんど影響せず、並びの読みで照合される。

- 長音「ー」は辞書に無いので、直前の母音に直す（ぱーく → ぱあく）
- 単独の「は・へ」は助詞の読み（わ・え）にされうるので、カタカナの「ハ・ヘ」に置き換える
- 括弧内の別名と「・」は外す

2026-09-29 時点で、営業中の全 8,987 駅を表せることを確認済み。
