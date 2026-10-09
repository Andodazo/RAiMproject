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
import 'dart:math' as math;
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

  /// 使うマイクの識別子。null なら OS の既定。
  ///
  /// 次に [start] したときから効く。開いている間に変えても切り替わらない
  /// （切り替えるには一度 [stop] する。VoiceController がやる）。
  String? deviceId;

  /// 開いているマイクの識別子。null なら OS の既定か、開いていない。
  String? _openedDeviceId;
  String? get openedDeviceId => _openedDeviceId;

  int get _prerollLimit =>
      (sampleRate * prerollDuration.inMilliseconds ~/ 1000) *
      channels *
      bytesPerSample;

  /// マイクの許可を確認する。
  ///
  /// Windows では record の権限チェックが実装されていないため、
  /// 常に true が返る場合がある。実際に start() して例外が出るかで判断する。
  Future<bool> hasPermission() => _recorder.hasPermission();

  /// 使えるマイクの一覧。
  Future<List<MicDevice>> listDevices() async {
    final devices = await _recorder.listInputDevices();
    return [
      for (final d in devices) MicDevice(id: d.id, label: d.label),
    ];
  }

  /// 開いている途中のもの。
  Future<Stream<Uint8List>>? _starting;

  /// マイクを開く。既に開いていれば同じストリームを返す。
  ///
  /// 返るのはブロードキャストなので、ウェイクワード検知と録音の
  /// 両方が同時に listen できる。
  ///
  /// 開いている途中にもう一度呼ばれたら、同じ結果を待つ。
  /// 以前は開き終わるまで「開いていない」扱いだったため、ウェイクワードの
  /// 起動とマイクボタンが重なると、マイクを2回開こうとしていた。
  Future<Stream<Uint8List>> start() {
    final existing = _controller;
    if (existing != null) return Future.value(existing.stream);

    final pending = _starting;
    if (pending != null) return pending;

    late final Future<Stream<Uint8List>> future;
    future = _open().whenComplete(() {
      if (identical(_starting, future)) _starting = null;
    });
    _starting = future;
    return future;
  }

  Future<Stream<Uint8List>> _open() async {
    if (!await hasPermission()) {
      throw StateError('マイクの使用が許可されていません');
    }

    final id = deviceId;
    final raw = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        device: id == null ? null : InputDevice(id: id, label: ''),
        sampleRate: sampleRate,
        numChannels: channels,
        // Windows ではエコーキャンセルもノイズ抑制も効かない。
        // TTS の声を拾って自己発火する問題は、状態機械側で
        // 「喋っている間は検知に渡さない」ことで対処する。
        //
        // iPhone では切る。iOS はエコーキャンセルを使うとアプリ全体を
        // 通話の扱いにするので、本体の音量を0まで下げられなくなる
        // （下げても1段上に戻る）。ライムの声も小さくなり、
        // 他のアプリの音楽も小さくされる。
        // 自分の声で反応しないようにするのは、上と同じく状態機械側で足りている。
        echoCancel: !Platform.isIOS,
        noiseSuppress: true,
        // 他の音（ライムの声・駅アラームの声・音楽）が鳴っても録音を止めない。
        //
        // record の既定（pause）は、録音のために音声フォーカスを取り、
        // 他のアプリや自分のプレーヤーにフォーカスを取られると録音を一時停止する。
        // 再開は手動なので、Android ではライムが一度喋るとそれ以降マイクの音が
        // 一切届かなくなっていた（「ねえライム」も聞き取りも反応しない）。
        // ライムが喋っている間の扱いは、こちらで suspend/mute して決めている。
        audioInterruption: AudioInterruptionMode.none,
        // iOS: 録音中もライムの声をスピーカーから鳴らし、音楽アプリの再生も
        // 止めない（電車で音楽を聴きながら駅アラームを使えるように）
        //
        // allowHapticsAndSystemSoundsDuringRecording: iOS は録音中の振動を
        // 既定で止める。ウェイクワードのためにマイクはほぼずっと開いているので、
        // これが無いと「ねえライム」の合図も駅アラームの振動も震えない
        // （record が録音を始めるたびにこの値で上書きするので、ここで指定する）。
        iosConfig: const IosRecordConfig(
          allowHapticsAndSystemSoundsDuringRecording: true,
          categoryOptions: [
            IosAudioCategoryOption.defaultToSpeaker,
            IosAudioCategoryOption.allowBluetooth,
            IosAudioCategoryOption.allowBluetoothA2DP,
            IosAudioCategoryOption.mixWithOthers,
          ],
        ),
      ),
    );

    final controller = StreamController<Uint8List>.broadcast();
    _controller = controller;
    _openedDeviceId = id;

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
        _measure(chunk);
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
    // 開いている途中なら、開き終わるのを待ってから閉じる。
    // 待たないと、閉じたあとで開き終わってマイクが開いたまま残る。
    final pending = _starting;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // 開けなかったのなら閉じるものも無い
      }
    }

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
    _openedDeviceId = null;
    _resetMeter();

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

  // ─── 音量の記録（動作確認用） ───
  //
  // マイクが「開いたまま音が来なくなる」「無音しか来なくなる」を
  // 見分けるため、数秒ごとに届いた回数と最大音量をログに出す。

  static const Duration _meterInterval = Duration(seconds: 3);
  DateTime? _meterFrom;
  int _meterChunks = 0;
  int _meterPeak = 0;

  void _measure(Uint8List chunk) {
    final data = ByteData.sublistView(chunk);
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      final v = data.getInt16(i, Endian.little).abs();
      if (v > _meterPeak) _meterPeak = v;
    }
    _meterChunks++;

    final now = DateTime.now();
    final from = _meterFrom ??= now;
    if (now.difference(from) < _meterInterval) return;
    final db = _meterPeak == 0
        ? '-∞'
        : (20 * math.log(_meterPeak / 32768) / math.ln10).toStringAsFixed(0);
    RaimLog.d('[Mic] ${_meterInterval.inSeconds}秒: $_meterChunks回 最大 ${db}dB');
    _meterFrom = now;
    _meterChunks = 0;
    _meterPeak = 0;
  }

  void _resetMeter() {
    _meterFrom = null;
    _meterChunks = 0;
    _meterPeak = 0;
  }

  // ─── デバッグ用の録音 ───

  bool get isDumping => _dump != null;

  /// マイクを使い続けたい利用者。
  ///
  /// 駅アラームのように「ねえライム」とは別にマイクを使うものが登録する。
  /// 登録がある間は、ねえライムを OFF にしてもマイクを閉じない。
  final Set<Object> _holders = {};

  /// 誰かがマイクを使い続けたいと登録しているか。
  bool get isHeld => _holders.isNotEmpty;

  void hold(Object who) => _holders.add(who);
  void unhold(Object who) => _holders.remove(who);

  /// 今マイクの音を受け取っている相手がいるか。
  bool get hasListeners => _controller?.hasListener ?? false;

  /// 生の PCM を溜め始める。
  void startDump() {
    _dump = BytesBuilder(copy: false);
    RaimLog.i('[Mic] デバッグ録音を開始しました');
  }

  /// 溜めた PCM を wav にして保存し、そのパスを返す。
  ///
  /// 保存先はアプリ専用の作業領域。ドキュメント領域を使うと、
  /// Windows で OneDrive にリダイレクトされている環境では
  /// デバッグ用の wav が同期対象になってしまう。
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

    final dir = await getApplicationSupportDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final file = File('${dir.path}${Platform.pathSeparator}${prefix}_$stamp.wav');
    await file.writeAsBytes(wav, flush: true);

    final seconds = pcm.length / bytesPerSample / sampleRate;
    // 保存先はプラットフォームごとに違ううえ、探すのが手間なので
    // パスもそのまま出す。デバッグ専用のログ。
    RaimLog.i(
      '[Mic] デバッグ録音を保存しました '
      '(${seconds.toStringAsFixed(1)}秒 / ${wav.length}bytes)\n'
      '      ${file.path}',
    );
    return file.path;
  }
}

/// マイク1台ぶんの情報。
class MicDevice {
  const MicDevice({required this.id, required this.label});

  final String id;

  /// OS が付けた名前（例: 「マイク (Realtek High Definition Audio)」）
  final String label;
}
