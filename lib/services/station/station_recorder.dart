// lib/services/station/station_recorder.dart
//
// 【確認用・後で消す】駅アラーム中のマイクの音を wav に残す。
//
// 電車で検知できない原因（音が小さい・雑音に埋もれている・イヤホン側で
// 消されている）を切り分けるため、駅アラームが実際に聞いていた音と、
// そのとき Vosk が何と聞き取ったか・GPS の距離を一緒に残す。
//
// 駅アラームの画面右上の ● で ON/OFF（既定は OFF）。リリースビルドでも使える。
//
// 保存先（1回の乗車ごとに wav と txt の組）:
//   iPhone : 「ファイル」アプリ > このiPhone内 > RAiM > station_rec
//   Android: 「ファイル」アプリ > ダウンロード > RAiM
//            録音中はアプリ専用のフォルダに書き、乗車が終わったら
//            ダウンロードへ写す（StationRecordingExport.kt）。
//            Android 9 以前は写せないので Android/data/com.ando.raim/files/station_rec に残る。
//
// 消すとき: 0117 のコミットを git revert する。手で消すなら
// 「【確認用・後で消す】」を grep して出てくるファイルと行を消す。

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:raim_prototype/services/mic_stream_service.dart';
import 'package:raim_prototype/services/raim_log.dart';

class StationRecorder {
  StationRecorder._(this._wav, this._log, this.path, this._startedAt);

  static const String _prefKey = 'debug.stationRecording';

  /// 残しておく乗車の数。古いものから消す（1時間で約115MB になるため）。
  static const int keepSessions = 5;

  /// 1回の乗車で録る長さの上限。超えた分は音だけ捨てる（txt は続ける）。
  static const Duration maxDuration = Duration(hours: 2);

  /// txt に音量を書く間隔。
  static const Duration levelInterval = Duration(seconds: 5);

  /// 録音する設定か（画面の ● の表示用）。[load] で読み込む。
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// 最後に保存した録音の場所（画面に出す）。まだ無ければ null。
  static final ValueNotifier<String?> lastSaved = ValueNotifier<String?>(null);

  /// 保存先の説明（画面に出す）。
  static String get whereLabel => Platform.isIOS
      ? '「ファイル」アプリ > このiPhone内 > RAiM > station_rec'
      : '「ファイル」アプリ > ダウンロード > RAiM（乗車を終えたときに保存）';

  static const MethodChannel _export = MethodChannel('raim_station_recording');

  /// ダウンロードへ写している途中のもの。次の録音はこれを待ってから始める。
  static Future<void> _exporting = Future.value();

  /// いま録音している乗車。録音していなければ null。
  static StationRecorder? _current;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_prefKey) ?? false;
    } catch (_) {
      // 読めなければ OFF のまま
    }
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (e) {
      RaimLog.w('[StationRec] 設定を保存できませんでした: ${e.runtimeType}');
    }
  }

  /// 保存先のフォルダ。
  static Future<Directory> directory() async {
    Directory? base;
    if (Platform.isAndroid) base = await getExternalStorageDirectory();
    base ??= await getApplicationDocumentsDirectory();
    return Directory('${base.path}${Platform.pathSeparator}station_rec');
  }

  /// 設定が ON なら録音を始める。OFF や失敗なら何もしない。
  static Future<void> startIfEnabled({required String destination}) async {
    await stop();
    await load();
    if (!enabled.value) return;

    try {
      final dir = await directory();
      await dir.create(recursive: true);
      // 前回アプリが途中で終わって写せなかった分があれば、先に写す
      if (Platform.isAndroid) {
        await _exporting;
        await _exportLeftovers(dir);
      }
      await _deleteOld(dir);

      final now = DateTime.now();
      final name = 'station_${_stamp(now)}';
      final sep = Platform.pathSeparator;
      final wavPath = '${dir.path}$sep$name.wav';

      final wav = await File(wavPath).open(mode: FileMode.write);
      await wav.writeFrom(_header(0));
      final log = File('${dir.path}$sep$name.txt').openWrite();

      final rec = StationRecorder._(wav, log, wavPath, now);
      _current = rec;
      rec._line('開始 降りる駅: $destination '
          '(${Platform.operatingSystem} / ${MicStreamService.sampleRate}Hz)');
      RaimLog.i('[StationRec] 録音を始めました: $wavPath');
    } catch (e) {
      RaimLog.w('[StationRec] 録音を始められませんでした: $e');
    }
  }

  /// 録音を止めて wav を仕上げる。録音していなければ何もしない。
  static Future<void> stop() async {
    final rec = _current;
    _current = null;
    await rec?._close();
  }

  /// マイクの音を足す（StationListener から、ライムが喋っている間も含めて全部）。
  static void add(Uint8List chunk) => _current?._add(chunk);

  /// txt に1行書く（聞き取った言葉・GPS・知らせなど）。
  static void note(String text) => _current?._line(text);

  // ─── 1回の乗車 ───

  final RandomAccessFile _wav;
  final IOSink _log;
  final String path;
  final DateTime _startedAt;

  Future<void> _writing = Future.value();
  int _bytes = 0;
  int _headerFixedAt = 0;
  bool _full = false;
  bool _closed = false;

  // 音量（levelInterval ごとに txt へ書く）
  double _sumSquares = 0;
  int _samples = 0;
  int _peak = 0;
  int _levelBytes = 0;

  static int get _maxBytes =>
      MicStreamService.sampleRate *
      MicStreamService.bytesPerSample *
      maxDuration.inSeconds;

  /// ヘッダの長さを書き直す間隔（30秒分）。
  static int get _headerFixBytes =>
      MicStreamService.sampleRate * MicStreamService.bytesPerSample * 30;

  static int get _levelBytesPerLine =>
      MicStreamService.sampleRate *
      MicStreamService.bytesPerSample *
      levelInterval.inSeconds;

  void _add(Uint8List chunk) {
    if (_closed) return;
    _measure(chunk);
    if (_full) return;
    if (_bytes + chunk.length > _maxBytes) {
      _full = true;
      _line('${maxDuration.inMinutes}分を超えたので、ここから先の音は残しません');
      return;
    }
    _bytes += chunk.length;
    final data = Uint8List.fromList(chunk);
    // ときどきヘッダの長さも書き直す。アプリが途中で落ちても、
    // そこまでの音を普通の wav として聞けるようにするため。
    final fixHeader = _bytes - _headerFixedAt >= _headerFixBytes;
    if (fixHeader) _headerFixedAt = _bytes;
    final total = _bytes;
    _writing = _writing.then((_) async {
      await _wav.writeFrom(data);
      if (fixHeader) {
        await _wav.setPosition(0);
        await _wav.writeFrom(_header(total));
        await _wav.setPosition(44 + total);
      }
    }).catchError((Object e) {
      RaimLog.w('[StationRec] 書き込めませんでした: ${e.runtimeType}');
      _full = true;
    });
  }

  void _measure(Uint8List chunk) {
    final view = ByteData.sublistView(chunk);
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      final s = view.getInt16(i, Endian.little);
      _sumSquares += s * s;
      final a = s.abs();
      if (a > _peak) _peak = a;
    }
    _samples += chunk.length ~/ 2;
    _levelBytes += chunk.length;
    if (_levelBytes < _levelBytesPerLine) return;

    final rms = _samples == 0 ? 0.0 : math.sqrt(_sumSquares / _samples);
    _line('音量 平均${_db(rms)}dB 最大${_db(_peak.toDouble())}dB');
    _sumSquares = 0;
    _samples = 0;
    _peak = 0;
    _levelBytes = 0;
  }

  void _line(String text) {
    if (_closed) return;
    final t = DateTime.now().difference(_startedAt);
    final m = t.inMinutes.toString().padLeft(2, '0');
    final s = (t.inMilliseconds % 60000 / 1000).toStringAsFixed(1).padLeft(4, '0');
    _log.writeln('[$m:$s] $text');
  }

  Future<void> _close() async {
    if (_closed) return;
    _line('終了');
    _closed = true;
    try {
      await _writing;
      // ヘッダの長さを書き直す
      final header = _header(_bytes);
      await _wav.setPosition(0);
      await _wav.writeFrom(header);
      await _wav.close();
    } catch (e) {
      RaimLog.w('[StationRec] wav を仕上げられませんでした: ${e.runtimeType}');
    }
    try {
      await _log.flush();
      await _log.close();
    } catch (_) {}
    RaimLog.i('[StationRec] 録音を保存しました: $path '
        '(${(_bytes / (MicStreamService.sampleRate * MicStreamService.bytesPerSample)).round()}秒)');

    final name = path.split(Platform.pathSeparator).last;
    if (Platform.isAndroid) {
      // 写すのに数秒かかることがあるので、乗車の終了は待たせない
      _exporting = _exportPair(path).then((ok) {
        lastSaved.value = ok
            ? 'ダウンロード > RAiM > $name'
            : '$path（ダウンロードへ写せませんでした）';
      });
    } else {
      lastSaved.value = 'station_rec > $name';
    }
  }

  /// wav と txt を「ダウンロード/RAiM」へ写し、写せたらアプリ側の分を消す。
  static Future<bool> _exportPair(String wavPath) async {
    final txtPath = '${wavPath.substring(0, wavPath.length - 4)}.txt';
    try {
      final wavOk = await _export.invokeMethod<bool>(
              'copyToDownloads', {'path': wavPath, 'mime': 'audio/wav'}) ??
          false;
      if (!wavOk) return false;
      final txtOk = await _export.invokeMethod<bool>(
              'copyToDownloads', {'path': txtPath, 'mime': 'text/plain'}) ??
          false;
      await File(wavPath).delete();
      if (txtOk) await File(txtPath).delete();
      RaimLog.i('[StationRec] ダウンロードへ写しました');
      return true;
    } catch (e) {
      RaimLog.w('[StationRec] ダウンロードへ写せませんでした: ${e.runtimeType}');
      return false;
    }
  }

  static Future<void> _exportLeftovers(Directory dir) async {
    try {
      // 写したものは消すので、一覧を取り終えてから写す
      final wavs = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.wav'))
          .map((e) => e.path)
          .toList();
      for (final wav in wavs) {
        await _exportPair(wav);
      }
    } catch (_) {}
  }

  // ─── 補助 ───

  static String _db(double amplitude) {
    if (amplitude <= 0) return '-inf';
    return (20 * math.log(amplitude / 32768) / math.ln10).toStringAsFixed(1);
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// 16bit モノラルの wav ヘッダ（44 バイト）。
  static Uint8List _header(int dataBytes) {
    const sampleRate = MicStreamService.sampleRate;
    const channels = 1;
    const bits = 16;
    final out = Uint8List(44);
    final v = ByteData.view(out.buffer);
    void ascii(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        out[at + i] = s.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    v.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    v.setUint32(16, 16, Endian.little);
    v.setUint16(20, 1, Endian.little);
    v.setUint16(22, channels, Endian.little);
    v.setUint32(24, sampleRate, Endian.little);
    v.setUint32(28, sampleRate * channels * bits ~/ 8, Endian.little);
    v.setUint16(32, channels * bits ~/ 8, Endian.little);
    v.setUint16(34, bits, Endian.little);
    ascii(36, 'data');
    v.setUint32(40, dataBytes, Endian.little);
    return out;
  }

  /// 古い乗車の録音を消して、新しく録る分を入れて [keepSessions] 個にする。
  static Future<void> _deleteOld(Directory dir) async {
    final wavs = <File>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.wav')) wavs.add(e);
    }
    wavs.sort((a, b) => a.path.compareTo(b.path)); // 名前が日時なので古い順
    final excess = wavs.length - (keepSessions - 1);
    for (var i = 0; i < excess; i++) {
      final wav = wavs[i];
      final txt = File('${wav.path.substring(0, wav.path.length - 4)}.txt');
      try {
        await wav.delete();
        if (await txt.exists()) await txt.delete();
      } catch (_) {}
    }
  }
}
