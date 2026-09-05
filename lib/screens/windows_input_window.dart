import 'dart:async';
import 'dart:io' show File, exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/providers/camera_provider.dart';
import 'package:raim_prototype/providers/auth_provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/services/mascot_window_service.dart';
import 'package:raim_prototype/services/raim_server_service.dart';
import 'package:raim_prototype/services/tray_service.dart';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/config/raim_config.dart';

/// Windows のデスクトップマスコット用の入力小窓。
///
/// 通常は入力バーだけの細い横長ウィンドウ。
/// ☰ を押すとパネルが下端を固定したまま上に伸びる。
///
/// Overlay を使わず Column を伸ばすだけにしてあるのは、
/// Overlay.insert したエントリが Navigator のルートより上に来てしまい、
/// PopupMenuButton や showDialog が裏に回る問題を避けるため。
/// 削除確認も行のインライン表示にしている。
class WindowsInputWindow extends StatefulWidget {
  const WindowsInputWindow({super.key});

  @override
  State<WindowsInputWindow> createState() => _WindowsInputWindowState();
}

enum _PanelMode { none, menu, log, credits }

class _WindowsInputWindowState extends State<WindowsInputWindow>
    with TrayListener {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _windowFocusNode = FocusNode();
  final _mascot = MascotWindowService.instance;

  StreamSubscription<Map<String, dynamic>>? _unitySub;
  _PanelMode _mode = _PanelMode.none;

  /// 削除確認を出しているスレッド
  String? _confirmingDeleteId;

  /// 前フレームで画像を選んでいたか（ウィンドウの高さ調整用）
  bool _hadImages = false;

  // ---- 開発検証用: 接続先切り替え ----
  // chat_input.dart の ChatMenuButton と同じ手順。URL は RaimConfig に集約。
  static const String _awsUrl = RaimConfig.serverUrl;
  static const String _localUrl = RaimConfig.localServerUrl;

  bool _isSwitching = false;
  String? _switchNote;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _enterMascotMode());
  }

  Future<void> _enterMascotMode() async {
    await _mascot.enterMascotMode();

    // 通常は main() で登録済み。_ready を見て二重登録はしないので、
    // ここで呼んでも無害。ログアウト→再ログインの経路で効く。
    await TrayService.instance.setup();

    if (mounted) _listenUnity();
  }

  // ------------------------------------------------------------
  // トレイ
  // ------------------------------------------------------------
  // 入力小窓を閉じるとタスクバーからも消えるため、
  // トレイが唯一の復帰口になる。

  @override
  void onTrayIconMouseDown() {
    // 左クリックで入力欄を開閉する
    if (_mascot.isVisible) {
      _closeWindow();
    } else {
      _mascot.showAtCharacter();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    final connected = context.read<UnityCommunicator>().isUnityConnected;
    TrayService.instance
        .refreshMenu(isUnityRunning: connected)
        .then((_) => trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case TrayService.keyShowInput:
        _mascot.showAtCharacter();
        _focusNode.requestFocus();
        break;

      case TrayService.keyShowLime:
        // Unity が落ちているときだけメニューに出る
        context.read<UnityCommunicator>().ensureUnityRunning();
        break;

      case TrayService.keyQuit:
        _quit();
        break;
    }
  }

  void _listenUnity() {
    final bridge = context.read<UnityCommunicator>();
    _unitySub = bridge.unityEvents.listen((event) async {
      switch (event['type']) {
        case 'unity.clicked':
          // ライムをクリックするたびに入力小窓を開閉する
          if (_mascot.isVisible) {
            await _closeWindow();
          } else {
            await _mascot.showAtCharacter();
            if (mounted && _mascot.isVisible) _focusNode.requestFocus();
          }
          break;

        case 'unity.moved':
          // 8765 は誰でも繋げるうえ、Unity のビルドが古いと
          // フィールドが欠けることもある。非 null キャストだと
          // listener の中で TypeError になり、以降のイベントが止まる。
          final x = (event['x'] as num?)?.toDouble();
          final y = (event['y'] as num?)?.toDouble();
          final width = (event['width'] as num?)?.toDouble();
          final height = (event['height'] as num?)?.toDouble();

          if (x == null || y == null || width == null || height == null) {
            RaimLog.w('[WindowsInputWindow] unity.moved の座標が不正なので無視します');
            break;
          }

          await _mascot.onUnityMoved(
            x: x,
            y: y,
            width: width,
            height: height,
            characterCenterX: (event['cx'] as num?)?.toDouble(),
            characterBottomY: (event['cy'] as num?)?.toDouble(),
            workArea: _readWorkArea(event),
          );
          break;
      }
    });
  }

  /// unity.moved に載っているモニタの作業領域を読む。
  /// 古い Unity ビルドでは無いので null になる。
  Rect? _readWorkArea(Map<String, dynamic> event) {
    final mx = (event['mx'] as num?)?.toDouble();
    final my = (event['my'] as num?)?.toDouble();
    final mw = (event['mw'] as num?)?.toDouble();
    final mh = (event['mh'] as num?)?.toDouble();

    if (mx == null || my == null || mw == null || mh == null) return null;
    if (mw <= 0 || mh <= 0) return null;

    return Rect.fromLTWH(mx, my, mw, mh);
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    _unitySub?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _windowFocusNode.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------
  // パネルの開閉（ウィンドウごとリサイズする）
  // ------------------------------------------------------------

  Future<void> _setMode(_PanelMode mode) async {
    if (_mode == mode) mode = _PanelMode.none;

    setState(() {
      _mode = mode;
      _confirmingDeleteId = null;
    });

    switch (mode) {
      case _PanelMode.none:
        await _mascot.collapse();
        break;
      case _PanelMode.menu:
        await _mascot.expandPanel();
        if (mounted) unawaited(context.read<ChatProvider>().loadThreads());
        break;
      case _PanelMode.log:
        await _mascot.expandLog();
        break;
      case _PanelMode.credits:
        await _mascot.expandPanel();
        break;
    }
  }

  // ------------------------------------------------------------
  // 送信（chat_input.dart と同じ手順）
  // ------------------------------------------------------------

  void _send() {
    final text = _controller.text.trim();
    final camera = context.read<CameraProvider>();
    final hasImage = camera.hasImage;

    if (text.isEmpty && !hasImage) return;

    // sendUserMessage は async で、最初の await で制御が戻る。
    // その隙に clearImage() が走るため、参照のまま渡すと空になる。
    // selectedImagePaths は非 null なので null 判定は不要（常に真だった）
    final paths = List<String>.from(camera.selectedImagePaths);
    final base64 = camera.selectedImagesBase64 != null
        ? List<String>.from(camera.selectedImagesBase64!)
        : null;

    context.read<ChatProvider>().sendUserMessage(
          text,
          images: base64,
          filePaths: paths,
        );

    _controller.clear();
    camera.clearImage();
  }

  // ------------------------------------------------------------
  // 接続先の切り替え（開発検証用）
  // ------------------------------------------------------------
  // 小窓に SnackBar は出しにくいので、メニュー行の下に状態を出す。

  Future<void> _switchServer() async {
    if (_isSwitching) return;
    _isSwitching = true;
    setState(() => _switchNote = '切り替え中…');

    try {
      final raimService = context.read<RaimServerService>();
      final isAws = RaimConfig.isAwsUrl(raimService.serverUrl);
      final targetUrl = isAws ? _localUrl : _awsUrl;

      final token = await context.read<AuthProvider>().getValidAccessToken();
      await raimService.switchServer(targetUrl, accessToken: token);

      if (mounted) {
        setState(() =>
            _switchNote = isAws ? 'Tailscale に切り替えました' : 'AWS に切り替えました');
      }
    } catch (e) {
      if (mounted) setState(() => _switchNote = '切り替えに失敗: $e');
    } finally {
      _isSwitching = false;
    }
  }

  Future<void> _pickImage() async {
    await context.read<CameraProvider>().pickAndStoreImage(ImageSource.gallery);
  }

  /// Unity を終了させてから自分も終わる。
  ///
  /// 二段構えにしてある:
  ///   1. app.quit を送って Unity 自身に終了してもらう
  ///      （Unity Editor や手動起動でも効く）
  ///   2. stop() で子プロセスを kill する
  ///      （Flutter が起動した場合の保険）
  Future<void> _quit() async {
    final bridge = context.read<UnityCommunicator>();

    try {
      bridge.sendAppQuit();
      // 送信が WebSocket に乗るのを待つ
      await Future.delayed(const Duration(milliseconds: 300));
      await bridge.stop();
      await TrayService.instance.destroy();
    } catch (_) {
      // 終了処理なので失敗しても構わない
    }

    exit(0);
  }

  // ------------------------------------------------------------
  // 見た目
  // ------------------------------------------------------------

  static const _bg = Color(0xFF1B1F26);
  static const _bg2 = Color(0xFF232830);
  static const _line = Color(0xFF333A44);
  static const _text = Color(0xFFE8ECF0);
  static const _mut = Color(0xFF8B97A4);
  static const _lime = Color(0xFFA3E635);

  /// 画像を選ぶとサムネイル列のぶんウィンドウを高くする。
  /// build 中に window 操作はできないので次フレームで行う。
  void _syncImageStripHeight(bool hasImages) {
    if (_hadImages == hasImages) return;
    _hadImages = hasImages;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mascot.setHasImages(hasImages);
    });
  }

  /// パネルを畳んでから隠す。
  /// 畳まずに隠すと、次に開いたときの高さと状態がずれる。
  Future<void> _closeWindow() async {
    if (_mode != _PanelMode.none) {
      setState(() {
        _mode = _PanelMode.none;
        _confirmingDeleteId = null;
      });
    }
    await _mascot.hide();
  }

  /// Esc で閉じる。ライムをもう一度クリックすれば開く。
  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey != LogicalKeyboardKey.escape) return;

    if (_mode != _PanelMode.none) {
      _setMode(_PanelMode.none);
    } else {
      _closeWindow();
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncImageStripHeight(context.watch<CameraProvider>().hasImage);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: KeyboardListener(
        focusNode: _windowFocusNode,
        onKeyEvent: _handleKey,
        child: Container(
        decoration: BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: _line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          // パネルは上へ伸びるので、バーは常に下端に置く
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_mode != _PanelMode.none)
              Expanded(
                child: switch (_mode) {
                  _PanelMode.menu => _buildMenu(),
                  _PanelMode.log => _buildLog(),
                  _PanelMode.credits => _buildCredits(),
                  _PanelMode.none => const SizedBox.shrink(),
                },
              ),
            const _SelectedImageStrip(),
            _buildBar(),
          ],
        ),
      ),
      ),
    );
  }

  // ---------- 入力バー ----------

  /// 入力欄のプレースホルダに出す状態表示。
  ///
  /// 何も起きていないときは null を返す（通常のヒント文に戻る）。
  String? _statusText(ChatProvider chat) {
    if (chat.isOffline) return null;

    // ツール実行中は、何を調べているかを出す。
    if (chat.isUsingTool) {
      final status = chat.toolStatus;
      if (status != null && status.isNotEmpty) return status;
      return '調べているよ…';
    }

    if (chat.isThinking) return '考えているよ…';

    return null;
  }

  String _hintText(ChatProvider chat) {
    if (chat.isOffline) return '接続待ち…';
    return _statusText(chat) ?? '何でも話してね';
  }

  Widget _buildBar() {
    final chat = context.watch<ChatProvider>();

    // 高さを固定しない。
    //
    // 表示倍率が 100% 以外だとウィンドウの論理サイズが小数になり
    // （例: 58px を要求しても実際は 57.6px）、
    // 枠線ぶんを引いた値をそのまま指定すると 1px 未満だけはみ出す。
    // 中身に必要な高さ（約34px）はウィンドウ高より十分小さいので、
    // 固定せず Row の自然な高さに任せれば余白が緩衝材になる。
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            _iconButton(
              Icons.menu,
              'メニュー',
              () => _setMode(_PanelMode.menu),
              active: _mode == _PanelMode.menu,
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: !chat.isOffline,
                style: const TextStyle(color: _text, fontSize: 13),
                cursorColor: _lime,
                decoration: InputDecoration(
                  isDense: true,
                  // マスコットモードには状態表示の場所が無いため、
                  // プレースホルダを状態表示に兼用する。
                  // 「〇〇を調べています」はチャット画面（message_list）に
                  // しか出ておらず、Windows では何も出ていなかった。
                  hintText: _hintText(chat),
                  hintStyle: TextStyle(
                    color: _statusText(chat) != null ? _lime : _mut,
                    fontSize: 13,
                  ),
                  filled: true,
                  fillColor: _bg2,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                  border: _border(_line),
                  enabledBorder: _border(_line),
                  focusedBorder: _border(_lime),
                  disabledBorder: _border(_line),
                ),
                // 生成中は Enter でも送らない（ボタンは既に無効化済み）
                onSubmitted: (_) {
                  if (context.read<ChatProvider>().isLoading) return;
                  _send();
                },
              ),
            ),
            _iconButton(Icons.attach_file, '画像を送る', _pickImage),
            _iconButton(Icons.mic_none, '音声入力（未実装）', null),
            const SizedBox(width: 4),
            SizedBox(
              width: 32,
              height: 32,
              child: ElevatedButton(
                onPressed: chat.isLoading ? null : _send,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7CB827),
                  foregroundColor: const Color(0xFF0D1116),
                  disabledBackgroundColor: const Color(0xFF3A4450),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: chat.isLoading
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _mut),
                      )
                    : const Icon(Icons.send, size: 15),
              ),
            ),
          ],
        ),
    );
  }

  OutlineInputBorder _border(Color color) => OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide(color: color),
      );

  Widget _iconButton(
    IconData icon,
    String tooltip,
    VoidCallback? onTap, {
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 17),
        color: active ? _lime : _mut,
        disabledColor: const Color(0xFF4B545E),
        splashRadius: 17,
        constraints: const BoxConstraints.tightFor(width: 31, height: 31),
        padding: EdgeInsets.zero,
        onPressed: onTap,
      ),
    );
  }

  // ---------- ☰ パネル ----------

  Widget _buildMenu() {
    final chat = context.watch<ChatProvider>();

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _sectionLabel('会話'),
        if (chat.isLoadingThreads)
          const Padding(
            padding: EdgeInsets.all(14),
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: _mut),
              ),
            ),
          )
        else if (chat.threadError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              chat.threadError!,
              style: const TextStyle(color: Color(0xFFE06C6C), fontSize: 12),
            ),
          )
        else
          ...chat.threads.map((t) => _threadRow(
                t.threadId,
                t.title,
                isCurrent: t.threadId == chat.currentThreadId,
              )),
        _menuRow(Icons.add, '新しい会話', () {
          context.read<ChatProvider>().startNewThread();
          _setMode(_PanelMode.none);
        }, color: _lime),
        const Divider(color: _line, height: 13),
        _menuRow(Icons.history, '会話ログを見る', () => _setMode(_PanelMode.log)),
        _menuRow(Icons.close, '入力欄を閉じる', _closeWindow),
        const Divider(color: _line, height: 13),
        _sectionLabel('アプリ'),
        _buildServerRow(),
        _menuRow(Icons.settings_outlined, '設定', () {
          RaimLog.d('[WindowsInputWindow] 設定が押されました');
        }),
        _menuRow(Icons.record_voice_over, 'クレジット表記',
            () => _setMode(_PanelMode.credits)),
        _menuRow(Icons.logout_rounded, 'ログアウト', _logout),
        _menuRow(Icons.power_settings_new, '終了', _quit),
      ],
    );
  }

  Widget _threadRow(String id, String title, {required bool isCurrent}) {
    if (_confirmingDeleteId == id) {
      // Overlay を使わず、行そのものを確認表示に差し替える
      return Container(
        color: _bg2,
        padding: const EdgeInsets.fromLTRB(14, 2, 8, 2),
        child: Row(
          children: [
            const Expanded(
              child: Text('この会話を削除しますか？',
                  style: TextStyle(color: _text, fontSize: 12.5)),
            ),
            TextButton(
              onPressed: () => setState(() => _confirmingDeleteId = null),
              child: const Text('やめる',
                  style: TextStyle(color: _mut, fontSize: 12)),
            ),
            TextButton(
              onPressed: () {
                context.read<ChatProvider>().deleteThread(id);
                setState(() => _confirmingDeleteId = null);
              },
              child: const Text('削除',
                  style: TextStyle(color: Color(0xFFE06C6C), fontSize: 12)),
            ),
          ],
        ),
      );
    }

    return InkWell(
      onTap: () {
        context.read<ChatProvider>().switchThread(id);
        _setMode(_PanelMode.none);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(
              isCurrent ? Icons.chat_bubble : Icons.chevron_right,
              size: 14,
              color: isCurrent ? _lime : _mut,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title.isEmpty ? '(無題)' : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isCurrent ? _lime : _text,
                  fontSize: 13,
                ),
              ),
            ),
            InkWell(
              onTap: () => setState(() => _confirmingDeleteId = id),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                child: Icon(Icons.more_horiz, size: 15, color: _mut),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ログアウトしてログイン画面へ戻す。
  ///
  /// `logoutForExit()` はトークンを消すだけで notifyListeners を呼ばないため
  /// 画面が変わらない。`logout()` の方は AuthStatus を unauthenticated にして
  /// 通知するので、SplashScreen の Consumer が LoginScreen へ切り替えてくれる。
  ///
  /// 入力小窓は枠なしで小さく、隠れていることもあるので、
  /// 先に通常ウィンドウへ戻してからログイン画面を出す。
  /// Unity はそのまま残す（再ログイン後もそのまま使える）。
  Future<void> _logout() async {
    final auth = context.read<AuthProvider>();
    final raimService = context.read<RaimServerService>();

    await _closeWindow();

    // 古いトークンで繋いだままにしない。
    // 切断待ちで止まる方が困るので短いタイムアウトを設ける。
    try {
      await raimService.disconnect().timeout(const Duration(seconds: 1));
    } catch (e) {
      RaimLog.d('[WindowsInputWindow] WebSocket切断待ちをスキップ: $e');
    }

    await _mascot.exitMascotMode();

    await auth.logout();
  }

  // ---------- クレジット ----------

  Widget _buildCredits() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _sectionLabel('クレジット表記')),
            IconButton(
              icon: const Icon(Icons.close, size: 15),
              color: _mut,
              splashRadius: 15,
              onPressed: () => _setMode(_PanelMode.menu),
            ),
          ],
        ),
        const Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // クレジット表記を増やしたい場合はここに追加
                Text('音声合成',
                    style: TextStyle(
                        color: _text,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
                SizedBox(height: 5),
                Text('・VOICEVOX: 春日部つむぎ',
                    style: TextStyle(color: _mut, fontSize: 12.5)),
                Divider(height: 22, color: _line),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 接続先切り替え（開発検証用）。現在の接続先を副題に出す。
  Widget _buildServerRow() {
    final url = context.watch<RaimServerService>().serverUrl;
    final isAws = RaimConfig.isAwsUrl(url);
    final accent = isAws ? _lime : Colors.orangeAccent;

    return InkWell(
      onTap: _isSwitching ? null : _switchServer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Row(
          children: [
            Icon(Icons.swap_horiz_rounded, size: 16, color: accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('接続先切り替え',
                      style: TextStyle(color: _text, fontSize: 13)),
                  Text(
                    _switchNote ??
                        (isAws ? '現在: AWS (CloudFront)' : '現在: Tailscale / Local'),
                    style: TextStyle(
                      color: accent,
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            if (_isSwitching)
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2, color: _mut),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 5),
        child: Text(
          text,
          style: const TextStyle(color: _mut, fontSize: 10.5, letterSpacing: 1),
        ),
      );

  Widget _menuRow(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color color = _text,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color == _text ? _mut : color),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: color, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  // ---------- 会話ログ ----------

  Widget _buildLog() {
    final messages = context.watch<ChatProvider>().messages;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _sectionLabel('会話ログ')),
            IconButton(
              icon: const Icon(Icons.close, size: 15),
              color: _mut,
              splashRadius: 15,
              onPressed: () => _setMode(_PanelMode.none),
            ),
          ],
        ),
        Expanded(
          child: messages.isEmpty
              ? const Center(
                  child: Text('まだ会話がありません',
                      style: TextStyle(color: _mut, fontSize: 12.5)),
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  itemCount: messages.length,
                  itemBuilder: (_, i) {
                    final m = messages[messages.length - 1 - i];
                    final isUser = m.role == MessageRole.user;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Align(
                        alignment: isUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 300),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: isUser ? const Color(0xFF2E4A1E) : _bg2,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            m.text,
                            style: const TextStyle(color: _text, fontSize: 12.5),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 選択中の画像を入力バーの上に並べる。
///
/// 画像があるときだけ高さを取るので、ウィンドウのリサイズは不要。
/// 入力バーの上に重なる形で伸びる。
class _SelectedImageStrip extends StatelessWidget {
  const _SelectedImageStrip();

  @override
  Widget build(BuildContext context) {
    final camera = context.watch<CameraProvider>();
    final paths = camera.selectedImagePaths;

    if (paths.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: MascotWindowService.imageStripHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        itemCount: paths.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(
                  File(paths[i]),
                  width: 42,
                  height: 42,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                top: -4,
                right: -4,
                child: IconButton(
                  icon: const Icon(Icons.cancel, size: 14),
                  color: Colors.white70,
                  splashRadius: 11,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 20, height: 20),
                  onPressed: () =>
                      context.read<CameraProvider>().removeImageAt(i),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}