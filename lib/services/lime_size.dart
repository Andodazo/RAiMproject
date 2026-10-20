import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows のデスクトップのライムの大きさ（タスクトレイの「ライムの大きさ」）。
///
/// Unity の窓（800×700）ごと縮めるので、ライムも同じ割合で小さくなる。
/// ノートパソコンの画面だと 100% ではライムが画面の高さの大半を占めていた。
enum LimeSize {
  small('小', 0.6),
  medium('中', 0.8),
  large('大', 1.0);

  const LimeSize(this.label, this.scale);

  /// メニューに出す名前
  final String label;

  /// Unity の窓の大きさの倍率（1 で元の大きさ）
  final double scale;
}

class LimeSizeSetting {
  LimeSizeSetting._();

  static const String _prefKey = 'windows_lime_size';

  /// 一度も選んでいないときの大きさ。Unity 側の既定（DefaultScale）と合わせる。
  static const LimeSize defaultSize = LimeSize.medium;

  static final ValueNotifier<LimeSize> current =
      ValueNotifier<LimeSize>(defaultSize);

  /// 前回選ばれた大きさを読む。
  static Future<LimeSize> load() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_prefKey);
    current.value = LimeSize.values.firstWhere(
      (size) => size.name == name,
      orElse: () => defaultSize,
    );
    return current.value;
  }

  /// 大きさを選んで覚えておく。
  static Future<void> set(LimeSize size) async {
    current.value = size;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, size.name);
  }
}
