import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/providers/voice_settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('初期値: ねえライムは OFF、聞き取りは ON、マイクは既定', () async {
    SharedPreferences.setMockInitialValues({});
    final s = VoiceSettingsProvider();
    await s.load();

    expect(s.wakeWordEnabled, isFalse);
    expect(s.sttEnabled, isTrue);
    expect(s.micDeviceId, isNull);
    expect(s.wakePhraseMode, WakePhraseMode.polite);
    // 聞き間違いがそのまま送られないよう、既定は「少し待ってから送る」
    expect(s.sendMode, VoiceSendMode.delayed);
  });

  test('聞き取った文の送り方は保存され、読み直しても残る', () async {
    SharedPreferences.setMockInitialValues({});
    final a = VoiceSettingsProvider();
    await a.load();
    await a.setSendMode(VoiceSendMode.manual);

    final b = VoiceSettingsProvider();
    await b.load();
    expect(b.sendMode, VoiceSendMode.manual);
  });

  test('変更は保存され、読み直しても残る', () async {
    SharedPreferences.setMockInitialValues({});
    final a = VoiceSettingsProvider();
    await a.load();
    await a.setWakeWordEnabled(true);
    await a.setSttEnabled(false);
    await a.setMicDeviceId('mic-1');
    await a.setWakePhraseMode(WakePhraseMode.both);

    final b = VoiceSettingsProvider();
    await b.load();
    expect(b.wakeWordEnabled, isTrue);
    expect(b.sttEnabled, isFalse);
    expect(b.micDeviceId, 'mic-1');
    expect(b.wakePhraseMode, WakePhraseMode.both);

    await b.setMicDeviceId(null);
    final c = VoiceSettingsProvider();
    await c.load();
    expect(c.micDeviceId, isNull);
  });

  test('ライムの声を消す設定は既定 OFF で、保存され読み直しても残る', () async {
    SharedPreferences.setMockInitialValues({});
    final a = VoiceSettingsProvider();
    await a.load();
    expect(a.speechMuted, isFalse);

    await a.setSpeechMuted(true);
    final b = VoiceSettingsProvider();
    await b.load();
    expect(b.speechMuted, isTrue);
  });

  test('「ライム」だけでも呼ぶ設定では単独の語も入る', () async {
    SharedPreferences.setMockInitialValues({});
    final s = VoiceSettingsProvider();
    await s.load();
    expect(s.wakeWords, isNot(contains('ライム')));

    await s.setWakePhraseMode(WakePhraseMode.both);
    expect(s.wakeWords, contains('ライム'));
  });
}
