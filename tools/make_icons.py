"""RAiM のアプリアイコンを Android / iOS / Windows ぶん、まとめて作る。

元画像は tools/icon/raim_bust.png（背景が透明なライムのバストアップ）。
顔のあたりを正方形に切り出し、背景色を敷いて各サイズに書き出す。

使い方（リポジトリ直下で）:
    pip install pillow
    python tools/make_icons.py
    python tools/make_icons.py --bg "#B7F35A"   # 背景色を変える

書き出すもの:
    Android  android/app/src/main/res/mipmap-*/ic_launcher.png        （古い端末用）
             android/app/src/main/res/drawable-*/ic_launcher_foreground.png（Android 8 以降の
             mipmap-anydpi-v26/ic_launcher.xml                          アダプティブアイコン）
             values/ic_launcher_background.xml                          （その背景色）
    iOS      ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png（Contents.json のサイズどおり）
    Windows  windows/runner/resources/app_icon.ico

flutter_launcher_icons を使わないのは、依存を増やさずに済むのと、
アダプティブアイコンの前景の大きさをこちらで決めたいため。
"""

import argparse
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'tools' / 'icon' / 'raim_bust.png'

# 元画像から切り出す正方形（顔が中心、髪の先と襟まで入る）
CROP_CENTER_X = 690
CROP_TOP = 0
CROP_SIZE = 760

DEFAULT_BG = '#172433'  # アプリのボタンと同じ紺

# Android の密度ごとのサイズ（px）。ic_launcher は 48dp、前景は 108dp
ANDROID_DENSITIES = {
    'mdpi': 1.0,
    'hdpi': 1.5,
    'xhdpi': 2.0,
    'xxhdpi': 3.0,
    'xxxhdpi': 4.0,
}

# アダプティブアイコンで、108dp の画用紙のうち絵を置く大きさ。
# 端末が見せるのは中央の 72dp（約 67%）だけで、形（丸・角丸など）は端末が決める。
# 72%（約 78dp）にすると、切り出しの端（襟の切れ目や頭のてっぺん）が見える範囲の外に出る。
ADAPTIVE_SCALE = 0.72


def parse_color(text: str) -> tuple[int, int, int]:
    text = text.lstrip('#')
    if len(text) != 6:
        raise SystemExit(f'色は #RRGGBB で指定してください: {text}')
    return tuple(int(text[i:i + 2], 16) for i in (0, 2, 4))


def load_face() -> Image.Image:
    src = Image.open(SOURCE).convert('RGBA')
    left = CROP_CENTER_X - CROP_SIZE // 2
    box = (left, CROP_TOP, left + CROP_SIZE, CROP_TOP + CROP_SIZE)
    return src.crop(box).resize((1024, 1024), Image.LANCZOS)


def full_icon(face: Image.Image, bg: tuple[int, int, int]) -> Image.Image:
    """背景を敷いた正方形。iOS は透明を使えないので RGB にする。"""
    canvas = Image.new('RGBA', face.size, bg + (255,))
    canvas.alpha_composite(face)
    return canvas.convert('RGB')


def adaptive_foreground(face: Image.Image) -> Image.Image:
    """透明の画用紙の中央に、少し小さくした顔を置く。"""
    size = 1024
    inner = round(size * ADAPTIVE_SCALE)
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    small = face.resize((inner, inner), Image.LANCZOS)
    offset = (size - inner) // 2
    canvas.alpha_composite(small, (offset, offset))
    return canvas


def write_android(icon: Image.Image, fg: Image.Image, bg_hex: str) -> None:
    res = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'
    for name, scale in ANDROID_DENSITIES.items():
        legacy = res / f'mipmap-{name}' / 'ic_launcher.png'
        legacy.parent.mkdir(parents=True, exist_ok=True)
        icon.resize((round(48 * scale),) * 2, Image.LANCZOS).save(legacy)

        fore = res / f'drawable-{name}' / 'ic_launcher_foreground.png'
        fore.parent.mkdir(parents=True, exist_ok=True)
        fg.resize((round(108 * scale),) * 2, Image.LANCZOS).save(fore)

    anydpi = res / 'mipmap-anydpi-v26' / 'ic_launcher.xml'
    anydpi.parent.mkdir(parents=True, exist_ok=True)
    anydpi.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- tools/make_icons.py で作ったもの。手で直さない -->\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n',
        encoding='utf-8',
    )

    color = res / 'values' / 'ic_launcher_background.xml'
    color.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- tools/make_icons.py で作ったもの。手で直さない -->\n'
        '<resources>\n'
        f'    <color name="ic_launcher_background">{bg_hex}</color>\n'
        '</resources>\n',
        encoding='utf-8',
    )


def write_ios(icon: Image.Image) -> None:
    folder = ROOT / 'ios' / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'
    contents = json.loads((folder / 'Contents.json').read_text(encoding='utf-8'))
    for entry in contents['images']:
        points = float(entry['size'].split('x')[0])
        scale = float(entry['scale'].rstrip('x'))
        px = round(points * scale)
        icon.resize((px, px), Image.LANCZOS).save(folder / entry['filename'], optimize=True)


def write_windows(icon: Image.Image) -> None:
    path = ROOT / 'windows' / 'runner' / 'resources' / 'app_icon.ico'
    sizes = [(s, s) for s in (16, 24, 32, 48, 64, 128, 256)]
    icon.save(path, format='ICO', sizes=sizes)


def main() -> None:
    parser = argparse.ArgumentParser(description='RAiM のアプリアイコンを作る')
    parser.add_argument('--bg', default=DEFAULT_BG, help='背景色（#RRGGBB）')
    args = parser.parse_args()

    bg = parse_color(args.bg)
    bg_hex = '#' + args.bg.lstrip('#').upper()

    face = load_face()
    icon = full_icon(face, bg)
    fg = adaptive_foreground(face)

    write_android(icon, fg, bg_hex)
    write_ios(icon)
    write_windows(icon)
    print(f'アイコンを作りました（背景 {bg_hex}）')


if __name__ == '__main__':
    main()
