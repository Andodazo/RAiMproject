// lib/services/planner/windows_lock_state.dart
//
// Windows の画面がロックされているか。
//
// 予定を知らせる時刻に PC がロックされていたら、ライムは喋らず通知だけにする
// （誰もいない部屋で喋り出さないように。安藤さんと決めた）。
//
// ロック中は「入力を受け付けるデスクトップ」がログオン画面に切り替わり、
// 普通のアプリからは開けない。開けなければロック中とみなす。

import 'dart:ffi';
import 'dart:io' show Platform;

typedef _OpenInputDesktopNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenInputDesktopDart = int Function(int, int, int);
typedef _CloseDesktopNative = Int32 Function(IntPtr);
typedef _CloseDesktopDart = int Function(int);

class WindowsLockState {
  WindowsLockState._();

  /// DESKTOP_SWITCHDESKTOP
  static const int _desktopSwitchDesktop = 0x0100;

  static _OpenInputDesktopDart? _open;
  static _CloseDesktopDart? _close;

  /// ロック中なら true。Windows 以外や、分からないときは false。
  static bool isLocked() {
    if (!Platform.isWindows) return false;
    try {
      if (_open == null || _close == null) {
        final user32 = DynamicLibrary.open('user32.dll');
        _open = user32.lookupFunction<_OpenInputDesktopNative, _OpenInputDesktopDart>(
          'OpenInputDesktop',
        );
        _close = user32.lookupFunction<_CloseDesktopNative, _CloseDesktopDart>(
          'CloseDesktop',
        );
      }
      final desktop = _open!(0, 0, _desktopSwitchDesktop);
      if (desktop == 0) return true;
      _close!(desktop);
      return false;
    } catch (_) {
      return false;
    }
  }
}
