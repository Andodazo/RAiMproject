// lib/providers/voice_settings_provider.dart
//
// 音声機能の設定。端末ごとに保存する。
//
// 【なぜウェイクワードの既定を OFF にするか】
// 常時マイクを聞く機能を黙って有効にすると、ユーザーの同意なしに
// マイクが動いていることになる。デスクトップに常駐するアプリなら
// なおさら、明示的に ON にしてもらう形にする。
// 手動のマイクボタン（押したときだけ録る）は OFF にする理由がないので既定 ON。

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:raim_prototype/services/raim_log.dart';

/// ウェイクワードとして受け付ける言い方。
enum WakePhraseMode {
  /// 「ねえライム」のみ。誤検知と自己発火に最も強い。
  polite,

  /// 「ねえライム」と「ライム」の両方。呼びやすいが誤検知が増える。
  both,
}

/// 声で聞き取った文をどう送るか。
enum VoiceSendMode {
  /// 聞き取ったらすぐ送る。
  immediate,

  /// 数秒待ってから送る。その間に入力欄を触れば止まり、直してから送れる。
  delayed,

  /// 入力欄に入れるだけ。送信ボタンで送る。
  manual,
}

class VoiceSettingsProvider extends ChangeNotifier {
  static const _kWakeWordEnabled = 'voice.wakeWordEnabled';
  static const _kSendMode = 'voice.sendMode';
  static const _kManualMicEnabled = 'voice.manualMicEnabled';
  static const _kWakePhraseMode = 'voice.wakePhraseMode';
  static const _kMicDeviceId = 'voice.micDeviceId';
  static const _kSttEnabled = 'voice.sttEnabled';
  static const _kWeatherUsesLocation = 'weather.usesLocation';
  static const _kSpeechMuted = 'voice.speechMuted';

  SharedPreferences? _prefs;

  bool _wakeWordEnabled = false;
  bool _manualMicEnabled = true;
  WakePhraseMode _wakePhraseMode = WakePhraseMode.polite;
  String? _micDeviceId;
  bool _sttEnabled = true;
  VoiceSendMode _sendMode = VoiceSendMode.delayed;
  bool _weatherUsesLocation = false;
  bool _speechMuted = false;

  /// ライムの声（読み上げ）を消しているか。画面右上の音量ボタンで切り替える。
  ///
  /// 電車の中など、声を出したくない場面のため。文字はふだんどおり出る。
  /// 駅アラームの知らせる音は別の仕組みで鳴らしているので、これでは消えない。
  bool get speechMuted => _speechMuted;

  /// 場所を言わずに天気を聞いたとき、今いるあたり（約10km）の天気を返すか。
  ///
  /// ON の間は送信のたびに丸めた現在地を送るので、既定は OFF。
  /// ON にするときに位置情報の許可を求める（画面側）。
  /// 音声の設定ではないが、設定の置き場所がここしか無いので一緒に持つ。
  bool get weatherUsesLocation => _weatherUsesLocation;

  /// 常時待機（ウェイクワード検知）を使うか。
  bool get wakeWordEnabled => _wakeWordEnabled;

  /// 入力バーのマイクボタンを使うか。
  bool get manualMicEnabled => _manualMicEnabled;

  WakePhraseMode get wakePhraseMode => _wakePhraseMode;

  /// 使うマイクの識別子。null なら OS の既定。
  String? get micDeviceId => _micDeviceId;

  /// 呼ばれたあとに話した内容を聞き取って送るか。
  ///
  /// OFF にすると、呼ばれても入力小窓を開くだけになる。
  /// 聞き取りは Transcribe の利用料がかかるので、止められるようにしておく。
  bool get sttEnabled => _sttEnabled;

  /// 聞き取った文をどう送るか。
  ///
  /// 既定は「少し待ってから送る」。周りの声や聞き間違いが、そのまま
  /// ライムに送られてしまうのを防ぐため。
  VoiceSendMode get sendMode => _sendMode;

  /// 何らかの形でマイクを使うか。権限要求の要否判断に使う。
  bool get needsMicrophone => _wakeWordEnabled || _manualMicEnabled;

  /// Vosk の文法に入れるウェイクワード。
  ///
  /// 表記違いの「らいむ」も辞書にあるため、どちらで返っても
  /// 拾えるように両方入れる。
  List<String> get wakeWords => switch (_wakePhraseMode) {
        WakePhraseMode.polite => const ['ねえ ライム', 'ねえ らいむ'],
        WakePhraseMode.both => const [
            'ねえ ライム',
            'ねえ らいむ',
            'ライム',
            'らいむ',
          ],
      };

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;

    _wakeWordEnabled = prefs.getBool(_kWakeWordEnabled) ?? false;
    _manualMicEnabled = prefs.getBool(_kManualMicEnabled) ?? true;
    _micDeviceId = prefs.getString(_kMicDeviceId);
    _sttEnabled = prefs.getBool(_kSttEnabled) ?? true;
    _weatherUsesLocation = prefs.getBool(_kWeatherUsesLocation) ?? false;
    _speechMuted = prefs.getBool(_kSpeechMuted) ?? false;

    final sendName = prefs.getString(_kSendMode);
    _sendMode = VoiceSendMode.values.firstWhere(
      (m) => m.name == sendName,
      orElse: () => VoiceSendMode.delayed,
    );

    final modeName = prefs.getString(_kWakePhraseMode);
    _wakePhraseMode = WakePhraseMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => WakePhraseMode.polite,
    );

    RaimLog.i(
      '[VoiceSettings] 読み込み wake=$_wakeWordEnabled '
      'manual=$_manualMicEnabled mode=${_wakePhraseMode.name} '
      'stt=$_sttEnabled send=${_sendMode.name} mute=$_speechMuted '
      'mic=${_micDeviceId == null ? "既定" : "指定"}',
    );
    notifyListeners();
  }

  Future<void> setWeatherUsesLocation(bool value) async {
    if (_weatherUsesLocation == value) return;
    _weatherUsesLocation = value;
    notifyListeners();
    await _prefs?.setBool(_kWeatherUsesLocation, value);
    RaimLog.i('[Settings] 天気に現在地を使う: ${value ? "ON" : "OFF"}');
  }

  Future<void> setSpeechMuted(bool value) async {
    if (_speechMuted == value) return;
    _speechMuted = value;
    notifyListeners();
    await _prefs?.setBool(_kSpeechMuted, value);
    RaimLog.i('[VoiceSettings] ライムの声: ${value ? "消す" : "出す"}');
  }

  Future<void> setWakeWordEnabled(bool value) async {
    if (_wakeWordEnabled == value) return;
    _wakeWordEnabled = value;
    notifyListeners();
    await _prefs?.setBool(_kWakeWordEnabled, value);
    RaimLog.i('[VoiceSettings] ウェイクワード: ${value ? "ON" : "OFF"}');
  }

  Future<void> setManualMicEnabled(bool value) async {
    if (_manualMicEnabled == value) return;
    _manualMicEnabled = value;
    notifyListeners();
    await _prefs?.setBool(_kManualMicEnabled, value);
  }

  Future<void> setWakePhraseMode(WakePhraseMode mode) async {
    if (_wakePhraseMode == mode) return;
    _wakePhraseMode = mode;
    notifyListeners();
    await _prefs?.setString(_kWakePhraseMode, mode.name);
  }

  Future<void> setSttEnabled(bool value) async {
    if (_sttEnabled == value) return;
    _sttEnabled = value;
    notifyListeners();
    await _prefs?.setBool(_kSttEnabled, value);
    RaimLog.i('[VoiceSettings] 聞き取り: ${value ? "ON" : "OFF"}');
  }

  Future<void> setSendMode(VoiceSendMode mode) async {
    if (_sendMode == mode) return;
    _sendMode = mode;
    notifyListeners();
    await _prefs?.setString(_kSendMode, mode.name);
    RaimLog.i('[VoiceSettings] 聞き取った文の送り方: ${mode.name}');
  }

  Future<void> setMicDeviceId(String? id) async {
    if (_micDeviceId == id) return;
    _micDeviceId = id;
    notifyListeners();
    if (id == null) {
      await _prefs?.remove(_kMicDeviceId);
    } else {
      await _prefs?.setString(_kMicDeviceId, id);
    }
  }
}
