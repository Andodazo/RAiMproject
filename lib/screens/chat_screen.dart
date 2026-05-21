import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:raim_prototype/widgets/character_display.dart';
import 'package:raim_prototype/widgets/message_list.dart';
import 'package:raim_prototype/widgets/chat_input.dart';

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isWideScreen = screenSize.width >= 600;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: isWideScreen
          ? _buildWideLayout(context)
          : _buildNarrowLayout(context),
    );
  }

  // ====================================================
  // 共通レイヤー
  // ====================================================

  Widget _buildBackground() {
    return Positioned.fill(
      child: Image.asset(
        'assets/images/background.png',
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _buildBackgroundOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.3),
      ),
    );
  }

  Widget _buildCharacterLayer(BuildContext context) {
    return const Positioned.fill(
      child: CharacterDisplay(),
    );
  }

  /// カメラ・マイクボタン
  ///
  /// 右上に配置する。
  /// Stack内でMessageListより前に置くことで、メッセージの背面に配置する。
  Widget _buildGlassActionButtons(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;

    return Positioned(
      top: safeTop + 50,
      right: 12,
      child: IgnorePointer(
        // 今は内部処理なしなので、完全に背面UIとして扱う
        ignoring: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _glassButton(
              icon: Icons.camera_alt_rounded,
              onTap: () {
                // TODO: カメラ処理はまだ入れない
              },
            ),
            const SizedBox(width: 14),
            _glassButton(
              icon: Icons.mic_rounded,
              onTap: () {
                // TODO: 音声入力処理はまだ入れない
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _glassButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 1.2, sigmaY: 1.2),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withOpacity(0.16),
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Icon(
              icon,
              color: Colors.white.withOpacity(0.65),
              size: 34,
            ),
          ),
        ),
      ),
    );
  }

  // ====================================================
  // スマホ・縦長レイアウト
  // Androidはこちら
  // ====================================================
  Widget _buildNarrowLayout(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final safeTop = mediaQuery.padding.top;
    final safeBottom = mediaQuery.padding.bottom;

    return Stack(
      children: [
        // 背景
        _buildBackground(),

        // 背景を少し暗くする
        _buildBackgroundOverlay(),

        // キャラクター
        _buildCharacterLayer(context),

        // カメラ・音声入力ボタン
        // MessageListより前に置くことで、メッセージの背面になる
        _buildGlassActionButtons(context),

        // 上部タイトル
        Positioned(
          top: safeTop,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: const Text(
              'RAiM',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 3,
                shadows: [
                  Shadow(blurRadius: 12, color: Colors.black87),
                  Shadow(blurRadius: 4, color: Colors.black54),
                ],
              ),
            ),
          ),
        ),

        // メッセージリスト
        Positioned(
          left: 0,
          right: 0,
          top: mediaQuery.size.height * 0.45,
          bottom: 90 + safeBottom,
          child: ShaderMask(
            shaderCallback: (Rect bounds) {
              return const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black,
                  Colors.black,
                ],
                stops: [0.0, 0.2, 1.0],
              ).createShader(bounds);
            },
            blendMode: BlendMode.dstIn,
            child: const MessageList(),
          ),
        ),

        // 入力欄
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.0),
                  Colors.black.withOpacity(0.6),
                  Colors.black.withOpacity(0.8),
                ],
                stops: const [0.0, 0.4, 1.0],
              ),
            ),
            padding: EdgeInsets.only(
              bottom: safeBottom,
              top: 20,
            ),
            child: const ChatInput(),
          ),
        ),
      ],
    );
  }

  // ====================================================
  // PC・横長レイアウト
  // Windowsはこちら
  // ====================================================
  Widget _buildWideLayout(BuildContext context) {
    return Stack(
      children: [
        // 背景
        _buildBackground(),

        // 背景を少し暗くする
        _buildBackgroundOverlay(),

        // キャラクター
        _buildCharacterLayer(context),

        // カメラ・音声入力ボタン
        // チャットより前に書くことで、チャットの背面に配置する
        _buildGlassActionButtons(context),

        // 左上タイトル
        Positioned(
          top: 20,
          left: 30,
          child: Text(
            'RAiM',
            style: TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
              shadows: [
                Shadow(
                  blurRadius: 12,
                  color: Colors.black.withOpacity(0.8),
                ),
              ],
            ),
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
                SizedBox(height: MediaQuery.of(context).padding.top + 20),
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
      ],
    );
  }

  double screenWidthRatio(BuildContext context, double ratio) {
    final width = MediaQuery.of(context).size.width * ratio;
    return width.clamp(300.0, 500.0);
  }
}