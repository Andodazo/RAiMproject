import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// サーバーから届いた audio_chunk を順番に再生するためのクラス
///
/// audio_chunk は Base64 文字列で届くので、
/// 1. Base64 を音声バイトに戻す
/// 2. キューに入れる
/// 3. 前の音声が終わったら次を再生する
/// という流れで処理する。
class AudioPlayQueue {
  /// 実際に音声を再生するプレイヤー
  final AudioPlayer _player = AudioPlayer();

  /// 再生待ちの音声を順番に入れておくキュー
  final Queue<_QueuedAudio> _queue = Queue<_QueuedAudio>();

  /// 音声の再生完了を監視する購読
  late final StreamSubscription<void> _completeSubscription;

  /// 現在、音声を再生中かどうか
  bool _isPlaying = false;

  /// dispose 後に再生処理が動かないようにするためのフラグ
  bool _disposed = false;

  /// reset() のたびに増える世代番号
  ///
  /// _playNext() は `await _player.play()` の間に制御を手放す。
  /// その隙に reset() が入ると、stop() の「後」に再生が始まってしまい、
  /// 前の返答の音声が新しい返答に重なって残る。
  /// 再生開始後に世代が変わっていたら、その音は捨てる。
  int _generation = 0;

  AudioPlayQueue() {
    // 1つの音声が終わったら、次の音声を再生する
    _completeSubscription = _player.onPlayerComplete.listen((_) {
      _isPlaying = false;
      _playNext();
    });
  }

  /// audio_chunk をキューに追加する
  ///
  /// [base64Audio] はサーバーから届く audio の文字列。
  /// [format] は wav / mp3 / ogg などの音声形式。
  void enqueue({
    required String base64Audio,
    String format = 'wav',
  }) {
    if (_disposed) return;

    try {
      // data:audio/wav;base64,... の形式にも対応できるように整形する
      final normalizedBase64 = _normalizeBase64(base64Audio);

      // Base64 文字列を音声バイトに変換する
      final bytes = base64Decode(normalizedBase64);

      enqueueBytes(bytes: bytes, format: format);
    } catch (e) {
      RaimLog.e('[AudioPlayQueue] 音声デコード失敗: $e');
    }
  }

  /// デコード済みの音声をキューに追加する。
  /// 分割WAVを再構成した音声の投入にも使用する。
  void enqueueBytes({required Uint8List bytes, String format = 'wav'}) {
    if (_disposed) return;

    _queue.add(
      _QueuedAudio(
        bytes: bytes,
        mimeType: _mimeTypeFromFormat(format),
      ),
    );

    RaimLog.d(
      '[AudioPlayQueue] キュー追加完了: '
      'queue=${_queue.length}',
    );

    // 今なにも再生していなければ、すぐ再生開始する
    if (!_isPlaying) {
      _playNext();
    }
  }

  /// 現在の再生と、待機中の音声をすべて止める
  ///
  /// 新しいユーザーメッセージを送るときに、
  /// 前の返答音声が残らないようにするために使う。
  Future<void> reset() async {
    _generation++;
    _queue.clear();
    _isPlaying = false;
    await _player.stop();
  }

  /// 待機中の音声だけを捨て、再生中の1つは最後まで鳴らす
  ///
  /// サーバーは文（句読点）単位で音声を作っているので、
  /// 「今喋っている1文は言い切ってから黙る」挙動になる。
  /// 長くても数秒で、人が割り込まれたときの振る舞いに近い。
  ///
  /// 即座に黙らせたいときは [reset] を使う。
  void stopAfterCurrent() {
    if (_disposed) return;

    final dropped = _queue.length;
    _queue.clear();

    if (dropped > 0) {
      RaimLog.d('[AudioPlayQueue] 待機中の音声 $dropped 件を破棄しました');
    }
  }

  /// AudioPlayQueue を破棄する
  ///
  /// ChatProvider の dispose から呼び出す。
  Future<void> dispose() async {
    _disposed = true;
    _queue.clear();
    await _completeSubscription.cancel();
    await _player.dispose();
  }

  /// キューの先頭にある音声を1つ再生する
  Future<void> _playNext() async {
    if (_disposed || _isPlaying || _queue.isEmpty) {
      return;
    }

    // この再生がどの世代のものかを覚えておく
    final generation = _generation;

    _isPlaying = true;

    // キューの先頭から音声を取り出す
    final audio = _queue.removeFirst();

    RaimLog.d(
      '[AudioPlayQueue] 再生開始: '
      'bytes=${audio.bytes.length}, mimeType=${audio.mimeType}',
    );

    try {
      // バイト列から音声を再生する
      await _player.play(
        BytesSource(
          audio.bytes,
          mimeType: audio.mimeType,
        ),
      );

      // 再生開始を待っている間に reset() が入っていたら、
      // 今始まった音は前の返答のものなので止める。
      if (generation != _generation) {
        RaimLog.d('[AudioPlayQueue] reset 済みのため再生を打ち切ります');
        await _player.stop();
        _isPlaying = false;
      }
    } catch (e) {
      RaimLog.e('[AudioPlayQueue] 音声再生失敗: $e');

      // reset 済みなら次へ進めない（捨てたキューを掘り返さない）
      if (generation != _generation) return;

      // 失敗した場合も次の音声へ進める
      _isPlaying = false;
      _playNext();
    }
  }

  /// Base64 文字列をデコードしやすい形に整える
  ///
  /// サーバーによっては、
  /// data:audio/wav;base64,xxxx
  /// のような形式で届くことがあるため、カンマ以降だけ取り出す。
  String _normalizeBase64(String value) {
    final trimmed = value.trim();

    if (!trimmed.startsWith('data:')) {
      return trimmed;
    }

    final commaIndex = trimmed.indexOf(',');
    if (commaIndex == -1) {
      return trimmed;
    }

    return trimmed.substring(commaIndex + 1);
  }

  /// format 文字列から MIME type に変換する
  ///
  /// BytesSource に MIME type を渡すと、
  /// 環境によって音声形式を判定しやすくなる。
  String? _mimeTypeFromFormat(String format) {
    switch (format.toLowerCase()) {
      case 'wav':
        return 'audio/wav';
      case 'mp3':
        return 'audio/mpeg';
      case 'ogg':
        return 'audio/ogg';
      default:
        return null;
    }
  }
}

/// キューに入れる1件分の音声データ
class _QueuedAudio {
  const _QueuedAudio({
    required this.bytes,
    required this.mimeType,
  });

  /// 再生する音声のバイト列
  final Uint8List bytes;

  /// 音声形式を表す MIME type
  final String? mimeType;
}
