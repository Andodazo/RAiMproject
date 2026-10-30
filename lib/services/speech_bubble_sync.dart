import 'dart:async';

/// Windows のライムの吹き出しを、読み上げの声に合わせて出す。
///
/// 【なぜ必要か】
/// 文字（text_chunk）は 0.14〜0.27 秒ごとに届き、声よりずっと先に進む。
/// 届いたそばから吹き出しへ出すと、長い返事では吹き出しの高さの上限を超え、
/// 読み上げる前に頭の文が消えていた。
///
/// 【合わせ方】
/// サーバーは1つの文ごとに chunk_id を振り、同じ chunk_id で文字と声を送ってくる。
/// 文字はここに持っておき、同じ chunk_id の声が鳴り始めたときに吹き出しへ出す。
/// 1ページに収まらなくなったら、文の終わりで吹き出しを区切って次のページにする。
///
/// 【声が来ないとき】
/// 次のどれでも、文字が出ないまま残らないようにする。
/// - 「？」だけの文など、サーバーが声を作らない
/// - 声の生成や再生に失敗した
/// - 声が届くのが遅い
///   → 前の声が鳴り終わってから [audioWait] 待っても声が来なければ出す
/// - 音量ボタンで声を消している、話しかけて声を止めた、chunk_id が無い
///   → 待たずにすぐ出す（[isImmediate]）
/// - 声が鳴り終わったという知らせが来ない
///   → [audioStallLimit] 待っても進まなければ、鳴り終わったことにする
class SpeechBubbleSync {
  SpeechBubbleSync({
    required this.onShow,
    required this.onBreak,
    required this.onEnd,
    bool Function()? isImmediate,
    Timer Function(Duration, void Function())? scheduler,
    this.audioWait = const Duration(milliseconds: 2500),
    this.audioStartLimit = const Duration(seconds: 6),
    this.audioStallLimit = const Duration(seconds: 20),
    this.pageChars = 50,
    this.commaPageChars = 70,
    this.maxPageChars = 90,
  })  : _isImmediate = isImmediate ?? (() => false),
        _scheduler = scheduler ?? Timer.new;

  /// 吹き出しに文を足す
  final void Function(String text) onShow;

  /// 吹き出しを区切る（次の文から新しいページ）
  final void Function() onBreak;

  /// 返事が終わった（吹き出しの消去タイマーを始める）
  final void Function(String? fullText) onEnd;

  final bool Function() _isImmediate;
  final Timer Function(Duration, void Function()) _scheduler;

  /// 声が鳴っていないのに声が来ない文を、出すまで待つ時間
  final Duration audioWait;

  /// 声は届いたのに鳴り始めないときに、あきらめて出すまでの時間
  final Duration audioStartLimit;

  /// 声が鳴り始めたのに鳴り終わりが来ないときに、鳴り終わったことにするまでの時間。
  ///
  /// 鳴り終わりを待ったままだと、残りの文も chat_end も吹き出しへ伝わらず、
  /// 吹き出しが消えなくなる。1つの文の声は長くても十数秒なので、それより長く取る。
  final Duration audioStallLimit;

  /// 1ページに入れる文字数の目安。超えそうなら、文の終わりで次のページにする。
  ///
  /// サーバーは文字を「。」だけでなく「、」や30文字ごと（言葉の途中でも）で切って
  /// 送ってくる。その切れ目でページを替えると、文や言葉の途中で替わって読みにくい。
  /// そのため、ページを替えるのは前の文字が文の終わり（。！？）のときだけにする。
  final int pageChars;

  /// 文が終わらないまま、ここまで長くなったら「、」の後でページを替える
  final int commaPageChars;

  /// それでも終わらないとき、ここを超えたら切れ目がどこでもページを替える。
  /// Unity の吹き出しの高さの上限（超えると古い行から消す）に掛からないため
  final int maxPageChars;

  /// 今のページに最後に出した文字
  String _lastShown = '';

  static final RegExp _sentenceEnd = RegExp(r'[。！？!?…\n][」』）)\s]*$');
  static final RegExp _commaEnd = RegExp(r'[、,][\s]*$');

  /// まだ吹き出しに出していない文と区切り（届いた順）
  final List<_Item> _pending = [];

  /// 今鳴っている声の chunk_id
  String? _playingId;

  /// chat_end を受け取ったが、まだ吹き出しへ伝えていない
  bool _endPending = false;
  String? _fullText;

  /// 今のページに出した文字数
  int _pageLength = 0;

  Timer? _timer;

  /// 文字が届いた
  void addText(String? chunkId, String text) {
    if (text.isEmpty) return;
    final id = chunkId?.trim() ?? '';
    if (id.isEmpty || _isImmediate()) {
      // 待っている文があれば、順番が入れ替わらないよう先に出す
      _releaseAll();
      _show(text);
      return;
    }
    _pending.add(_Item.text(id, text));
    _schedule();
  }

  /// bubble_break が届いた（ツールの前置きと本文を分ける）
  void addBreak() {
    if (_pending.isEmpty) {
      _break();
      return;
    }
    _pending.add(_Item.breakMark());
  }

  /// 声がそろって再生の順番待ちに入った
  void audioQueued(String? chunkId) {
    final item = _find(chunkId);
    if (item == null) return;
    item.audioQueued = true;
    _schedule();
  }

  /// 声が鳴り始めた。その文（と、それより前の文）を出す
  void audioStarted(String? chunkId) {
    _playingId = chunkId;
    final index = _indexOf(chunkId);
    if (index >= 0) {
      for (var i = 0; i <= index; i++) {
        _release(_pending.removeAt(0));
      }
    }
    _schedule();
  }

  /// 声が鳴り終わった（失敗した場合も含む）
  void audioFinished(String? chunkId) {
    if (_playingId == chunkId) _playingId = null;
    _schedule();
  }

  /// chat_end が届いた。残りを出し切って、声も鳴り終わったら吹き出しへ伝える
  void end(String? fullText) {
    _endPending = true;
    _fullText = fullText;
    if (_isImmediate()) _releaseAll();
    _schedule();
  }

  /// 待たずに全部出す（話しかけて声を止めたとき）
  void flush() {
    _releaseAll();
    _playingId = null;
    _schedule();
  }

  /// 捨てる（新しい送信、会話の切り替え、エラー）
  void reset() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _playingId = null;
    _endPending = false;
    _fullText = null;
    _pageLength = 0;
    _lastShown = '';
  }

  void dispose() => reset();

  // ------------------------------------------------------------

  void _schedule() {
    _timer?.cancel();
    _timer = null;

    if (_pending.isEmpty) {
      if (_endPending && _playingId == null) {
        _endPending = false;
        final fullText = _fullText;
        _fullText = null;
        _pageLength = 0;
        _lastShown = '';
        onEnd(fullText);
        return;
      }
      // 返事は終わったのに、最後の声の鳴り終わりが来ない
      if (_endPending) _watchStall();
      return;
    }

    final head = _pending.first;
    if (head.isBreak) {
      _release(_pending.removeAt(0));
      _schedule();
      return;
    }

    // 前の声が鳴っている間は待つ。その間にこの文の声が届くことが多い。
    // 鳴り終わると audioFinished からまたここへ来る
    if (_playingId != null) {
      _watchStall();
      return;
    }

    // 声が届いていれば鳴り始めるのを待つ（鳴らないときの保険だけ掛ける）。
    // 届いていなければ、少し待っても来ないときに文字だけ出す
    _timer = _scheduler(
      head.audioQueued ? audioStartLimit : audioWait,
      _releaseHead,
    );
  }

  /// 鳴り終わりが来ないまま止まったときの保険を掛ける
  void _watchStall() {
    _timer = _scheduler(audioStallLimit, _onAudioStalled);
  }

  void _onAudioStalled() {
    _timer = null;
    _playingId = null;
    _schedule();
  }

  void _releaseHead() {
    _timer = null;
    if (_pending.isEmpty) return;
    _release(_pending.removeAt(0));
    _schedule();
  }

  void _releaseAll() {
    while (_pending.isNotEmpty) {
      _release(_pending.removeAt(0));
    }
  }

  void _release(_Item item) {
    if (item.isBreak) {
      _break();
    } else {
      _show(item.text);
    }
  }

  void _show(String text) {
    if (_shouldTurnPage(text.length)) _break();
    onShow(text);
    _pageLength += text.length;
    _lastShown = text;
  }

  /// 次の文字（[length] 文字）を出す前に、ページを替えるか
  bool _shouldTurnPage(int length) {
    if (_pageLength == 0) return false;
    final total = _pageLength + length;
    if (total <= pageChars) return false;
    // 文の終わりなら替える
    if (_sentenceEnd.hasMatch(_lastShown)) return true;
    // 文が長く続くときは「、」の後で替える
    if (total > commaPageChars && _commaEnd.hasMatch(_lastShown)) return true;
    // それでも収まらないときだけ、どこででも替える
    return total > maxPageChars;
  }

  void _break() {
    onBreak();
    _pageLength = 0;
    _lastShown = '';
  }

  int _indexOf(String? chunkId) {
    if (chunkId == null) return -1;
    return _pending.indexWhere((item) => item.chunkId == chunkId);
  }

  _Item? _find(String? chunkId) {
    final index = _indexOf(chunkId);
    return index < 0 ? null : _pending[index];
  }
}

class _Item {
  _Item.text(this.chunkId, this.text) : isBreak = false;

  _Item.breakMark()
      : chunkId = null,
        text = '',
        isBreak = true;

  final String? chunkId;
  final String text;
  final bool isBreak;
  bool audioQueued = false;
}
