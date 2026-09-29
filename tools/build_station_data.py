"""
アプリに同梱する駅データ（assets/stations/stations.json）を作る。

  python tools/build_station_data.py \
      --model <展開した vosk-model-small-ja-0.22> \
      --src   <station_database>/out/main \
      --out   assets/stations/stations.json

元データ: station_database（Seo-4d696b75、CC BY 4.0）
  https://github.com/Seo-4d696b75/station_database
  CC BY 4.0 なので、アプリのクレジット表記に出典を載せること。

出力（サイズを抑えるため配列で持つ）:
  stations: [[コード, 駅名, よみ, Vosk用の語の並び, 緯度, 経度], ...]
  lines:    [[コード, 路線名, よみ, [駅コード（並び順）]], ...]

Vosk 用の語の並びは、よみをモデルの辞書にある語で分けたもの
（例: しんじゅく → "しん じゅく"）。アプリはこれをそのまま文法に入れる。
辞書に無い語を文法に入れると Vosk は黙って無視するので、ここで作っておく。
"""
import argparse, csv, json, os, sys, datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import station_vocab_check as c  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--model', required=True)
    p.add_argument('--src', required=True, help='station_database の out/main')
    p.add_argument('--out', required=True)
    a = p.parse_args()

    vocab = c.load_vocab(os.path.join(a.model, 'graph', 'words.txt'))
    hira = {w for w in vocab if c.HIRA.match(w)}

    def read(name):
        with open(os.path.join(a.src, name), encoding='utf-8') as f:
            return list(csv.DictReader(f))

    stations = [r for r in read('station.csv') if r['closed'] == '0']
    lines = [r for r in read('line.csv') if r['closed'] == '0']
    register = read('register.csv')

    out_stations, skipped = [], []
    alive = set()
    for s in stations:
        forms, seg = c.forms_for(s['original_name'], s['name_kana'], vocab, hira)
        if not seg:
            skipped.append(s['name'])
            continue
        alive.add(s['code'])
        out_stations.append([
            int(s['code']), s['name'], s['name_kana'], ' '.join(seg),
            round(float(s['lat']), 5), round(float(s['lng']), 5),
        ])

    by_line = {}
    for r in register:
        if r['station_code'] in alive:
            by_line.setdefault(r['line_code'], []).append((int(r['index']), int(r['station_code'])))

    out_lines = []
    for l in lines:
        members = [code for _, code in sorted(by_line.get(l['code'], []))]
        if members:
            out_lines.append([int(l['code']), l['name'], l['name_kana'], members])

    data = {
        'source': 'station_database (Seo-4d696b75) CC BY 4.0 https://github.com/Seo-4d696b75/station_database',
        'model': os.path.basename(os.path.normpath(a.model)),
        'generated': datetime.date.today().isoformat(),
        'stations': out_stations,
        'lines': out_lines,
    }
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, separators=(',', ':'))

    size = os.path.getsize(a.out)
    print(f'駅 {len(out_stations)}件 / 路線 {len(out_lines)}件 / 除外 {len(skipped)}件 → {a.out} ({size / 1024:.0f}KB)')
    for n in skipped[:20]:
        print('  除外:', n)


if __name__ == '__main__':
    main()
