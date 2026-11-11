import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:raim_prototype/models/avatar_mode.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// 選択の保存だけを担当する。Unityへの転送はアプリ起動部で行う。
class AvatarModeSetting {
  AvatarModeSetting._();

  static const _prefKey = 'avatar_mode';
  static final _current = ValueNotifier<AvatarMode>(AvatarMode.threeD);
  static ValueListenable<AvatarMode> get current => _current;
  static Future<void> _pendingSave = Future<void>.value();

  static Future<AvatarMode> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _current.value =
          AvatarMode.tryParse(prefs.getString(_prefKey)) ?? AvatarMode.threeD;
    } catch (error) {
      RaimLog.w('[AvatarMode] 表示設定を読めませんでした: ${error.runtimeType}');
      _current.value = AvatarMode.threeD;
    }
    return _current.value;
  }

  static Future<void> set(AvatarMode mode) {
    _current.value = mode;
    // 保存を直列化し、先に選んだ値が後から保存されるのを防ぐ。
    final saving = _pendingSave.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_prefKey, mode.wireValue)) {
        throw StateError('Avatar mode was not saved');
      }
    });
    // 失敗後も次の選択を保存できるよう、内部の列だけは回復させる。
    _pendingSave = saving.catchError((Object error, StackTrace stack) {
      RaimLog.e('[AvatarMode] 表示設定を保存できませんでした: ${error.runtimeType}');
    });
    return saving;
  }
}
