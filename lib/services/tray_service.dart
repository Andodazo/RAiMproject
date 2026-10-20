import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:tray_manager/tray_manager.dart';
import 'package:raim_prototype/services/lime_size.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// タスクトレイの常駐アイコン。
///
/// 入力小窓を閉じるとタスクバーからも消えるため、
/// トレイが唯一の復帰口になる。
/// 主要な機能は入力小窓の ☰ に置いてあるので、ここは詰み防止の3つと、
/// ライムの大きさだけ。
///
/// Windows のトレイは既定で「隠れているインジケーター」に折りたたまれる。
/// 主導線をここに置くと気づかれないので、あくまで保険として扱う。
class TrayService {
  TrayService._();
  static final TrayService instance = TrayService._();

  static const String keyShowInput = 'show_input';
  static const String keyShowLime = 'show_lime';
  static const String keyQuit = 'quit';

  /// 「ライムの大きさ」の各項目のキー。後ろに LimeSize の名前を付ける
  static const String keyLimeSizePrefix = 'lime_size_';

  /// メニューのキーから、選ばれた大きさを返す。大きさの項目でなければ null。
  static LimeSize? limeSizeOf(String? key) {
    if (key == null || !key.startsWith(keyLimeSizePrefix)) return null;
    final name = key.substring(keyLimeSizePrefix.length);
    for (final size in LimeSize.values) {
      if (size.name == name) return size;
    }
    return null;
  }

  bool _ready = false;
  bool get isReady => _ready;

  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isWindows;
    } catch (_) {
      return false;
    }
  }

  /// アイコンのパス。pubspec の assets に含まれている必要がある。
  /// tray_manager がビルド後の flutter_assets を基準に解決する。
  static const String iconPath = 'assets/images/tray_icon.ico';

  /// トレイアイコンとメニューを登録する。
  /// main() から呼ぶ。ウィジェットのライフサイクルに依存させない。
  Future<void> setup() async {
    RaimLog.d('[Tray] setup 開始 (supported=$isSupported, ready=$_ready)');

    if (!isSupported || _ready) return;

    try {
      await trayManager.setIcon(iconPath);
      RaimLog.d('[Tray] アイコンを設定: $iconPath');

      await trayManager.setToolTip('RAiM');
      await refreshMenu();

      _ready = true;
      RaimLog.d('[Tray] トレイアイコンを登録しました');
    } catch (e, st) {
      // トレイが使えなくても本体は動くので落とさない
      RaimLog.e('[Tray] 登録に失敗: $e');
      RaimLog.d('$st');
    }
  }

  /// メニューを作り直す。
  ///
  /// [isUnityRunning] が false のときだけ「ライムを表示」を出す。
  /// 既に立っているのに押せると、何も起きないボタンになって紛らわしい。
  Future<void> refreshMenu({bool isUnityRunning = true}) async {
    if (!isSupported) return;

    final menu = Menu(
      items: [
        MenuItem(key: keyShowInput, label: '入力欄を出す'),
        if (!isUnityRunning)
          MenuItem(key: keyShowLime, label: 'ライムを表示'),
        MenuItem.submenu(
          label: 'ライムの大きさ',
          submenu: Menu(
            items: [
              for (final size in LimeSize.values)
                MenuItem.checkbox(
                  key: '$keyLimeSizePrefix${size.name}',
                  label: size.label,
                  checked: size == LimeSizeSetting.current.value,
                ),
            ],
          ),
        ),
        MenuItem.separator(),
        MenuItem(key: keyQuit, label: '終了'),
      ],
    );

    await trayManager.setContextMenu(menu);
  }

  Future<void> destroy() async {
    if (!isSupported || !_ready) return;
    _ready = false;
    await trayManager.destroy();
  }
}
