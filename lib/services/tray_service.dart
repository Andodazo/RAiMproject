import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:tray_manager/tray_manager.dart';

/// タスクトレイの常駐アイコン。
///
/// 入力小窓を閉じるとタスクバーからも消えるため、
/// トレイが唯一の復帰口になる。
/// 主要な機能は入力小窓の ☰ に置いてあるので、ここは詰み防止の3つだけ。
///
/// Windows のトレイは既定で「隠れているインジケーター」に折りたたまれる。
/// 主導線をここに置くと気づかれないので、あくまで保険として扱う。
class TrayService {
  TrayService._();
  static final TrayService instance = TrayService._();

  static const String keyShowInput = 'show_input';
  static const String keyShowLime = 'show_lime';
  static const String keyQuit = 'quit';

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
    debugPrint('[Tray] setup 開始 (supported=$isSupported, ready=$_ready)');

    if (!isSupported || _ready) return;

    try {
      await trayManager.setIcon(iconPath);
      debugPrint('[Tray] アイコンを設定: $iconPath');

      await trayManager.setToolTip('RAiM');
      await refreshMenu();

      _ready = true;
      debugPrint('[Tray] トレイアイコンを登録しました');
    } catch (e, st) {
      // トレイが使えなくても本体は動くので落とさない
      debugPrint('[Tray] 登録に失敗: $e');
      debugPrint('$st');
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
