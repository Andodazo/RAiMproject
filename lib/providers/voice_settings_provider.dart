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

class VoiceSettingsProvider extends ChangeNotifier {
  static const _kWakeWordEnabled = 'voice.wakeWordEnabled';
  static const _kManualMicEnabled = 'voice.manualMicEnabled';
  static const _kWakePhraseMode = 'voice.wakePhraseMode';
  static const _kMicDeviceId = 'voice.micDeviceId';

  SharedPreferences? _prefs;

  bool _wakeWordEnabled = false;
  bool _manualMicEnabled = true;
  WakePhraseMode _wakePhraseMode = WakePhraseMode.polite;
  String? _micDeviceId;

  /// 常時待機（ウェイクワード検知）を使うか。
  bool get wakeWordEnabled => _wakeWordEnabled;

  /// 入力バーのマイクボタンを使うか。
  bool get manualMicEnabled => _manualMicEnabled;

  WakePhraseMode get wakePhraseMode => _wakePhraseMode;

  /// 使うマイクの識別子。null なら OS の既定。
  String? get micDeviceId => _micDeviceId;

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

    final modeName = prefs.getString(_kWakePhraseMode);
    _wakePhraseMode = WakePhraseMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => WakePhraseMode.polite,
    );

    RaimLog.i(
      '[VoiceSettings] 読み込み wake=$_wakeWordEnabled '
      'manual=$_manualMicEnabled mode=${_wakePhraseMode.name}',
    );
    notifyListeners();
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
