// SpeechBubbleSync（Windows の吹き出しを読み上げに合わせて出す）の確認

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/speech_bubble_sync.dart';

/// 時間を進める代わりに、予約されたタイマーを手で発火させる
class _FakeTimers {
  final List<_FakeTimer> timers = [];

  Timer schedule(Duration duration, void Function() callback) {
    final timer = _FakeTimer(duration, callback);
    timers.add(timer);
    return timer;
  }

  /// まだ取り消されていないタイマー
  List<_FakeTimer> get active => timers.where((t) => t.isActive).toList();

  /// 一番新しい有効なタイマーを発火させる
  void fireLatest() {
    final list = active;
    expect(list, isNotEmpty, reason: '待っているタイマーが無い');
    list.last.fire();
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// Core（response-queue-publisher.js の takeNextTextChunk）と同じ切り方。
/// 最初の「。！？!?、,改行」で切り、30文字以内に無ければ30文字目で切る。
List<String> _serverChunks(String text) {
  const max = 30;
  final end = RegExp(r'[。！？!?、,\n]');
  final chunks = <String>[];
  var rest = text;
  while (rest.isNotEmpty) {
    final m = end.firstMatch(rest);
    final length = m == null ? 0 : m.start + 1;
    if (length > 0 && length <= max) {
      chunks.add(rest.substring(0, length));
      rest = rest.substring(length);
    } else if (rest.length >= max) {
      chunks.add(rest.substring(0, max));
      rest = rest.substring(max);
    } else {
      chunks.add(rest);
      rest = '';
    }
  }
  return chunks;
}

void main() {
  late List<String> events;
  late _FakeTimers timers;
  late bool immediate;
  late SpeechBubbleSync sync;

  setUp(() {
    events = [];
    timers = _FakeTimers();
    immediate = false;
    sync = SpeechBubbleSync(
      onShow: (text) => events.add('show:$text'),
      onBreak: () => events.add('break'),
      onEnd: (fullText) => events.add('end'),
      isImmediate: () => immediate,
      scheduler: timers.schedule,
      pageChars: 20,
    );
  });

  test('文字は届いた時点では出さず、同じ chunk_id の声が鳴り始めたときに出す', () {
    sync.addText('c1', 'こんにちは。');
    sync.addText('c2', 'ライムだよ。');
    expect(events, isEmpty);

    sync.audioQueued('c1');
    sync.audioStarted('c1');
    expect(events, ['show:こんにちは。']);

    sync.audioQueued('c2');
    sync.audioFinished('c1');
    sync.audioStarted('c2');
    expect(events, ['show:こんにちは。', 'show:ライムだよ。']);
  });

  test('chat_end は、残りを出し切って声が鳴り終わってから伝える', () {
    sync.addText('c1', 'こんにちは。');
    sync.end('こんにちは。');
    expect(events, isEmpty);

    sync.audioQueued('c1');
    sync.audioStarted('c1');
    expect(events, ['show:こんにちは。']);

    sync.audioFinished('c1');
    expect(events, ['show:こんにちは。', 'end']);
  });

  test('1ページに収まらなくなったら、文の終わりで区切ってから次の文を出す', () {
    sync.addText('c1', 'あいうえおかきくけこ。');
    sync.addText('c2', 'さしすせそたちつてと。');
    sync.audioStarted('c1');
    sync.audioFinished('c1');
    sync.audioStarted('c2');
    expect(events, [
      'show:あいうえおかきくけこ。',
      'break',
      'show:さしすせそたちつてと。',
    ]);
  });

  test('「、」で切れたかたまりは、ページを替えずに同じページへつなげる', () {
    sync.addText('c1', 'あいうえおかきくけこ、');
    sync.addText('c2', 'さしすせそたちつてと。');
    sync.audioStarted('c1');
    sync.audioStarted('c2');
    expect(events, [
      'show:あいうえおかきくけこ、',
      'show:さしすせそたちつてと。',
    ]);
  });

  test('サーバーと同じ切り方の長い返事でも、ページは文の終わりで替わる', () {
    final long = SpeechBubbleSync(
      onShow: (text) => events.add('show:$text'),
      onBreak: () => events.add('break'),
      onEnd: (_) {},
      scheduler: timers.schedule,
    );
    const reply = '私はライムだよ！銀髪のショートボブに黄緑のメッシュが入った姿で、'
        '12種類の表情で気持ちを伝えるAIなの。おしゃべり以外にも、'
        '天気やネットの調べもの、駅アラームとかができるよ。'
        '日本工学院八王子専門学校の学生5人のチーム、Signさんが卒業研究で作ってくれたんだ。'
        '本当は喋れなかったんだけど、頑張って喋れるようにしてくれたんだよ！';
    final chunks = _serverChunks(reply);
    for (var i = 0; i < chunks.length; i++) {
      long.addText('c$i', chunks[i]);
    }
    for (var i = 0; i < chunks.length; i++) {
      long.audioStarted('c$i');
    }

    // ページごとにまとめる
    final pages = <String>[''];
    for (final e in events) {
      if (e == 'break') {
        pages.add('');
      } else {
        pages[pages.length - 1] += e.substring('show:'.length);
      }
    }
    expect(pages.join(), reply);
    for (final page in pages) {
      // 90文字を超えるページは作らない
      expect(page.length, lessThanOrEqualTo(long.maxPageChars), reason: page);
    }
    for (final page in pages.take(pages.length - 1)) {
      // 文の終わりか、長い文のときは「、」で終わる
      expect(RegExp(r'[。！？、]$').hasMatch(page), isTrue, reason: page);
    }
    // 50文字に収まるのに途中で替えたページは無い（短すぎるページが無い）
    expect(pages.where((p) => p.length < 10), isEmpty, reason: pages.join(' | '));
  });

  test('声が来ない文は、前の声が鳴り終わってから少し待って出す', () {
    sync.addText('c1', 'えっと。');
    sync.addText('c2', '？');
    sync.audioQueued('c1');
    sync.audioStarted('c1');
    expect(events, ['show:えっと。']);

    // 鳴っている間は待つ
    expect(timers.active, isEmpty);

    sync.audioFinished('c1');
    expect(events, ['show:えっと。']);
    timers.fireLatest();
    expect(events, ['show:えっと。', 'show:？']);
  });

  test('後の文の声が先に鳴り始めたら、声の無かった前の文も順番どおりに出す', () {
    sync.addText('c1', '？');
    sync.addText('c2', 'そうなんだ。');
    sync.audioQueued('c2');
    sync.audioStarted('c2');
    expect(events, ['show:？', 'show:そうなんだ。']);
  });

  test('声が1つも来なくても、chat_end の後に全部出して終わる', () {
    sync.addText('c1', 'あ。');
    sync.addText('c2', 'い。');
    sync.end(null);
    timers.fireLatest();
    timers.fireLatest();
    expect(events, ['show:あ。', 'show:い。', 'end']);
  });

  test('声が届いたのに鳴り始めないときも、待ちすぎずに出す', () {
    sync.addText('c1', 'あ。');
    sync.audioQueued('c1');
    timers.fireLatest();
    expect(events, ['show:あ。']);
    expect(timers.timers.last.duration, sync.audioStartLimit);
  });

  test('音量を切っているときは、待たずに届いた順に出す', () {
    immediate = true;
    sync.addText('c1', 'あ。');
    sync.end(null);
    expect(events, ['show:あ。', 'end']);
  });

  test('chunk_id が無い文字（古いサーバー）は、待たずに出す', () {
    sync.addText(null, 'あ。');
    expect(events, ['show:あ。']);
  });

  test('声を止めたら、待っていた文を全部出す', () {
    sync.addText('c1', 'あ。');
    sync.addText('c2', 'い。');
    sync.audioStarted('c1');
    sync.flush();
    expect(events, ['show:あ。', 'show:い。']);
  });

  test('bubble_break は前の文を出し終えてから入れる', () {
    sync.addText('c1', '調べるね。');
    sync.addBreak();
    sync.addText('c2', '晴れだよ。');
    sync.audioStarted('c1');
    expect(events, ['show:調べるね。', 'break']);
    sync.audioFinished('c1');
    sync.audioStarted('c2');
    expect(events, ['show:調べるね。', 'break', 'show:晴れだよ。']);
  });

  test('reset した後は、前の返事の文を出さない', () {
    sync.addText('c1', '前の返事。');
    sync.reset();
    sync.audioStarted('c1');
    for (final timer in timers.active) {
      timer.fire();
    }
    expect(events, isEmpty);
  });
}
