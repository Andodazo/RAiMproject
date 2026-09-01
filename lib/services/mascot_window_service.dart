import 'dart:io' show Platform;

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Windows でデスクトップマスコット用の入力小窓を制御する。
///
/// Flutter のウィンドウを枠なし・最前面の細い横長ウィンドウにして、
/// ライムの足元に置く。☰ を押すと下端を固定したまま上に伸ばす。
///
/// 認証中は通常のウィンドウのままにしたいので、
/// 認証が済んでから [enterMascotMode] を呼ぶ。
class MascotWindowService {
  MascotWindowService._();
  static final MascotWindowService instance = MascotWindowService._();

  // ------------------------------------------------------------
  // サイズ定義
  // ------------------------------------------------------------

  /// 入力バーだけの高さ。
  ///
  /// 枠線(上下1pxずつ)ぶんを含んだウィンドウ全体の高さなので、
  /// 中身の Row はこれより2px小さく組む必要がある。
  static const double barHeight = 58;

  /// 枠線の太さ(上下合計)
  static const double borderWidth = 2;

  /// 選択中の画像サムネイル列の高さ
  static const double imageStripHeight = 54;

  /// ☰ パネルを開いたときの高さ。
  /// 項目が増えたら伸ばす。中身は ListView なので溢れてもスクロールする。
  static const double panelHeight = 380;

  /// 会話ログを開いたときの高さ
  static const double logHeight = 460;

  static const double windowWidth = 420;

  /// 認証前・ログイン画面のときのサイズ
  static const Size normalSize = Size(900, 700);

  // ------------------------------------------------------------
  // ライムとの位置関係
  // ------------------------------------------------------------

  /// ライムの足元からどれだけ下に置くか(px)。
  ///
  /// Unity が送ってくる足元Yはスプライトの矩形の下端なので、
  /// 絵の下に透明な余白があるとそのぶん下にズレる。
  /// マイナス値で詰められる。ホットリロードで効くので実機を見ながら調整する。
  static double gapBelowCharacter = -24;

  /// 配置の計算をログに出す。マルチモニタで位置がおかしいときに使う。
  static bool debugPosition = false;

  /// Unity が cx/cy を送ってこない古いビルド向けの保険。
  /// ウィンドウ幅に対するキャラ中心の位置（0=左端, 1=右端）。
  static double characterCenterRatio = 0.65;

  bool _mascotMode = false;
  bool get isMascotMode => _mascotMode;

  /// 入力小窓を表示しているか
  bool _visible = false;
  bool get isVisible => _visible;

  /// Unity の位置がまだ届いていない間に表示を頼まれたか。
  /// 届いた時点で改めて表示する。
  bool _pendingShow = false;

  /// ライムの位置が分かっているか
  bool get hasCharacterPosition => _unityRect != null;

  double _currentHeight = barHeight;

  /// Unity ウィンドウの最新の位置とサイズ
  Rect? _unityRect;

  /// ライムの中心X・足元Y（画面座標・上原点）。
  /// Unity が送ってくるので、ウィンドウ内のどこにキャラがいるかを
  /// Flutter 側で推測する必要がない。
  Offset? _characterFoot;

  /// ライムがいるモニタの作業領域（タスクバーを除いた範囲）。
  /// 入力小窓をこの中に収める。Unity が測って送ってくる。
  Rect? _workArea;

  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isWindows;
    } catch (_) {
      return false;
    }
  }

  /// main() で runApp より前に呼ぶ。
  static Future<void> initialize() async {
    if (!isSupported) return;

    await windowManager.ensureInitialized();

    // 認証前は普通のウィンドウ。マスコット化は認証後に行う。
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: normalSize,
        center: true,
        title: 'RAiM',
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  // ------------------------------------------------------------
  // モード切り替え
  // ------------------------------------------------------------

  /// 枠なし・最前面の入力小窓へ切り替える。
  Future<void> enterMascotMode() async {
    if (!isSupported || _mascotMode) return;
    _mascotMode = true;
    _currentHeight = barHeight;

    await windowManager.setAsFrameless();
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setResizable(false);
    await windowManager.setMinimizable(false);

    // タスクバーには残す。トレイだけだと見失ったときに戻れないため。
    await windowManager.setSkipTaskbar(false);

    await windowManager.setSize(const Size(windowWidth, barHeight));

    // Unity の位置が分かるまでは隠しておく。
    // 出しっぱなしにすると、Unity 起動前は見当違いの場所に窓が出て
    // 壊れているように見える。
    await hide();

    debugPrint('[Mascot] 入力小窓モードに切り替えました（クリック待ち）');
  }

  /// 通常ウィンドウに戻す（ログアウト時など）。
  ///
  /// 入力小窓は枠なしで小さく、しかも隠れていることがあるため、
  /// ログイン画面を出す前に必ず元の姿へ戻して表示する。
  Future<void> exitMascotMode() async {
    if (!isSupported || !_mascotMode) return;

    _mascotMode = false;
    _visible = false;
    _pendingShow = false;
    _currentHeight = barHeight;

    await windowManager.setAlwaysOnTop(false);
    await windowManager.setResizable(true);
    await windowManager.setMinimizable(true);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    await windowManager.setSize(normalSize);
    await windowManager.center();

    // 隠したまま抜けるとログイン画面が見えないので必ず出す
    await windowManager.show();
    await windowManager.focus();

    debugPrint('[Mascot] 通常ウィンドウに戻しました');
  }

  // ------------------------------------------------------------
  // 高さの変更（下端を固定して上に伸ばす）
  // ------------------------------------------------------------

  /// [height] へリサイズする。入力欄の位置が動かないよう下端を固定する。
  Future<void> setHeight(double height) async {
    if (!isSupported || !_mascotMode) return;
    if ((height - _currentHeight).abs() < 1) return;

    final pos = await windowManager.getPosition();

    // 下端 = pos.dy + 現在の高さ。これを保ったまま上へ伸ばす。
    final bottom = pos.dy + _currentHeight;
    final newY = bottom - height;

    _currentHeight = height;

    await windowManager.setSize(Size(windowWidth, height));
    await windowManager.setPosition(Offset(pos.dx, newY));
  }

  /// 画像を選んでいるかどうかでバーの高さが変わる
  bool _hasImages = false;

  Future<void> setHasImages(bool value) async {
    if (_hasImages == value) return;
    _hasImages = value;
    if (_currentHeight <= barHeight + imageStripHeight) {
      await collapse();
    }
  }

  double get _collapsedHeight =>
      barHeight + (_hasImages ? imageStripHeight : 0);

  Future<void> collapse() => setHeight(_collapsedHeight);
  Future<void> expandPanel() => setHeight(panelHeight);
  Future<void> expandLog() => setHeight(logHeight);

  // ------------------------------------------------------------
  // ライムへの追従
  // ------------------------------------------------------------

  // ------------------------------------------------------------
  // 座標系の変換
  // ------------------------------------------------------------
  // Unity は Win32 の GetWindowRect で取った「物理ピクセル」を送ってくる。
  // 一方 window_manager の setPosition / setSize は「論理ピクセル」で、
  // 表示倍率のぶん値が違う。
  //
  //   倍率100% : 物理 = 論理        （デスクトップ機はこれで一致していた）
  //   倍率125% : 物理 1000 → 論理 800
  //
  // 変換しないと、倍率が上がるほどライムから下へ離れていく。

  double get _scale {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return 1.0;
    final ratio = views.first.devicePixelRatio;
    return ratio > 0 ? ratio : 1.0;
  }

  /// Unity から届いた unity.moved を反映する。
  /// 引数はすべて物理ピクセル。ここで論理ピクセルへ直す。
  Future<void> onUnityMoved({
    required double x,
    required double y,
    required double width,
    required double height,
    double? characterCenterX,
    double? characterBottomY,
    Rect? workArea,
  }) async {
    final s = _scale;

    _unityRect = Rect.fromLTWH(x / s, y / s, width / s, height / s);

    if (characterCenterX != null && characterBottomY != null) {
      _characterFoot = Offset(characterCenterX / s, characterBottomY / s);
    }

    if (workArea != null && workArea.width > 0 && workArea.height > 0) {
      _workArea = Rect.fromLTWH(
        workArea.left / s,
        workArea.top / s,
        workArea.width / s,
        workArea.height / s,
      );
    }

    if (!_mascotMode) return;

    // 位置が分からずに表示を保留していたなら、ここで開く
    if (_pendingShow) {
      _pendingShow = false;
      await showAtCharacter();
      return;
    }

    // 隠しているときは動かさない。次に表示するときに位置を合わせる。
    if (!_visible) return;
    await _placeUnderCharacter();
  }

  /// setPosition の実行中フラグ。
  ///
  /// Unity は 60fps 近い頻度で位置を送ってくる。
  /// 1件ずつ await していると処理が溜まって、指を離した後も
  /// 窓が遅れて動き続ける。実行中は最新の目標だけ覚えておき、
  /// 終わってからまとめて反映する（中間の座標は捨てる）。
  bool _placing = false;
  bool _placeQueued = false;

  Future<void> _placeUnderCharacter() async {
    if (_placing) {
      _placeQueued = true;
      return;
    }

    _placing = true;
    try {
      await _applyPosition();

      // 待っている間に新しい座標が届いていたら、最新だけ反映する
      while (_placeQueued) {
        _placeQueued = false;
        await _applyPosition();
      }
    } finally {
      _placing = false;
    }
  }

  Future<void> _applyPosition() async {
    final rect = _unityRect;
    if (rect == null) return;

    // Unity が送ってきた足元の座標を使う。
    // 無ければウィンドウ幅からの推測に落とす（古いビルド向け）。
    final foot = _characterFoot;
    final centerX =
        foot?.dx ?? (rect.left + rect.width * characterCenterRatio);
    final footY = foot?.dy ?? rect.bottom;

    // 入力バーの下端がライムの足元の少し下に来るようにする。
    // パネルを開いて上に伸びてもバーの位置は変わらない。
    final top = footY + gapBelowCharacter + _collapsedHeight - _currentHeight;

    var left = centerX - windowWidth / 2;
    var placeTop = top;

    // ライムがいるモニタの中に収める。
    // 「画面座標が 0 以上」で判定してはいけない。
    // プライマリの左にサブモニタがあると座標が負になり、
    // 0 で押し戻すとサブモニタへ付いていけなくなる。
    final area = _workArea;
    if (area != null) {
      final maxLeft = area.right - windowWidth;
      if (maxLeft > area.left) {
        left = left.clamp(area.left, maxLeft);
      }

      final maxTop = area.bottom - _currentHeight;
      if (maxTop > area.top) {
        placeTop = placeTop.clamp(area.top, maxTop);
      }
    }

    if (debugPosition) {
      debugPrint('[Mascot] 配置: left=${left.toStringAsFixed(0)} '
          'top=${placeTop.toStringAsFixed(0)} '
          'foot=$foot area=$_workArea height=$_currentHeight '
          'scale=${_scale.toStringAsFixed(2)}');
    }

    await windowManager.setPosition(Offset(left, placeTop));
  }

  // ------------------------------------------------------------
  // 表示 / 非表示
  // ------------------------------------------------------------

  /// ライムがクリックされたときに呼ぶ。
  /// 位置を合わせてから出すので、ちらつかない。
  Future<void> showAtCharacter() async {
    if (!isSupported || !_mascotMode) return;

    // Unity の位置がまだ届いていないうちに出すと、前の位置のまま現れる。
    // Unity は2秒おきに強制送信してくるので、届いてから出す。
    if (_unityRect == null) {
      debugPrint('[Mascot] ライムの位置がまだ不明。届き次第表示します');
      _pendingShow = true;
      return;
    }

    await _placeUnderCharacter();
    await windowManager.show();
    await windowManager.focus();

    // 非表示中の setPosition は Windows で効かないことがあるため、
    // 表示してからもう一度合わせる。
    await _placeUnderCharacter();

    _visible = true;
    _pendingShow = false;
  }

  Future<void> hide() async {
    if (!isSupported) return;

    _visible = false;
    _pendingShow = false;

    // 次に開いたときバーだけの状態から始まるよう畳んでおく。
    // 隠れている間はリサイズしても見えないので位置は動かさない。
    _currentHeight = _collapsedHeight;
    await windowManager.setSize(Size(windowWidth, _currentHeight));

    await windowManager.hide();
  }

  /// クリックのたびに開閉を切り替える。
  Future<void> toggleAtCharacter() async {
    if (_visible) {
      await hide();
    } else {
      await showAtCharacter();
    }
  }
}