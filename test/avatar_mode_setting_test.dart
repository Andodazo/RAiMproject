import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/models/avatar_mode.dart';
import 'package:raim_prototype/services/avatar_mode_setting.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('未保存と不正な保存値は現在の3D表示を選ぶ', () async {
    for (final values in <Map<String, Object>>[
      {},
      {'avatar_mode': 'unknown'},
    ]) {
      SharedPreferences.setMockInitialValues(values);
      expect(await AvatarModeSetting.load(), AvatarMode.threeD);
    }
  });

  test('保存した2Dを次回の読み込みでも選ぶ', () async {
    SharedPreferences.setMockInitialValues({});
    await AvatarModeSetting.load();
    await AvatarModeSetting.set(AvatarMode.twoD);
    expect(await AvatarModeSetting.load(), AvatarMode.twoD);
  });

  test('連続選択は直ちに通知し、保存は最後の選択で終わる', () async {
    SharedPreferences.setMockInitialValues({});
    await AvatarModeSetting.load();
    var notifications = 0;
    void changed() => notifications++;
    AvatarModeSetting.current.addListener(changed);
    try {
      final first = AvatarModeSetting.set(AvatarMode.twoD);
      final second = AvatarModeSetting.set(AvatarMode.threeD);
      final third = AvatarModeSetting.set(AvatarMode.twoD);
      expect(AvatarModeSetting.current.value, AvatarMode.twoD);
      expect(notifications, 3);
      await Future.wait([first, second, third]);
      await AvatarModeSetting.set(AvatarMode.twoD);
      expect(notifications, 3);
      expect(await AvatarModeSetting.load(), AvatarMode.twoD);
    } finally {
      AvatarModeSetting.current.removeListener(changed);
    }
  });
}
