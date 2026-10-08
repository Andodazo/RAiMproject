//画面にUIの配置や位置調整
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_embed_unity/flutter_embed_unity.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/auth_provider.dart';
import 'package:raim_prototype/providers/voice_controller.dart';
import 'package:raim_prototype/services/app_exit_service.dart';
import 'package:raim_prototype/services/raim_server_service.dart';
import 'package:raim_prototype/widgets/message_list.dart';
import 'package:raim_prototype/widgets/chat_input.dart';
import 'package:raim_prototype/widgets/client_action_listener.dart';
import 'package:raim_prototype/widgets/raim_calling_overlay.dart';
import 'package:raim_prototype/widgets/thread_selector_menu.dart';
import 'package:raim_prototype/widgets/voice_settings_panel.dart';
import 'package:raim_prototype/providers/station_alarm_controller.dart';
import 'package:raim_prototype/screens/station_alarm_screen.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/unity_communicator.dart';
import 'package:raim_prototype/services/unity_ready_signal.dart';

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  // ====================================================
  // プラットフォーム判定
  // ====================================================
  // モバイル(iOS/Android)では Unity を埋め込み、
  // Windows では Flutter の Image.asset で立ち絵表示する。
  bool get _isMobile {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (e) {
      // Web 等で Platform が使えない場合
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isWideScreen = screenSize.width >= 600;

    // ライムに頼まれた操作（「新宿で起こして」→ 駅アラーム）を実行する
    return ClientActionListener(
      child: Scaffold(
        // キーボード表示時に画面全体が縮むのを防ぐ。
        // キャラクター表示や背景のサイズを固定したままにするため false にする。
        resizeToAvoidBottomInset: false,
        backgroundColor: const Color(0xFF1a1a2e),
        body: _ChatVisibilityReporter(
          enabled: _isMobile,
          child: isWideScreen
              ? _buildWideLayout(context)
              : _buildNarrowLayout(context),
        ),
      ),
    );
  }

  // ====================================================
  // 共通レイヤー
  // ====================================================

  /// Layer 1: 背景画像(一番下)
  Widget _buildBackground() {
    return Positioned.fill(
      child: Image.asset('assets/images/background.png', fit: BoxFit.cover),
    );
  }

  /// Layer 1.5: 背景に黒の半透明オーバーレイ
  ///
  /// Q1.A の方針: 背景の直後に置く(キャラクター表示の手前ではない)
  /// → キャラクターはくっきり、背景は夜の雰囲気で暗く
  Widget _buildBackgroundOverlay() {
    return Positioned.fill(
      child: Container(color: Colors.black.withValues(alpha: 0.3)),
    );
  }

  /// Layer 2: キャラクター層(プラットフォーム分岐)
  ///
  /// - モバイル: EmbedUnity(Unity 3D シーン埋め込み)
  /// - Windows: CharacterDisplay(Image.asset で立ち絵)
  ///
  /// Q3.C の方針: 下寄せ・縦長で配置、頭が見切れないよう上に余白
  Widget _buildCharacterLayer(BuildContext context) {
    if (_isMobile) {
      return Positioned.fill(
        child: const EmbedUnity(onMessageFromUnity: _handleUnityMessage),
      );
    }
    // Windows: Unity 側が描画するので何も置かない
    return const SizedBox.shrink();
  }

  /// Layer 2.5: Unity の準備ができるまで、ライムに電話をかけているような画面を重ねる
  ///
  /// Windows は Unity が別ウィンドウなので出さない。
  Widget _buildCallingOverlay() {
    if (!_isMobile) return const SizedBox.shrink();
    return const Positioned.fill(child: RaimCallingOverlay());
  }


  /// Unity からのメッセージハンドラ
  ///
  /// 今届くのは、Unity の準備ができたという合図（unity.ready）だけ。
  static void _handleUnityMessage(String message) {
    RaimLog.d('[ChatScreen] Unity から受信 ${RaimLog.size(message)}');
    UnityReadySignal.handleMessage(message);
  }

  /// 参考UI風の上部ヘッダー
  ///
  /// FlutterのUIとして上に重ねる。
  Widget _buildReferenceTopBar(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    final bar = Row(
      children: [
        ChatMenuButton(
          onSettings: () => showVoiceSettingsSheet(context),
          onStationAlarm: StationAlarmController.isSupported
              ? () => StationAlarmScreen.open(context)
              : null,
          onLogout: () {
            _confirmLogoutAndClose(context);
          },
        ),
        const SizedBox(width: 12),
        //新しい会話ボタン
        Expanded(
          child: ChatNewConversationButton(
            onTap: (buttonContext) => showThreadMenu(buttonContext),
          ),
        ),
        const SizedBox(width: 12),
        // 音量ボタン（ライムの声を消す / 出す）。
        // 以前ここにあった CAPTURE は入力欄の左に移した
        const ChatVolumeButton(),
      ],
    );

    //ハンバーガーメニュー
    return Positioned(
      top: safeTop + 60, //上部三つのボタンの位置を変える
      left: 24,
      right: 24,
      // スマホでは、このバーのすぐ下にライムの頭が来るよう Unity へ伝える
      child: _isMobile ? _HeadLayoutReporter(child: bar) : bar,
    );
  }

  // ====================================================
  // スマホ・縦長レイアウト(参考UI 風)
  // ====================================================
  //
  //
  // - キャラを全画面で見せる
  // - メッセージは画面中央〜下に透明背景でオーバーレイ
  // - 入力欄は最下部、半透明グラデーション
  Widget _buildNarrowLayout(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final safeTop = mediaQuery.padding.top;
    final safeBottom = mediaQuery.padding.bottom;
    // キーボードの高さを取得する。
    // キーボード非表示時は 0、表示時はキーボード分の高さになる。
    final keyboardBottom = mediaQuery.viewInsets.bottom;

    return Stack(
      children: [
        // ====================================================
        // Layer 1: 背景画像
        // ====================================================
        _buildBackground(),

        // Layer 1.5: 背景オーバーレイ(Q1.A: 背景の直後)
        _buildBackgroundOverlay(),

        // ====================================================
        // Layer 2: キャラクター(Unity または立ち絵)
        // ====================================================
        _buildCharacterLayer(context),

        // Layer 2.5: Unity の準備ができるまでの「発信中」の画面（スマホのみ）
        _buildCallingOverlay(),

        // ====================================================
        // Layer 3: UI オーバーレイ
        // ====================================================

        // 上部タイトル
        Positioned(
          top: safeTop,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Image.asset(
              'assets/images/RAiM_logo_white.png',
              width: 100, // ★横幅を指定
              height: 40, // ★高さを指定
              fit: BoxFit.contain, // ★アスペクト比（縦横比）の保ち方を指定
            ),
          ),
        ),

        // メッセージリスト(中央〜下、透明背景)
        // 入力欄に被らないよう bottom に余白を確保
        Positioned(
          left: 0,
          right: 0,
          top: mediaQuery.size.height * 0.45, // 画面中央あたりから
          bottom: 90 + safeBottom, // 入力欄の高さぶん上に
          child: ShaderMask(
            // 上部をフェードアウト(キャラに自然に重なる効果)
            shaderCallback: (Rect bounds) {
              return const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black, Colors.black],
                stops: [0.0, 0.2, 1.0],
              ).createShader(bounds);
            },
            blendMode: BlendMode.dstIn,
            child: const MessageList(),
          ),
        ),

        // 入力欄(最下部、半透明グラデーション)
        Positioned(
          bottom: keyboardBottom,
          left: 0,
          right: 0,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.0),
                  Colors.black.withValues(alpha: 0.16),
                  Colors.black.withValues(alpha: 0.28),
                ],
                stops: const [0.0, 0.4, 1.0],
              ),
            ),
            padding: EdgeInsets.only(bottom: safeBottom, top: 20),
            // 入力欄の外側をタップしたらフォーカスを外し、キーボードを閉じる。
            // 入力欄タップ直後の誤反応を避けるため、画面全体の GestureDetector ではなく TapRegion を使う。
            child: TapRegion(
              onTapOutside: (_) {
                FocusManager.instance.primaryFocus?.unfocus();
              },
              child: const ChatInput(),
            ),
          ),
        ),

        // 参考UI風の上部ヘッダー（メニュー・新しい会話・音量）
        _buildReferenceTopBar(context),
      ],
    );
  }

  // ====================================================
  // PC・全画面用 操作ボタン
  // ====================================================
  Widget _buildWideControlBar(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;

    return Stack(
      children: [
        // メニューボタン
        Positioned(
          top: safeTop + 20,
          left: 130,
          child: ChatMenuButton(
            isWide: true,
            onSettings: () => showVoiceSettingsSheet(context),
            onStationAlarm: StationAlarmController.isSupported
                ? () => StationAlarmScreen.open(context)
                : null,
            onLogout: () {
              _confirmLogoutAndClose(context);
            },
          ),
        ),

        // 新しい会話ボタン
        Positioned(
          top: safeTop + 30,
          right: 100,
          child: ChatNewConversationButton(
            isWide: true,
            onTap: (buttonContext) => showThreadMenu(buttonContext),
          ),
        ),

        // 画像の添付は入力欄の左のボタンから（ChatInput に含まれる）

        // 音量ボタン
        Positioned(
          top: safeTop + 30,
          right: 32,
          child: const ChatVolumeButton(isWide: true),
        ),
      ],
    );
  }

  // ====================================================
  // PC・横長レイアウト(現状維持 + プラットフォーム分岐対応)
  // PC画面全体の配置を決める処理
  // ====================================================
  Widget _buildWideLayout(BuildContext context) {
    return Stack(
      children: [
        _buildBackground(),
        _buildBackgroundOverlay(),
        _buildCharacterLayer(context),
        _buildCallingOverlay(),

        // 左上タイトル
        Positioned(
          top: 20,
          left: 30,
          child: Image.asset(
            'assets/images/RAiM_logo_white.png',
            width: 100, // ★横幅を指定
            height: 40, // ★高さを指定
            fit: BoxFit.contain, // ★アスペクト比（縦横比）の保ち方を指定
          ),
        ),

        // 右サイドチャットパネル
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: screenWidthRatio(context, 0.4),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              border: Border(
                left: BorderSide(
                  color: Colors.white.withValues(alpha: 0.2),
                  width: 1,
                ),
              ),
            ),
            child: Column(
              children: [
                SizedBox(height: MediaQuery.of(context).padding.top + 100),
                const Expanded(child: MessageList()),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    border: Border(
                      top: BorderSide(
                        color: Colors.white.withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                  ),
                  child: const ChatInput(),
                ),
              ],
            ),
          ),
        ),

        // PC・全画面でも音量ボタンを表示する
        _buildWideControlBar(context),
      ],
    );
  }

  //チャットパネルの横幅計算
  double screenWidthRatio(BuildContext context, double ratio) {
    final width = MediaQuery.of(context).size.width * ratio;
    return width.clamp(300.0, 500.0);
  }

  /// ハンバーガーメニューの「ログアウトして終了」から呼ばれる処理。
  ///
  /// この検証アプリは起動時に必ず認証状態を確認するため、ログアウト後に同じ画面内で
  /// LoginScreenへ戻すよりも、保存済みTokenを消してアプリを閉じる方が動作説明しやすい。
  Future<void> _confirmLogoutAndClose(BuildContext context) async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF172433),
          title: const Text(
            'ログアウトしますか？',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            '保存済みの認証情報を削除して、RAiMアプリを終了します。'
            '次回起動時はCognito認証から開始します。',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('ログアウトして終了'),
            ),
          ],
        );
      },
    );

    if (shouldLogout != true || !context.mounted) return;

    final raimService = context.read<RaimServerService>();
    final authProvider = context.read<AuthProvider>();

    try {
      // Access Token / Refresh Token を削除する。次回起動時は未認証として扱われる。
      await authProvider.logoutForExit();
    } finally {
      // 通信を残したままアプリを閉じないように WebSocket も閉じる。
      // ただし終了操作では「切断完了待ち」でアプリ終了が止まる方が困るため、
      // 短いタイムアウトを設け、失敗しても終了処理へ進む。
      try {
        await raimService.disconnect().timeout(const Duration(seconds: 1));
      } catch (error) {
        RaimLog.d('[ChatScreen] WebSocket切断待ちをスキップ: $error');
      }
      await AppExitService.exitAfterLogout();
      // ここへ戻ってきたということは、アプリを終了できなかった
      // （iOS 実機など）。トークンは消えているので、画面も未認証へ戻す。
      authProvider.notifyLogoutFallback();
    }
  }
}

/// 上部のバーの下端を測り、ライムの頭をその少し下に置くよう Unity へ伝える（スマホのみ）。
///
/// 以前はライムの大きさが部屋の中で固定（身長 1.65m 相当）で、スマホでは
/// バーとの間が大きく空き、ライムが小さく見えていた。
/// バーの位置は端末（ノッチの有無・画面の高さ）で変わるので、ピクセルではなく
/// 画面の高さに対する割合で送る。Unity は縦の画角が固定なので、割合で合わせれば
/// どの端末でも同じ見え方になる。
class _HeadLayoutReporter extends StatefulWidget {
  const _HeadLayoutReporter({required this.child});

  final Widget child;

  @override
  State<_HeadLayoutReporter> createState() => _HeadLayoutReporterState();
}

class _HeadLayoutReporterState extends State<_HeadLayoutReporter> {
  /// バーとライムの頭の間の隙間（論理ピクセル）
  static const double gap = 12;

  /// Unity は起動に数秒かかり、読み込み前に送ったメッセージは届かない。
  /// 起動直後は間を置いて何度か送る（Unity 側は同じ値なら何度受け取っても同じ）。
  static const List<Duration> _retries = [
    Duration(milliseconds: 300),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];

  final GlobalKey _key = GlobalKey();
  final List<Timer> _timers = [];
  double? _lastSent;

  @override
  void initState() {
    super.initState();
    for (final delay in _retries) {
      _timers.add(Timer(delay, () => _report(force: true)));
    }
    // Unity の準備ができたらすぐ送る。「発信中」の画面が消える前に大きさを合わせておく
    UnityReadySignal.ready.addListener(_onUnityReady);
  }

  void _onUnityReady() {
    if (UnityReadySignal.ready.value) _report(force: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 画面の大きさ（回転・分割表示など）が変わったら測り直す
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  @override
  void dispose() {
    UnityReadySignal.ready.removeListener(_onUnityReady);
    for (final timer in _timers) {
      timer.cancel();
    }
    super.dispose();
  }

  void _report({bool force = false}) {
    if (!mounted) return;
    final box = _key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;

    final screenHeight = MediaQuery.sizeOf(context).height;
    if (screenHeight <= 0) return;

    final barBottom = box.localToGlobal(Offset(0, box.size.height)).dy;
    final headTop = ((barBottom + gap) / screenHeight).clamp(0.05, 0.6);

    if (!force &&
        _lastSent != null &&
        (headTop - _lastSent!).abs() < 0.002) {
      return;
    }
    _lastSent = headTop;
    context.read<UnityCommunicator>().sendLayout(headTop: headTop);
  }

  @override
  Widget build(BuildContext context) {
    // 画面の大きさが変わったときに didChangeDependencies が呼ばれるようにする
    MediaQuery.sizeOf(context);
    return KeyedSubtree(key: _key, child: widget.child);
  }
}

/// チャット画面が見えているかを VoiceController へ伝える（スマホのみ）。
///
/// 駅アラームの画面・設定・メニューなどが上に開いている間は「ねえライム」を止める。
/// 以前はどの画面にいても聞いていたので、会話の中の「ライム」に反応すると、
/// 見えていないチャットの入力欄に文が入ったり送られたりしていた。
///
/// Windows は入力小窓を閉じた状態で呼ぶのが本来の使い方なので対象外。
class _ChatVisibilityReporter extends StatefulWidget {
  const _ChatVisibilityReporter({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<_ChatVisibilityReporter> createState() =>
      _ChatVisibilityReporterState();
}

class _ChatVisibilityReporterState extends State<_ChatVisibilityReporter> {
  VoiceController? _voice;
  bool? _lastVisible;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _voice = context.read<VoiceController>();
  }

  @override
  void dispose() {
    // ログアウトなどでチャット画面が無くなるときは、止めたままにしない
    if (widget.enabled) _voice?.setChatVisible(true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.enabled) {
      // 上に別の画面（ボトムシート・ダイアログ・メニューも含む）が
      // 開くと isCurrent が false になり、ここが作り直される
      final visible = ModalRoute.of(context)?.isCurrent ?? true;
      if (visible != _lastVisible) {
        _lastVisible = visible;
        final voice = _voice;
        // build 中に通知を出さないよう、描き終わってから伝える
        WidgetsBinding.instance.addPostFrameCallback((_) {
          voice?.setChatVisible(visible);
        });
      }
    }
    return widget.child;
  }
}
