import 'dart:async';
import 'dart:io' show Platform;

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:raim_prototype/services/lime_size.dart';
import 'package:raim_prototype/services/raim_log.dart';

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

  /// 「発信中」を出しているときの高さ（Unity の起動待ち）
  static const double callingHeight = 128;

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
  ///
  /// ライムが 100% の大きさのときの値。透明な余白もライムと一緒に縮むので、
  /// 実際には選ばれた大きさ（タスクトレイ「ライムの大きさ」）の割合を掛けて使う。
  static double gapBelowCharacter = -24;

  double get _gapBelowCharacter =>
      gapBelowCharacter * LimeSizeSetting.current.value.scale;

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

  /// Unity の起動を待つ間、小窓に「発信中」を出しているか。
  ///
  /// 入力小窓は普段ライムの足元に出すが、起動中はライムがまだいないので
  /// 画面の中央に出す。入力小窓を開いたり隠したりすると false に戻る。
  final ValueNotifier<bool> calling = ValueNotifier<bool>(false);

  /// ユーザーが入力小窓をドラッグして任意位置へ置いたかどうか。
  /// 手動配置後はUnityの移動通知で元の位置へ戻さない。小窓を閉じると解除する。
  bool _manualPosition = false;

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
    _manualPosition = false;
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

    RaimLog.d('[Mascot] 入力小窓モードに切り替えました（クリック待ち）');
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
    calling.value = false;
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

    RaimLog.d('[Mascot] 通常ウィンドウに戻しました');
  }

  // ------------------------------------------------------------
  // 高さの変更（下端を固定して上に伸ばす）
  // ------------------------------------------------------------

  /// [height] へリサイズする。
  ///
  /// ライムに付いて動いているときは、高さに合った場所（背が高ければライムの横）へ
  /// 大きさと位置を一度に変える。手で動かした後は、入力欄の位置が動かないよう
  /// 下端を固定して上へ伸ばす。
  Future<void> setHeight(double height) async {
    if (!isSupported || !_mascotMode) return;
    if ((height - _currentHeight).abs() < 1) return;

    final place = _manualPosition ? null : _targetPosition(height);
    if (place != null) {
      _currentHeight = height;
      await windowManager.setBounds(
        Rect.fromLTWH(place.dx, place.dy, windowWidth, height),
      );
      return;
    }

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

    // 次に起動したとき「発信中」をここに出せるよう覚えておく
    _scheduleSaveLastPlace();

    if (!_mascotMode) return;

    // 手動配置中はUnityへの追従を停止する。Unityの最新座標自体は上で更新済み
    // なので、手動配置を解除した場合にも正しい位置へ戻れる。
    if (_manualPosition) return;

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
    final place = _targetPosition(_currentHeight);
    if (place == null) return;

    if (debugPosition) {
      RaimLog.d('[Mascot] 配置: left=${place.dx.toStringAsFixed(0)} '
          'top=${place.dy.toStringAsFixed(0)} '
          'foot=$_characterFoot area=$_workArea height=$_currentHeight '
          'scale=${_scale.toStringAsFixed(2)}');
    }

    await windowManager.setPosition(place);
  }

  /// 高さ [height] の小窓を置く位置。ライムの位置が分からなければ null。
  Offset? _targetPosition(double height) {
    // Unity が送ってきた足元の座標を使う。
    // 無ければウィンドウ幅からの推測に落とす（古いビルド向け）。
    final point = _footPoint();
    if (point == null) return null;
    return placeWindow(
      centerX: point.dx,
      footY: point.dy,
      characterTop: _unityRect?.top,
      area: _workArea,
      height: height,
      collapsedHeight: _collapsedHeight,
      gapBelow: _gapBelowCharacter,
    );
  }

  /// ライムの横に開くときの、ライムと小窓のすき間(px)
  static const double sideGap = 12;

  /// 立ち絵の幅 ÷ 高さ（assets/images の立ち絵は 753x2089）
  static const double characterAspect = 0.36;

  /// 小窓を置く位置を決める。
  ///
  /// 入力バーだけのときは、ライムの足元の少し下に置く。
  ///
  /// ☰ パネルや会話ログを開いて背が高くなったときは、ライムの横に置く。
  /// 以前は入力欄の位置を変えずに上へ伸ばしていたので、伸びた分が
  /// ライムの体と顔に重なって姿が見えなくなっていた。
  /// - 吹き出しはふだんライムの右に出るので、まず左に置く
  /// - 左に入らなければ右に置く
  /// - どちらにも入らなければ、広い方に置いて画面の中へ押し戻す（少し重なる）
  /// - 下端は入力バーのときと同じ高さにそろえる
  ///
  /// 座標はすべて論理ピクセル・画面座標（上原点）。
  /// [characterTop] は Unity ウィンドウの上端。ライムの幅の見積もりに使う。
  @visibleForTesting
  static Offset placeWindow({
    required double centerX,
    required double footY,
    required double? characterTop,
    required Rect? area,
    required double height,
    required double collapsedHeight,
    required double gapBelow,
  }) {
    // 入力バーの下端がライムの足元の少し下に来るようにする。
    // パネルを開いて背が高くなってもバーの下端の高さは変わらない。
    var top = footY + gapBelow + collapsedHeight - height;
    var left = centerX - windowWidth / 2;

    final expanded = height > collapsedHeight + 1;
    if (expanded) {
      // ライムの半分の幅。Unity ウィンドウの上端から足元までを
      // 立ち絵の高さとみなして見積もる（窓の方が高いので、少し広めに出る）。
      final characterHeight =
          characterTop == null ? 0.0 : (footY - characterTop).clamp(0.0, 4000.0);
      final halfWidth = characterHeight * characterAspect / 2;

      final leftSide = centerX - halfWidth - sideGap - windowWidth;
      final rightSide = centerX + halfWidth + sideGap;

      if (area == null || leftSide >= area.left) {
        left = leftSide;
      } else if (rightSide + windowWidth <= area.right) {
        left = rightSide;
      } else {
        final roomLeft = (centerX - halfWidth) - area.left;
        final roomRight = area.right - (centerX + halfWidth);
        left = roomLeft >= roomRight ? leftSide : rightSide;
      }
    }

    // ライムがいるモニタの中に収める。
    // 「画面座標が 0 以上」で判定してはいけない。
    // プライマリの左にサブモニタがあると座標が負になり、
    // 0 で押し戻すとサブモニタへ付いていけなくなる。
    if (area != null) {
      final maxLeft = area.right - windowWidth;
      if (maxLeft > area.left) {
        left = left.clamp(area.left, maxLeft);
      }

      final maxTop = area.bottom - height;
      if (maxTop > area.top) {
        top = top.clamp(area.top, maxTop);
      }
    }

    return Offset(left, top);
  }

  /// 入力バーのドラッグ開始時に呼ぶ。
  ///
  /// ネイティブのウィンドウドラッグを使うことで、DPI倍率や複数モニタの
  /// 座標計算をFlutter側で再実装せず、Windows自身に移動を任せる。
  Future<void> beginManualDrag() async {
    if (!isSupported || !_mascotMode || !_visible) return;
    _manualPosition = true;
    await windowManager.startDragging();
  }

  // ------------------------------------------------------------
  // 表示 / 非表示
  // ------------------------------------------------------------

  /// ライムがクリックされたときに呼ぶ。
  /// 位置を合わせてから出すので、ちらつかない。
  Future<void> showAtCharacter() async {
    if (!isSupported || !_mascotMode) return;

    // 「発信中」を出していたら、入力バーの大きさに戻してから表示する。
    if (calling.value) {
      calling.value = false;
      _currentHeight = _collapsedHeight;
      await windowManager.setSize(Size(windowWidth, _currentHeight));
    }

    if (!_manualPosition) {
      // Unity の位置がまだ届いていないうちに出すと、前の位置のまま現れる。
      // Unity は2秒おきに強制送信してくるので、届いてから出す。
      if (_unityRect == null) {
        RaimLog.d('[Mascot] ライムの位置がまだ不明。届き次第表示します');
        _pendingShow = true;
        return;
      }

      await _placeUnderCharacter();
    }

    // 再表示時にも最前面設定を確実に戻す。
    await windowManager.setAlwaysOnTop(true);
    await windowManager.show();
    await windowManager.focus();

    // 非表示中の setPosition は Windows で効かないことがあるため、
    // 表示してからもう一度合わせる。
    if (!_manualPosition) {
      await _placeUnderCharacter();
    }

    _visible = true;
    _pendingShow = false;
  }

  Future<void> hide() async {
    if (!isSupported) return;

    _visible = false;
    _pendingShow = false;
    calling.value = false;

    // 修正: 以前は一度手で動かすと、再起動かログアウトまで追従が戻らなかった。
    // 間違えて動かしたときに戻す方法がなかったので、閉じたら追従に戻す。
    _manualPosition = false;

    // 次に開いたときバーだけの状態から始まるよう畳んでおく。
    // 隠れている間はリサイズしても見えないので位置は動かさない。
    _currentHeight = _collapsedHeight;
    await windowManager.setSize(Size(windowWidth, _currentHeight));

    await windowManager.hide();
  }

  /// 外部認証ブラウザを操作できるよう、一時的に小窓の最前面表示をやめます。
  ///
  /// マスコット小窓は常に最前面なので、そのままだとブラウザの
  /// パスキー画面をクリックできないことがあります。
  // 修正: 以前は小窓を隠していた。ブラウザを閉じると callback が来ないため、
  // タイムアウトまでライムが消えたままになっていた。最前面をやめるだけにする。
  Future<void> prepareForExternalAuthentication() async {
    if (!isSupported || !_mascotMode) return;
    await windowManager.setAlwaysOnTop(false);
  }

  /// 外部認証ブラウザから戻った後に小窓を再表示します。
  Future<void> restoreAfterExternalAuthentication() async {
    if (!isSupported || !_mascotMode) return;
    await showAtCharacter();
  }

  /// Unity の起動を待つ間、「発信中」の小窓を出す。
  ///
  /// 前回ライムがいた場所の足元に出す。初めて起動したときは画面の中央。
  ///
  /// 入力小窓を開いているときは何もしない。
  Future<void> showCalling() async {
    if (!isSupported || !_mascotMode || _visible) return;

    calling.value = true;
    await windowManager.setSize(const Size(windowWidth, callingHeight));

    final place = await _lastCallingPosition();
    if (place == null) {
      await windowManager.center();
    } else {
      await windowManager.setPosition(place);
    }
    await windowManager.show();

    // 非表示中の setPosition は Windows で効かないことがあるため、表示してからもう一度
    if (place != null) await windowManager.setPosition(place);
  }

  // ------------------------------------------------------------
  // 前回ライムがいた場所
  // ------------------------------------------------------------
  // 「発信中」は Unity の起動を待つ間に出すので、まだライムの位置が分からない。
  // 前回ライムがいた場所を覚えておき、入力小窓と同じくその足元に出す。
  // ライムは前回の場所に戻ってくるので、そのまま「つながる」ように見える。

  static const String _kLastFootX = 'mascot.lastFootX';
  static const String _kLastFootY = 'mascot.lastFootY';
  static const String _kLastAreaLeft = 'mascot.lastAreaLeft';
  static const String _kLastAreaTop = 'mascot.lastAreaTop';
  static const String _kLastAreaWidth = 'mascot.lastAreaWidth';
  static const String _kLastAreaHeight = 'mascot.lastAreaHeight';

  /// ドラッグ中は位置が細かく届くので、止まってから保存する
  Timer? _saveTimer;

  void _scheduleSaveLastPlace() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_saveLastPlace());
    });
  }

  /// ライムの中心X・足元Y（論理ピクセル）。位置が分からなければ null。
  Offset? _footPoint() {
    final rect = _unityRect;
    if (rect == null) return null;
    // 足元の座標が無い古い Unity ビルドでは、ウィンドウ幅から推測する
    final foot = _characterFoot;
    return Offset(
      foot?.dx ?? (rect.left + rect.width * characterCenterRatio),
      foot?.dy ?? rect.bottom,
    );
  }

  Future<void> _saveLastPlace() async {
    final foot = _footPoint();
    final area = _workArea;
    if (foot == null || area == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kLastFootX, foot.dx);
      await prefs.setDouble(_kLastFootY, foot.dy);
      await prefs.setDouble(_kLastAreaLeft, area.left);
      await prefs.setDouble(_kLastAreaTop, area.top);
      await prefs.setDouble(_kLastAreaWidth, area.width);
      await prefs.setDouble(_kLastAreaHeight, area.height);
    } catch (e) {
      RaimLog.w('[Mascot] ライムの位置を保存できませんでした: ${e.runtimeType}');
    }
  }

  /// 「発信中」を出す位置。前回の場所が無ければ null（画面の中央に出す）。
  Future<Offset?> _lastCallingPosition() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final x = prefs.getDouble(_kLastFootX);
      final y = prefs.getDouble(_kLastFootY);
      final al = prefs.getDouble(_kLastAreaLeft);
      final at = prefs.getDouble(_kLastAreaTop);
      final aw = prefs.getDouble(_kLastAreaWidth);
      final ah = prefs.getDouble(_kLastAreaHeight);
      if (x == null || y == null || al == null || at == null ||
          aw == null || ah == null || aw <= 0 || ah <= 0) {
        return null;
      }
      final area = Rect.fromLTWH(al, at, aw, ah);

      // 入力バーと同じく、ライムの足元の少し下に出す。
      // 縦に長いので、画面の下にはみ出すぶんは上へずらす（_applyPosition と同じ考え方）
      var left = x - windowWidth / 2;
      var top = y + _gapBelowCharacter;

      final maxLeft = area.right - windowWidth;
      if (maxLeft > area.left) left = left.clamp(area.left, maxLeft);
      final maxTop = area.bottom - callingHeight;
      if (maxTop > area.top) top = top.clamp(area.top, maxTop);

      return Offset(left, top);
    } catch (e) {
      RaimLog.w('[Mascot] 前回の位置を読めませんでした: ${e.runtimeType}');
      return null;
    }
  }

  /// 「発信中」の小窓を消す。
  ///
  /// その間に入力小窓を開いていたら（[calling] が false に戻っている）何もしない。
  Future<void> endCalling() async {
    if (!calling.value) return;
    await hide();
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
