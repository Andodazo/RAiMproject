"""
駅名を Vosk の文法に入れられる形にできるかを調べる。

  python station_vocab_check.py --model vosk-model-small-ja-0.22 --stations station.csv
  python station_vocab_check.py --model ... --stations ... --only 新宿,放出,三国ヶ丘

駅データは station_database（CC BY 4.0）の out/main/station.csv を使う。
  https://github.com/Seo-4d696b75/station_database

【考え方】
Vosk の文法には辞書（graph/words.txt）にある語しか入れられない。
駅名は2通りで表し、どちらかに一致すれば「その駅」とみなす。

  漢字 … 駅名がそのまま辞書にあれば使う（例: 新宿）。
         読みは辞書側の読みになるので、特殊な読みの駅（放出=はなてん）では外れる。
  かな … 読みがなを辞書にある「ひらがなだけの語」に分けて並べる
         （例: しんじゅく → しん じゅく）。読みから作るので読み違いが起きない。

文法モードでは語の区切りは認識にほぼ影響しない（並びの読みで照合される）。
"""
import argparse, csv, collections, re

HIRA = re.compile(r'^[ぁ-ゖっー]+$')
# 助詞として読まれやすい語。「は」を wa と読まれると駅名の読みとずれる
PARTICLE_LIKE = {'は', 'へ', 'を'}
KATAKANA_FOR = {'は': 'ハ', 'へ': 'ヘ', 'を': 'ヲ'}

def load_vocab(path):
    words = set()
    with open(path, encoding='utf-8') as f:
        for line in f:
            w = line.split(' ', 1)[0]
            if w and not w.startswith(('<', '!', '[', '#')):
                words.add(w)
    return words

VOWEL = {}
for row in ['あかさたなはまやらわがざだばぱぁゃゎ', 'いきしちにひみりぎじぢびぴぃ', 'うくすつぬふむゆるぐずづぶぷぅゅゔ',
            'えけせてねへめれげぜでべぺぇ', 'おこそとのほもよろをごぞどぼぽぉょ']:
    for ch in row:
        VOWEL[ch] = row[0]

def normalize_kana(kana):
    """辞書で表せる形に直す。

    - 括弧の中（別名）は外す: さんのみや(こうべさんのみや) → さんのみや
    - 「・」は詰める: まんざ・かざわぐち → まんざかざわぐち
    - ぢ→じ、づ→ず（発音は同じで、辞書は じ・ず 側が多い）
    - 長音「ー」は直前の母音に直す（ぱーく → ぱあく）。辞書に「ー」が無いため
    """
    kana = re.sub(r'[（(〈].*?[）)〉]', '', kana)
    kana = re.sub(r'[\s　]', '', kana)
    kana = kana.replace('・', '').replace('ぢ', 'じ').replace('づ', 'ず')
    out = []
    for ch in kana:
        if ch == 'ー' and out:
            out.append(VOWEL.get(out[-1], 'う'))
        else:
            out.append(ch)
    return ''.join(out)

def segment(text, vocab, maxlen=10):
    """語数が最少、同数なら助詞っぽい1文字語が少ない分け方。無ければ None。"""
    n = len(text)
    best = [None] * (n + 1)
    best[0] = (0, 0, [])
    for i in range(n):
        if best[i] is None:
            continue
        cnt, bad, seq = best[i]
        for j in range(i + 1, min(n, i + maxlen) + 1):
            w = text[i:j]
            if w not in vocab:
                continue
            cand = (cnt + 1, bad + (w in PARTICLE_LIKE), seq + [w])
            if best[j] is None or cand[:2] < best[j][:2]:
                best[j] = cand
    return best[n][2] if best[n] else None

def forms_for(name, kana, vocab, hira_vocab):
    """文法に入れる表記の候補（空白区切りの語の並び）を返す。"""
    forms = []
    name = re.sub(r'[（(〈].*?[）)〉]', '', name).strip()
    if name in vocab:
        forms.append(name)
    seg = segment(normalize_kana(kana), hira_vocab)
    if seg:
        # 単独の「は・へ・を」は助詞の読み（わ・え・お）にされうるので、
        # 同じ音のカタカナに置き換える（カタカナは字のとおりに読まれる）
        seg = [KATAKANA_FOR.get(w, w) if KATAKANA_FOR.get(w) in vocab else w
               for w in seg]
        forms.append(' '.join(seg))
    return forms, seg

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--model', required=True)
    p.add_argument('--stations', required=True)
    p.add_argument('--only')
    p.add_argument('--show', type=int, default=10)
    a = p.parse_args()

    vocab = load_vocab(f'{a.model}/graph/words.txt')
    hira_vocab = {w for w in vocab if HIRA.match(w)}

    rows = [r for r in csv.DictReader(open(a.stations, encoding='utf-8')) if r['closed'] == '0']
    if a.only:
        want = {s.strip() for s in a.only.split(',')}
        rows = [r for r in rows if r['name'] in want or r['original_name'] in want]

    # 同じ名前・読みの駅（乗換駅など）はまとめて数える
    seen = {}
    for r in rows:
        seen.setdefault((r['original_name'], r['name_kana']), r)

    stats = collections.Counter()
    samples = collections.defaultdict(list)
    particle = []
    for (name, kana), r in seen.items():
        forms, seg = forms_for(name, kana, vocab, hira_vocab)
        kanji_ok = re.sub(r'[（(〈].*?[）)〉]', '', name).strip() in vocab
        key = ('漢字+かな' if kanji_ok and seg else
               'かなのみ' if seg else
               '漢字のみ' if kanji_ok else '不可')
        stats[key] += 1
        samples[key].append((name, kana, forms))
        if seg and any(w in PARTICLE_LIKE for w in seg):
            particle.append((name, kana, seg))

    total = len(seen)
    print(f'辞書 {len(vocab)}語（ひらがなのみ {len(hira_vocab)}語） / 営業中の駅名 {total}件\n')
    for key in ['漢字+かな', 'かなのみ', '漢字のみ', '不可']:
        n = stats[key]
        print(f'{key}: {n}件 ({n / total:.1%})')
        for name, kana, forms in samples[key][:a.show]:
            print(f'    {name}（{kana}） → ' + ' / '.join(forms or ['×']))
    print(f'\n分けた語に「は・へ・を」が単独で入る駅: {len(particle)}件（読みがずれる恐れ）')
    for name, kana, seg in particle[:a.show]:
        print(f'    {name}（{kana}） → {" ".join(seg)}')

if __name__ == '__main__':
    main()
