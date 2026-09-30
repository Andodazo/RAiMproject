#!/bin/bash
# iOS 用の libvosk.xcframework を取ってきて、packages/vosk_ios/ios/Frameworks/ に置く。
#
#   bash packages/vosk_ios/tool/fetch_libvosk.sh
#
# 必要なもの: Mac、git、git-lfs（brew install git-lfs）
#
# 【出どころ】
# 公式（alphacep）は iOS 用のビルド済みライブラリを配布していない。
# 有志がビルドした openup-app/vosk-speech-recognition（2024-05-28）を使う。
# 誰がどうビルドしたかは確認できないので、中身が変わっていないことを
# SHA-256 で確かめる（2026-09-29 に取得して確認したもの）。
# 正式に採用するなら、vosk-api のソースから自分たちでビルドし直すこと。
set -euo pipefail

REPO="https://github.com/openup-app/vosk-speech-recognition.git"
COMMIT="44a5bbfcc0e4971325ec1db60bef0dda6164cbb6"
SHA_DEVICE="a6705b01390ec42a33f4f3b83ac4f2d760d74bf15e5a82cf7ea1710aca1115f9"
SHA_SIM="7933cf4794fad8f066de78ed1b6f70797b41ce3f43b5944e151c6a1f6c08d76c"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HERE/ios/Frameworks"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! git lfs version >/dev/null 2>&1; then
  echo "git-lfs がありません。brew install git-lfs を実行してから、もう一度実行してください。" >&2
  exit 1
fi

echo "取得中（約170MB）..."
git clone --quiet "$REPO" "$WORK/src"
git -C "$WORK/src" checkout --quiet "$COMMIT"
# この PC で git lfs install をしていなくても取れるように、このクローンだけで有効にする
git -C "$WORK/src" lfs install --local >/dev/null
git -C "$WORK/src" lfs pull

check() {
  local file="$1" want="$2"
  local got
  got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    echo "ハッシュが一致しません: $file" >&2
    echo "  期待: $want" >&2
    echo "  実際: $got" >&2
    exit 1
  fi
}
check "$WORK/src/libvosk.xcframework/ios-arm64_armv7_armv7s/libvosk.a" "$SHA_DEVICE"
check "$WORK/src/libvosk.xcframework/ios-arm64_x86_64-simulator/libvosk.a" "$SHA_SIM"

rm -rf "$DEST/libvosk.xcframework"
cp -R "$WORK/src/libvosk.xcframework" "$DEST/"
echo "置きました: $DEST/libvosk.xcframework"
echo "続けて: cd ios && pod install（または flutter run で自動）"
