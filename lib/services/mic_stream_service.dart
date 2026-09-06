// lib/services/mic_stream_service.dart
//
// マイク入力を **1本だけ** 開いて、複数の利用者に配る。
//
// 【なぜ1本にするか】
// 素直に作ると「ウェイクワード検知が止まる → STT がマイクを開き直す」になるが、
// デバイスの閉じ直しに 0.2〜0.5 秒かかる。その間の音が落ちるので
// 「ねえライム、明日の天気」と続けて言うと後半の頭が欠ける。
// 1本のストリームを開きっぱなしにして、聞く側を切り替える方式にする。
//
// 【プリロール】
// 直近の音を常に保持しておく。ウェイクワードを検知した時点では
// 発話はもう始まっているので、検知の「前」から録れていないと頭が欠ける。
//
// 【デバッグ】
// startDump/stopDump で生の PCM を wav に落とせる。
// 音声は失敗してもエラーが出ないので、耳で確認する手段は必須。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/wav_writer.dart';

class MicStreamService {
  MicStreamService._();
  static final MicStreamService instance = MicStreamService._();

  /// Vosk も Transcribe も 16kHz を前提にしている。
  /// ここを変えると両方の設定を揃える必要がある。
  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int bytesPerSample = 2;

  /// プリロールとして保持する長さ。
  /// ウェイクワードの発話（約1秒）＋反応の余裕を見て少し長めに取る。
  static const Duration prerollDuration = Duration(milliseconds: 1500);

  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Uint8List>? _sub;
  StreamController<Uint8List>? _controller;

  /// 直近の音を溜めておくリングバッファ代わり。
  /// 単純な List で持ち、超えたぶんを先頭から捨てる。
  final BytesBuilder _preroll = BytesBuilder(copy: false);
  int _prerollBytes = 0;

  /// デバッグ用の録音バッファ。null のときは録っていない。
  BytesBuilder? _dump;

  bool get isRunning => _controller != null;

  int get _prerollLimit =>
      (sampleRate * prerollDuration.inMilliseconds ~/ 1000) *
      channels *
      bytesPerSample;

  /// マイクの許可を確認する。
  ///
  /// Windows では record の権限チェックが実装されていないため、
  /// 常に true が返る場合がある。実際に start() して例外が出るかで判断する。
  Future<bool> hasPermission() => _recorder.hasPermission();

  /// マイクを開く。既に開いていれば同じストリームを返す。
  ///
  /// 返るのはブロードキャストなので、ウェイクワード検知と録音の
  /// 両方が同時に listen できる。
  Future<Stream<Uint8List>> start() async {
    final existing = _controller;
    if (existing != null) return existing.stream;

    if (!await hasPermission()) {
      throw StateError('マイクの使用が許可されていません');
    }

    final raw = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
        // Windows ではエコーキャンセルもノイズ抑制も効かない。
        // TTS の声を拾って自己発火する問題は、状態機械側で
        // 「喋っている間は検知に渡さない」ことで対処する。
        echoCancel: true,
        noiseSuppress: true,
      ),
    );

    final controller = StreamController<Uint8List>.broadcast();
    _controller = controller;

    var chunkLogged = false;
    _sub = raw.listen(
      (chunk) {
        // 最初の1回だけチャンクサイズを出す。
        // 想定と違うと後段のフレーム分割が全部ずれるので、
        // 実測値を必ず確認できるようにしておく。
        if (!chunkLogged) {
          chunkLogged = true;
          RaimLog.i(
            '[Mic] 開始 rate=$sampleRate ch=$channels '
            'chunk=${chunk.length}bytes '
            '(${(chunk.length / bytesPerSample / sampleRate * 1000).toStringAsFixed(1)}ms相当)',
          );
        }
        _pushPreroll(chunk);
        _dump?.add(chunk);
        controller.add(chunk);
      },
      onError: (Object e, StackTrace s) {
        RaimLog.e('[Mic] ストリームでエラー', e);
        controller.addError(e, s);
      },
      onDone: () {
        RaimLog.i('[Mic] ストリームが終了しました');
        unawaited(stop());
      },
    );

    return controller.stream;
  }

  Future<void> stop() async {
    final sub = _sub;
    final controller = _controller;
    _sub = null;
    _controller = null;

    await sub?.cancel();
    try {
      await _recorder.stop();
    } catch (e) {
      RaimLog.w('[Mic] stop に失敗しました: ${e.runtimeType}');
    }
    await controller?.close();

    _preroll.clear();
    _prerollBytes = 0;
    RaimLog.i('[Mic] 停止しました');
  }

  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
  }

  /// 直近 [prerollDuration] ぶんの音を取り出す。
  ///
  /// ウェイクワード検知の直後に呼び、この続きから録音を始めると
  /// 発話の頭が欠けない。
  Uint8List takePreroll() {
    final bytes = _preroll.takeBytes();
    _prerollBytes = 0;
    // takeBytes は中身を空にするので、続きを溜め直す。
    _preroll.add(bytes);
    _prerollBytes = bytes.length;
    return Uint8List.fromList(bytes);
  }

  void _pushPreroll(Uint8List chunk) {
    _preroll.add(chunk);
    _prerollBytes += chunk.length;
    if (_prerollBytes <= _prerollLimit) return;

    // 上限を超えたら古いぶんを捨てる。
    // BytesBuilder は前方を削れないので、一度取り出して詰め直す。
    final all = _preroll.takeBytes();
    final keep = all.sublist(all.length - _prerollLimit);
    _preroll.add(keep);
    _prerollBytes = keep.length;
  }

  // ─── デバッグ用の録音 ───

  bool get isDumping => _dump != null;

  /// 生の PCM を溜め始める。
  void startDump() {
    _dump = BytesBuilder(copy: false);
    RaimLog.i('[Mic] デバッグ録音を開始しました');
  }

  /// 溜めた PCM を wav にして保存し、そのパスを返す。
  ///
  /// 保存先はアプリのドキュメント領域。Windows なら
  /// C:\Users\<user>\Documents\... 配下に出る。
  Future<String?> stopDumpAndSave({String prefix = 'mic'}) async {
    final dump = _dump;
    _dump = null;
    if (dump == null) return null;

    final pcm = dump.takeBytes();
    if (pcm.isEmpty) {
      RaimLog.w('[Mic] デバッグ録音が空でした');
      return null;
    }

    final wav = WavWriter.fromPcm16(
      pcm: Uint8List.fromList(pcm),
      sampleRate: sampleRate,
      channels: channels,
    );

    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final file = File('${dir.path}${Platform.pathSeparator}${prefix}_$stamp.wav');
    await file.writeAsBytes(wav, flush: true);

    final seconds = pcm.length / bytesPerSample / sampleRate;
    RaimLog.i(
      '[Mic] デバッグ録音を保存しました '
      '(${seconds.toStringAsFixed(1)}秒 / ${wav.length}bytes)',
    );
    return file.path;
  }
}
