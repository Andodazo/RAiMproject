<#
.SYNOPSIS
  RAiM の配布用ビルドを作り、GitHub Releases に上げる。

.DESCRIPTION
  Windows（zip）と Android（APK）を作って dist\ に置く。
  -Publish を付けると、pubspec.yaml の version で GitHub Releases に公開する。

  配布ページ（docs\index.html）は「最新のリリース」の
    RAiM-android.apk / RAiM-windows.zip
  を指しているので、ファイル名は固定にしている。公開すればページは自動で新しい版になる。

  事前に必要なもの:
    - android\key.properties と、そこに書いた keystore（無いと Android は作らない）
    - android\unityLibrary（Unity から Android 向けに Export したもの）
    - unity\raim_unity\builds\Windows\raim.exe（Unity の Windows ビルド）
    - -Publish するなら gh（GitHub CLI）でログイン済みであること

.EXAMPLE
  # 手元で作るだけ（dist\ にできる）
  .\tools\release.ps1

.EXAMPLE
  # 作って公開する
  .\tools\release.ps1 -Publish

.EXAMPLE
  # Android だけ作り直して公開する
  .\tools\release.ps1 -SkipWindows -Publish
#>
param(
  [switch]$SkipWindows,
  [switch]$SkipAndroid,
  [switch]$Publish,
  # リリースノート。省略すると前回のリリースからのコミット・PR から自動で作る
  [string]$Notes = ''
)

# このファイルは UTF-8（BOM 付き）で保存すること。
# BOM が無いと Windows PowerShell 5.1 が Shift-JIS として読み、日本語が化けて動かない。
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Fail([string]$message) {
  Write-Host "中止: $message" -ForegroundColor Red
  exit 1
}

function Step([string]$message) {
  Write-Host ''
  Write-Host "== $message" -ForegroundColor Cyan
}

# ------------------------------------------------------------
# バージョン
# ------------------------------------------------------------
$versionLine = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(\S+)' | Select-Object -First 1
if (-not $versionLine) { Fail 'pubspec.yaml に version: がありません' }
$fullVersion = $versionLine.Matches[0].Groups[1].Value   # 例: 1.0.1+2
$versionName = $fullVersion.Split('+')[0]                 # 例: 1.0.1
$tag = "v$versionName"
Write-Host "バージョン: $fullVersion（タグ $tag）"

# ------------------------------------------------------------
# 公開前の確認
# ------------------------------------------------------------
if ($Publish) {
  Step '公開前の確認'

  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Fail 'gh（GitHub CLI）が見つかりません。winget install GitHub.cli で入れて gh auth login してください'
  }

  # 公開する版は必ずコミットと対応させる（どのコードの版か後で追えるように）
  $dirty = git status --porcelain
  if ($dirty) { Fail 'コミットしていない変更があります。コミットしてから実行してください' }

  $head = git rev-parse HEAD
  $pushed = git branch -r --contains $head
  if (-not $pushed) { Fail '今のコミットがまだ push されていません。push してから実行してください' }

  # 同じ版を二重に出さない。上書きしたいときは GitHub 上で消してからやり直す
  # Windows PowerShell 5.1 は Stop のままだと、外部コマンドの stderr を捨てるだけで例外になる
  $ErrorActionPreference = 'Continue'
  gh release view $tag *> $null
  $exists = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = 'Stop'
  if ($exists) {
    Fail "$tag はもう公開されています。pubspec.yaml の version を上げてください（例: 1.0.1+2 → 1.0.2+3）"
  }
}

# 配布ビルドでは接続先切り替えメニューを隠す（常に AWS につなぐ）
$defines = @('--dart-define=RAIM_ENABLE_SERVER_SWITCH=false')

$dist = Join-Path $repoRoot 'dist'
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory $dist | Out-Null

$assets = @()

# ------------------------------------------------------------
# Android
# ------------------------------------------------------------
if (-not $SkipAndroid) {
  Step 'Android（APK）'

  # key.properties が無いと debug の鍵で署名される。debug の鍵は PC ごとに違うので、
  # その APK を配ると次の版を上書きインストールできなくなる。だから作らずに止める
  if (-not (Test-Path 'android\key.properties')) {
    Fail 'android\key.properties がありません。配布用の鍵が無い PC では Android 版を作れません（-SkipAndroid で Windows だけ作れます）'
  }
  if (-not (Test-Path 'android\unityLibrary')) {
    Fail 'android\unityLibrary がありません。Unity から Android 向けに Export してください'
  }

  flutter build apk --release @defines
  if ($LASTEXITCODE -ne 0) { Fail 'Android のビルドに失敗しました' }

  $apk = 'build\app\outputs\flutter-apk\app-release.apk'
  if (-not (Test-Path $apk)) { Fail "$apk が見つかりません" }

  $apkOut = Join-Path $dist 'RAiM-android.apk'
  Copy-Item $apk $apkOut
  $assets += $apkOut
  Write-Host "→ $apkOut"
}

# ------------------------------------------------------------
# Windows
# ------------------------------------------------------------
if (-not $SkipWindows) {
  Step 'Windows（zip）'

  $unityBuild = 'unity\raim_unity\builds\Windows'
  if (-not (Test-Path "$unityBuild\raim.exe")) {
    Fail "$unityBuild\raim.exe がありません。Unity で Windows 向けにビルドしてください"
  }

  flutter build windows --release @defines
  if ($LASTEXITCODE -ne 0) { Fail 'Windows のビルドに失敗しました' }

  $release = 'build\windows\x64\runner\Release'
  $stage = Join-Path $dist 'RAiM'
  New-Item -ItemType Directory $stage | Out-Null

  # Flutter 本体（exe・data\・プラグインの dll。libvosk.dll もここに入る）
  Copy-Item "$release\*" $stage -Recurse

  # exe 名だけ配布用に変える。開発中の exe 名（raim_prototype.exe）は変えない。
  # 保存先フォルダ（AppData）は exe 名ではなく Runner.rc の会社名・製品名で決まるので、
  # ここを変えてもログイン状態や設定は引き継がれる
  $devExe = Join-Path $stage 'raim_prototype.exe'
  if (-not (Test-Path $devExe)) { Fail "$devExe が見つかりません" }
  Rename-Item $devExe 'RAiM.exe'

  # ウェイクワードが動くかに関わるので、念のため確認する
  if (-not (Test-Path (Join-Path $stage 'libvosk.dll'))) {
    Write-Host '注意: libvosk.dll が入っていません。ウェイクワードが動きません' -ForegroundColor Yellow
  }

  # Unity（マスコット本体）。windows_unity_bridge.dart は exe の隣の unity\raim.exe を探す
  $unityStage = Join-Path $stage 'unity'
  New-Item -ItemType Directory $unityStage | Out-Null
  Get-ChildItem $unityBuild |
    # 配らなくていいもの: Burst のデバッグ情報（*_DoNotShip）と IL2CPP のバックアップ（*_ButDontShipItWithYourGame、1GB 超）
    Where-Object { $_.Name -notlike '*_DoNotShip' -and $_.Name -notlike '*_ButDontShipItWithYourGame' } |
    ForEach-Object { Copy-Item $_.FullName $unityStage -Recurse }

  # VC++ ランタイム。デモ用 PC に入っていないと Flutter の exe が起動しない
  foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    $src = Join-Path $env:WINDIR "System32\$dll"
    if (Test-Path $src) {
      Copy-Item $src $stage
    } else {
      Write-Host "注意: $src が見つかりません（同梱できませんでした）" -ForegroundColor Yellow
    }
  }

  $zipOut = Join-Path $dist 'RAiM-windows.zip'
  # Compress-Archive は日本語や大きいファイルで不安定なので tar を使う（Windows 10 以降に標準である）
  Push-Location $dist
  tar -a -c -f 'RAiM-windows.zip' 'RAiM'
  Pop-Location
  if (-not (Test-Path $zipOut)) { Fail 'zip を作れませんでした' }

  $assets += $zipOut
  Write-Host "→ $zipOut"
}

if ($assets.Count -eq 0) { Fail '何も作っていません（-SkipWindows と -SkipAndroid を両方付けています）' }

# ------------------------------------------------------------
# 公開
# ------------------------------------------------------------
if (-not $Publish) {
  Step '完了（公開はしていません）'
  Write-Host 'dist\ を確認して、問題なければ -Publish を付けて実行してください'
  exit 0
}

Step "GitHub Releases に公開（$tag）"

$head = git rev-parse HEAD
$ghArgs = @('release', 'create', $tag) + $assets + @('--target', $head, '--title', "RAiM $versionName")
if ($Notes) {
  $ghArgs += @('--notes', $Notes)
} else {
  $ghArgs += '--generate-notes'
}

gh @ghArgs
if ($LASTEXITCODE -ne 0) { Fail '公開に失敗しました' }

Write-Host ''
Write-Host '公開しました。配布ページは自動でこの版を指します:' -ForegroundColor Green
Write-Host '  https://andodazo.github.io/RAiMproject/'
