//画面にUIの配置や位置調整
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_embed_unity/flutter_embed_unity.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/auth_provider.dart';
import 'package:raim_prototype/services/app_exit_service.dart';
import 'package:raim_prototype/services/raim_server_service.dart';
import 'package:raim_prototype/widgets/message_list.dart';
import 'package:raim_prototype/widgets/chat_input.dart';
import 'package:raim_prototype/widgets/thread_selector_menu.dart';
import 'package:raim_prototype/services/raim_log.dart';

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

    return Scaffold(
      // キーボード表示時に画面全体が縮むのを防ぐ。
      // キャラクター表示や背景のサイズを固定したままにするため false にする。
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF1a1a2e),
      body: isWideScreen
          ? _buildWideLayout(context)
          : _buildNarrowLayout(context),
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
      child: Container(color: Colors.black.withOpacity(0.3)),
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


  /// Unity からのメッセージハンドラ
  ///
  /// 現状は Flutter → Unity の一方通行なので空実装。
  /// 将来 Unity 側でクリック検知やアニメ完了通知が必要になったらここで処理。
  static void _handleUnityMessage(String message) {
    RaimLog.d('[ChatScreen] Unity から受信 ${RaimLog.size(message)}');
  }

  /// 参考UI風の上部ヘッダー
  ///
  /// FlutterのUIとして上に重ねる。
  Widget _buildReferenceTopBar(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    //ハンバーガーメニュー
    return Positioned(
      top: safeTop + 60, //上部三つのボタンの位置を変える
      left: 24,
      right: 24,
      child: Row(
        children: [
          ChatMenuButton(
            onSettings: () {
              RaimLog.d('[ChatScreen] 設定が押されました');
            },
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
          //キャプチャーボタン
          ChatCaptureButton(
            onTap: () {
              showImageSourceSelector(context);
            },
          ),
        ],
      ),
    );
  }

  /// 下部の丸い操作ボタン
  /// 音量を表示する。
  // 音量ボタンは画面右上寄りに固定する。
  // bottom を指定するとキーボード表示時に位置がずれるため、top と right のみ使う。
  Widget _buildVolumeButton(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;

    return Positioned(
      top: safeTop + 125,
      right: 36,
      child: ChatVolumeButton(
        onTap: () {
          RaimLog.d('[ChatScreen] 音量ボタンが押されました');
        },
      ),
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
                  Colors.black.withOpacity(0.0),
                  Colors.black.withOpacity(0.16),
                  Colors.black.withOpacity(0.28),
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

        // 参考UI風の上部ヘッダー
        _buildReferenceTopBar(context),

        // 参考UI風の下部操作ボタン
        _buildVolumeButton(context),
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
            onSettings: () {
              RaimLog.d('[ChatScreen] 設定が押されました');
            },
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

        // CAPTUREボタン
        Positioned(
          bottom: 10,
          right: 520,
          child: ChatCaptureButton(
            isWide: true,
            onTap: () {
              showImageSourceSelector(context);
            },
          ),
        ),

        // 音量ボタン
        Positioned(
          top: safeTop + 30,
          right: 32,
          child: ChatVolumeButton(
            isWide: true,
            onTap: () {
              RaimLog.d('[ChatScreen] 音量ボタンが押されました');
            },
          ),
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
              color: Colors.black.withOpacity(0.5),
              border: Border(
                left: BorderSide(
                  color: Colors.white.withOpacity(0.2),
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
                    color: Colors.black.withOpacity(0.4),
                    border: Border(
                      top: BorderSide(
                        color: Colors.white.withOpacity(0.2),
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
    }
  }
}
