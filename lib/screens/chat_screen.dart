import 'dart:io' show Platform;
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_embed_unity/flutter_embed_unity.dart';
import 'package:raim_prototype/widgets/character_display.dart';
import 'package:raim_prototype/widgets/message_list.dart';
import 'package:raim_prototype/widgets/chat_input.dart';

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});
  
  // ====================================================
  // プラットフォーム判定
  // ====================================================
  // モバイル(iOS/Android)では Unity を埋め込み、
  // Windows では Flutter の Image.asset で立ち絵表示する
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
      child: Image.asset(
        'assets/images/background.png',
        fit: BoxFit.cover,
      ),
    );
  }
  
  /// Layer 1.5: 背景に黒の半透明オーバーレイ
  /// 
  /// Q1.A の方針: 背景の直後に置く(Unity の手前ではない)
  /// → Unity のキャラクターはくっきり、背景は夜の雰囲気で暗く
  Widget _buildBackgroundOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.3),
      ),
    );
  }
  
  /// Layer 2: キャラクター層(プラットフォーム分岐)
  /// 
  /// - モバイル: EmbedUnity(Unity 3D シーン埋め込み)
  /// - Windows: CharacterDisplay(Image.asset で立ち絵)
  /// 
  /// Q3.C の方針: 下寄せ・縦長で配置、頭が見切れないよう上に余白
  Widget _buildCharacterLayer(BuildContext context) {
        /// ガラス風のカメラ・マイクボタン
        ///
        /// 内部処理はまだ入れない。
        /// EmbedUnity方式は変更せず、UIボタンだけを重ねる。
    final size = MediaQuery.of(context).size;
    
    if (_isMobile) {
      // モバイル: Unity 埋め込み
      // 画面の上 15% は余白(タイトル + 頭の上の空間)
      // 画面の下 85% を Unity 領域として使う
      return Positioned(
        left: 0,
        right: 0,
        top: size.height * 0.15,
        bottom: 0,
        child: const EmbedUnity(
          onMessageFromUnity: _handleUnityMessage,
        ),
      );
    } else {
      // Windows: 既存の CharacterDisplay(立ち絵画像)
      return const Positioned.fill(
        child: CharacterDisplay(),
      );
    }
  }

   Widget _buildGlassActionButtons(BuildContext context) {
          final safeTop = MediaQuery.of(context).padding.top;

          return Positioned(
            top: safeTop + 70,
            right: 24,
            child: IgnorePointer(
              ignoring: false,
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

          /// ガラス風ボタン本体
        Widget _glassButton({
  required IconData icon,
  required VoidCallback onTap,
}) {
  return Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: () {
        debugPrint('camera button tapped');
      // TODO: カメラ処理はまだ入れない
      },
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.18),
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Icon(
          icon,
          color: Colors.white.withValues(alpha: 0.75),
          size: 34,
        ),
      ),
    ),
  );
}
  
  /// Unity からのメッセージハンドラ
  /// 
  /// 現状は Flutter → Unity の一方通行なので空実装。
  /// 将来 Unity 側でクリック検知やアニメ完了通知が必要になったらここで処理。
  static void _handleUnityMessage(String message) {
    debugPrint('[ChatScreen] Unity から受信: $message');
  }
  
  // ====================================================
  // スマホ・縦長レイアウト(参考UI 風)
  // ====================================================
  // 
  // Q4 の方針: 参考UI(しずく)風
  // - キャラを全画面で見せる
  // - メッセージは画面中央〜下に透明背景でオーバーレイ
  // - 入力欄は最下部、半透明グラデーション
  Widget _buildNarrowLayout(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final safeTop = mediaQuery.padding.top;
    final safeBottom = mediaQuery.padding.bottom;
    
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

         // カメラ・音声入力ボタン
        _buildGlassActionButtons(context),
        
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
        
        // 入力欄(最下部、半透明グラデーション)
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
  // PC・横長レイアウト(現状維持 + プラットフォーム分岐対応)
  // ====================================================
  Widget _buildWideLayout(BuildContext context) {
    return Stack(
      children: [
        _buildBackground(),
        _buildBackgroundOverlay(),
        _buildCharacterLayer(context),
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
                color: Colors.black.withOpacity(0.8)),
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