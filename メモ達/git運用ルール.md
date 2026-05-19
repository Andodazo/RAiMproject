# RAiM Git 運用ルール

## このドキュメントについて

班員全員が同じルールで Git 操作することで、事故を防ぎ、卒研期間中ずっと「動くもの」を維持するためのルール集。

リーダー(安藤)が判断に迷った時の判断基準としても使う。

合わせて読むドキュメント:
- `環境セットアップ.md` — 開発環境構築
- `まとめ.md` — プロジェクト全体設計

---

## 基本原則

### 1. main ブランチは「常に動く状態」を維持

`main` ブランチに push されるコードは、**clone した班員が誰でもビルドできる状態**であること。

実験的な変更や壊れる可能性があるものは `feature/*` ブランチで行う。

### 2. 自動生成物は絶対にコミットしない

ビルドの度に変わるファイル・各自の環境で再生成すべきファイルは Git に入れない。

具体例:
- `android/unityLibrary/`(Unity Export で生成)
- `unity/raim_unity/Library/`(Unity の内部キャッシュ)
- `build/`, `.dart_tool/`(Flutter ビルド成果物)

詳細は `.gitignore` で管理。

### 3. コミット前に必ず動作確認

「コードを書いた → コミット」ではなく、「コードを書いた → 動かして確認 → コミット」。

特に main ブランチに直接プッシュする時は、`flutter run -d windows` でメッセージ送信まで確認してから push する。

### 4. 困ったら聞く、迷ったらブランチ切る

Git 操作で「これ実行して大丈夫?」と迷ったら、実行前に班員/リーダーに確認する。

特に以下は実行前に必ず確認:
- `git reset --hard`(変更を破棄、戻せない)
- `git push --force`(他人の変更を上書き、戻せない)
- `git rm`(ファイル削除)
- ブランチ切替時に未コミット変更がある場合

---

## ブランチ運用

### ブランチ構成

```
main                          ← 常に動く状態
├── feature/voice-input        ← 個別機能の開発
├── feature/unity6-upgrade     ← 大きな変更の実験
├── fix/audio-delay            ← バグ修正
└── docs/setup-guide-update    ← ドキュメント更新
```

### ブランチ命名規則

| プレフィックス | 用途 | 例 |
|---|---|---|
| `feature/` | 新機能追加 | `feature/voice-input` |
| `fix/` | バグ修正 | `fix/audio-delay` |
| `docs/` | ドキュメントのみ | `docs/setup-guide-update` |
| `chore/` | ビルド設定・依存更新 | `chore/upgrade-flutter-sdk` |
| `experiment/` | 実験的、main マージしないかも | `experiment/unity6-upiper` |

### ブランチ作成・切替

```powershell
# 現在のブランチ確認
git branch

# 新規ブランチ作成して切り替え
git checkout -b feature/voice-input

# GitHub にも push(初回)
git push -u origin feature/voice-input

# 既存ブランチに切り替え
git checkout main

# リモートの最新を取得
git fetch origin
git pull origin main
```

### main にマージするタイミング

機能が完成して動作確認が取れたら、班員に知らせて Pull Request 経由でマージ。

GitHub の Pull Request:
1. ブランチを push 後、GitHub で「Compare & pull request」ボタン
2. タイトル・説明を書く
3. リーダーが確認 → Approve → Merge
4. ローカルでも `git checkout main && git pull` で取り込む

班員が少ない時期は直接 `main` に push でも OK だが、**重要な変更ほど PR 経由**で安全策をとる。

---

## コミットメッセージのルール

### フォーマット

```
<プレフィックス>: <概要>

<必要なら詳細説明>
<必要なら背景や経緯>
```

### プレフィックス一覧

| プレフィックス | 用途 |
|---|---|
| `feat:` | 新機能追加 |
| `fix:` | バグ修正 |
| `docs:` | ドキュメントのみ変更 |
| `style:` | コードフォーマット(動作に影響なし) |
| `refactor:` | リファクタリング(動作変更なし) |
| `chore:` | ビルド設定、依存パッケージ更新等 |
| `perf:` | パフォーマンス改善 |
| `test:` | テスト追加・修正 |

### 良い例

```
feat: VOICEVOX TTS統合、春日部つむぎで音声出力対応

- TTSService クラス追加(VOICEVOX HTTP API)
- ChatProvider で LLM 応答後に speak() 呼び出し
- pubspec.yaml に audioplayers 追加
```

```
fix: Windows ビルド時の audioplayers C2338 エラー

CMakeLists.txt の APPLY_STANDARD_SETTINGS に
/utf-8 と _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS を追加
```

```
chore: android/unityLibrary を Git 管理から除外

自動生成物なので各自の環境で Export し直す前提
.gitignore に追加 + git rm --cached で追跡解除
```

### 悪い例

```
update          ← 何の update か不明
fix bug         ← どのバグ?
WIP             ← Work In Progress を main に push しない
作業中          ← 同上
```

---

## .gitignore の管理

### 現在の `.gitignore` 構成

```gitignore
# ============================================
# Flutter 用
# ============================================
.dart_tool/
.flutter-plugins-dependencies
.pub-cache/
.pub/
/build/
/coverage/
**/ios/Flutter/.last_build_id

# Android 自動生成物
/android/app/debug
/android/app/profile
/android/app/release
/android/.gradle/

# Flutter Embed Unity の生成物(★ 絶対に Git に入れない)
android/unityLibrary/
ios/UnityFramework/
ios/UnityLibrary/

# Windows
windows/flutter/generated_plugin_registrant.cc
windows/flutter/generated_plugin_registrant.h
windows/flutter/generated_plugins.cmake

# ============================================
# Unity 用
# ============================================
unity/**/[Ll]ibrary/
unity/**/[Tt]emp/
unity/**/[Oo]bj/
unity/**/[Bb]uild/
unity/**/[Bb]uilds/
unity/**/[Ll]ogs/
unity/**/[Uu]ser[Ss]ettings/
unity/**/[Mm]emoryCaptures/
unity/**/[Rr]ecordings/
unity/raim_unity_backup/
unity/**/.vs/
unity/**/.gradle/

# 自動生成のソリューション/プロジェクトファイル
unity/**/*.csproj
unity/**/*.unityproj
unity/**/*.sln
unity/**/*.suo
unity/**/*.user
unity/**/*.pidb
unity/**/*.booproj
unity/**/*.svd
unity/**/*.pdb
unity/**/*.mdb
unity/**/*.opendb
unity/**/*.VC.db

# Unity Builds
unity/**/*.apk
unity/**/*.aab
unity/**/*.unitypackage
unity/**/*.app

# Crashlytics
unity/**/crashlytics-build.properties

# Packed Addressables
unity/**/[Aa]ssets/[Aa]ddressable[Aa]ssets[Dd]ata/*/*.bin*

# Auto-generated Android Assets
unity/**/[Aa]ssets/[Ss]treamingAssets/aa.meta
unity/**/[Aa]ssets/[Ss]treamingAssets/aa/*

# ============================================
# 共通
# ============================================
*.class
*.log
*.pyc
*.swp
.DS_Store
.atom/
.build/
.buildlog/
.history
.svn/
.swiftpm/
migrate_working_dir/

# IDE 設定(個人ごとに違うので Git に入れない)
*.iml
*.ipr
*.iws
.idea/
.vscode/

# Symbolication
app.*.symbols
app.*.map.json
```

### `.gitignore` を編集する時の手順

`.gitignore` を**後から書いても**、すでに Git の追跡対象になっているファイルは除外されない。明示的に追跡を外す必要がある。

#### 手順

```powershell
cd H:\dev\RAiM_prot\Flutter_Test\raim_prototype

# 1. まず .gitignore を編集して保存

# 2. すでに追跡されているファイルを Git 管理から外す(ファイル自体は消えない)
git rm -r --cached <除外したいフォルダ or ファイル>

# 例:
git rm -r --cached android/unityLibrary/
git rm -r --cached android/.gradle/ 2>$null   # ↑ もし存在しなくてもエラー無視

# 3. 状態確認
git status

# 4. コミット & push
git add .gitignore
git commit -m "chore: <フォルダ名> を Git 管理から除外"
git push origin main
```

**重要**: `--cached` をつけることで、**ファイルは消さず Git 管理だけ外す**。`--cached` 抜きで実行するとローカルのファイルも消える。

---

## Unity Export 後の必須作業

Unity Editor で `Window > Flutter Embed Unity > Export Android` (または iOS)を実行すると、`android/unityLibrary/` に大量のファイルが生成される(数千 ファイル、数GB)。

### 絶対にやってはいけないこと

❌ `git add .` で全部ステージ
❌ そのまま `git commit -m "Unity Export"`
❌ `git push`

これをやると:
- リポジトリが肥大化(GitHub の容量制限に引っかかる)
- 他の班員が clone するのに数十分かかる
- 自動生成物のため、各自の環境で再生成すべき

### 正しい手順

Unity Export 後に VS Code で 1000+ ファイル変更が表示されたら、**コミットせず**に:

```powershell
# 何が変更されたか確認(コミットはしない)
git status

# unityLibrary 以外の変更があれば、それだけステージ
git add unity/raim_unity/Assets/Scripts/RAiMCharacterController.cs   # 例
git commit -m "feat: Unity Script の修正"

# unityLibrary は .gitignore に入っているので git status に出ない(出たら .gitignore 確認)
```

もし誤って unityLibrary が追跡されてしまった場合:

```powershell
# 緊急対応
git reset                              # ステージング解除
git rm -r --cached android/unityLibrary/
git commit -m "chore: 誤って追加された unityLibrary を除外"
```

---

## よくある事故と対処法

### 事故 1: 大量の自動生成物を間違えてコミットしてしまった

**コミットだけしてプッシュ前**:

```powershell
# 直前のコミットを取り消す(変更は手元に残る)
git reset --soft HEAD~1

# ステージング解除
git reset

# .gitignore を整備してから再コミット
```

**プッシュもしてしまった**:

```powershell
# .gitignore を整備
# git rm --cached で追跡解除
git rm -r --cached android/unityLibrary/

# コミット & 強制 push(リーダー判断、班員に通知してから)
git add .gitignore
git commit -m "chore: 誤って push した自動生成物を除外"
git push origin main

# 注意: 他の班員は git pull で衝突する可能性
# 班員に「pull する前に通知してね」と知らせる
```

### 事故 2: ブランチを切り替えたら変更が消えた

未コミット変更があるままブランチ切替すると、**Git は変更を持ち越そうとする**(切替先で衝突する可能性)。

予防策:
```powershell
# ブランチ切替前に変更を保存
git stash                          # 一時退避

# 切替後、戻したい時に
git stash pop                      # 退避から復元
```

または:
```powershell
# 切替前にコミット(WIP として)
git add -A
git commit -m "WIP: 作業途中"

# 後で履歴を整理する時に
git reset --soft HEAD~1            # コミット取り消し
```

### 事故 3: コンフリクトが出てパニック

`git pull` 時に「CONFLICT」エラー:

```powershell
# 1. どのファイルが衝突したか確認
git status

# 2. 衝突したファイルを開くと、以下のマーカーがある:
# <<<<<<< HEAD
# 自分の変更
# =======
# リモートの変更
# >>>>>>> origin/main

# 3. どちらを残すか(または両方マージするか)決めて、マーカー削除

# 4. 解決後
git add <ファイル>
git commit -m "fix: マージコンフリクト解消"
```

判断に迷うコンフリクトは、班員と相談してから解決。

### 事故 4: 間違ったファイルを `git rm` で消した

```powershell
# まだコミットしていなければ
git checkout HEAD <ファイル>          # 復元

# コミットしてしまった場合
git revert <コミットID>               # 削除を取り消すコミットを作る
```

---

## 推奨ワークフロー

### 機能開発時の流れ

```
1. main の最新を取得
   git checkout main
   git pull origin main

2. ブランチを切る
   git checkout -b feature/voice-input

3. コード書く、こまめにコミット
   git add <ファイル>
   git commit -m "feat: 音声入力ボタン追加"
   (繰り返し)

4. 動作確認
   flutter run -d windows  → 動いた!

5. GitHub に push
   git push -u origin feature/voice-input

6. GitHub で Pull Request 作成
   - リーダーが Approve
   - main にマージ

7. ローカルでも取り込み
   git checkout main
   git pull origin main
   git branch -d feature/voice-input   # ブランチ削除(任意)
```

### 朝の開発開始時(必須ルーチン)

```powershell
cd H:\dev\RAiM_prot\Flutter_Test\raim_prototype
git checkout main
git pull origin main                  # 班員の変更を取り込む
flutter pub get                       # 依存パッケージが更新されてるかも
```

これをやらないと、班員の変更とコンフリクトが起きやすくなる。

---

## チェックリスト(Git 操作前)

実行前に必ず確認:

- [ ] 今いるブランチは正しいか?(`git branch` で確認)
- [ ] 未コミット変更で消えてはいけないものはないか?(`git status` で確認)
- [ ] コミットするファイルに自動生成物は含まれていないか?(`git status` で確認)
- [ ] コミットメッセージはルール通りか?(`feat:`, `fix:` 等のプレフィックス)
- [ ] push 先のブランチは正しいか?(間違って `main` に push してないか)

---

## 班員へのお願い

リーダー(安藤)から班員へ:

1. **困ったら手を止めて聞いて**。Git は事故ると戻すのが大変なので、悩むより聞く方が早い。

2. **重要な作業前にコミット**。コードを大きく変える前、ライブラリを変更する前は、必ず動く状態でコミット&push しておく。「戻せる場所」を作ってから挑戦する。

3. **Unity Export は要注意**。Unity Editor で Export した直後は VS Code で大量の変更が表示されるが、**コミットボタン押す前にこのドキュメント確認**。

4. **班員の変更を取り込む癖を**。朝の作業開始時、main に切り替えて `git pull`。これだけでコンフリクト 9 割減る。

5. **ブランチ運用に慣れる**。実験的なことをやる時は必ずブランチを切る。「動くもの」を main に残しておく安心感が、卒研期間を救う。

---

## 変更履歴

- 初版(2026/05/19): Git 運用ルールを独立ドキュメント化、Unity Export の取り扱い、`.gitignore` 編集手順、よくある事故と対処法を反映