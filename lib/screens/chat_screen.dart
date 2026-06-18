import 'dart:io' show Platform;
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_embed_unity/flutter_embed_unity.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/camera_provider.dart';
import 'package:raim_prototype/widgets/character_display.dart';
import 'package:raim_prototype/widgets/message_list.dart';
import 'package:raim_prototype/widgets/chat_input.dart';
import 'package:raim_prototype/services/camera_service.dart';
import 'package:image_picker/image_picker.dart'; 

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
        /// EmbedUnity方式は変更せず、UIボタンだけを重ねる。
    final size = MediaQuery.of(context).size;
    
    if (_isMobile) {
      // モバイル: Unity 埋め込み
      return Positioned(
        left: 0,
        right: 0,
        top: 0,
        bottom: 0,
        child: const EmbedUnity(
          onMessageFromUnity: _handleUnityMessage,
        ),
      );
    } else {
      // Windows: CharacterDisplay の位置を調整する
      return Positioned.fill(
        child: Transform.translate(
          offset: const Offset(-120, 0),
          child: const CharacterDisplay(),
        ),
      );
    }
  }

   
    /// 参考UI風の上部ヘッダー
    ///
    /// EmbedUnity方式は変更せず、FlutterのUIとして上に重ねる。
  Widget _buildReferenceTopBar(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;

    return Positioned(
      top: safeTop + 60,//上部三つのボタンの位置を変える
      left: 24,
      right: 24,
      child: Row(
        children: [
          _glassMenuButton(context),
          const SizedBox(width: 12),

          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
                child: Material(
                  // CAPTUREボタンと同じように Material の中に InkWell を入れる。
                color: Colors.transparent,
                child: InkWell(
                splashColor: Colors.white.withValues(alpha: 0.18),
                highlightColor: Colors.white.withValues(alpha: 0.10),
                onTap: () {
                // 新しい会話ボタンが押された時の処理。
                // 今は画面遷移せず、押されたことだけを確認する。
                  debugPrint('[ChatScreen] 新しい会話ボタンが押されました');
                },
                child: Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF172433).withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                    color: const Color(0xFFD6ECFF).withValues(alpha: 0.18),
                      width: 1,
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.chat_bubble_outline_rounded,
                        color: Colors.white70,
                        size: 18,
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '新しい会話',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: Colors.white70,
                        size: 22,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(width: 12),

          ClipRRect(
  borderRadius: BorderRadius.circular(18),
  child: BackdropFilter(
    filter: ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
    child: Material(
      // 音量ボタンと同じ仕組みにして、CAPTUREボタンにもタップ反応を出す。
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        splashColor: Colors.white.withValues(alpha: 0.18),
        highlightColor: Colors.white.withValues(alpha: 0.10),
        onTap: () {
          // ★ ここを書き換え：直接ギャラリーを開くのではなく、選択ボトムシートを起動
          _showImageSourceSelector(context);
        },
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF172433).withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: const Color(0xFFD6ECFF).withValues(alpha: 0.18),
              width: 1,
            ),
          ),
          child: const Row(
            children: [
              Icon(
                Icons.camera_alt_rounded,
                color: Colors.white,
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                'CAPTURE',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 💡 追加：カメラ・ギャラリーの選択ボトムシート
  void _showImageSourceSelector(BuildContext context) {
    showModalBottomSheet(
      context: context,
      // 背景を少し暗くしつつ、上の角を丸くする
      backgroundColor: const Color(0xFF1A1A2E), 
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext bc) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 10),
                child: Text(
                  '画像の追加方法を選択',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_rounded, color: Colors.white70),
                title: const Text('カメラで撮影', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.of(bc).pop(); // シートを閉じる
                  final provider = Provider.of<CameraProvider>(context, listen: false);
                  await provider.pickAndStoreImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_rounded, color: Colors.white70),
                title: const Text('ギャラリーから選択', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.of(bc).pop(); // シートを閉じる
                  final provider = Provider.of<CameraProvider>(context, listen: false);
                  await provider.pickAndStoreImage(ImageSource.gallery);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

Widget _glassMenuButton(BuildContext context) {  // ハンバーガーメニュー
  return PopupMenuButton<String>(
    tooltip: 'メニュー',
    color: Colors.black.withValues(alpha: 0.88),
    offset: const Offset(0, 56),

    onOpened: () {
    // ハンバーガーメニューを開いた時点で入力欄のフォーカスを外す。
    // メニュー表示中に入力欄が反応しないようにする。
    FocusManager.instance.primaryFocus?.unfocus();
    },

    onCanceled: () {
    // 設定を押さず、何もない空間を押してメニューを閉じた時の処理。
    // 入力欄にカーソルやキーボードが戻らないようにする。
    FocusManager.instance.primaryFocus?.unfocus();
    },

    onSelected: (value) {
      // 設定メニューを押したあと、入力欄にフォーカスが戻らないようにする。
      // これでキーボードやカーソルが入力欄へ移動するのを防ぐ。
      FocusManager.instance.primaryFocus?.unfocus();
      if (value == 'settings') {
        // 今は設定画面を開かず、押されたことだけを確認して終わる。
        debugPrint('[ChatScreen] 設定が押されました');
      }
    },
    itemBuilder: (context) => const [ //設定変更
      PopupMenuItem(
        value: 'settings',
        child: Row(
          children: [
            Icon(Icons.settings_rounded, color: Colors.white70),
            SizedBox(width: 12),
            Text('設定', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    ],
    child: _glassSmallButtonVisual(icon: Icons.menu_rounded),
  );
}

  Widget _glassSmallButtonVisual({
    required IconData icon,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 1.4, sigmaY: 1.4),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF172433).withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: const Color(0xFFD6ECFF).withValues(alpha: 0.18),
              width: 1,
            ),
          ),
          child: Icon(
            icon,
            color: Colors.white.withValues(alpha: 0.82),
            size: 24,
          ),
        ),
      ),
    );
  }

  /// 下部の丸い操作ボタン
  ///
  /// 設定・音量・マイクを表示する。
  // 音量ボタンは画面右上寄りに固定する。
  // bottom を指定するとキーボード表示時に位置がずれるため、top と right のみ使う。
  Widget _buildVolumeButton(BuildContext context) {
  final safeTop = MediaQuery.of(context).padding.top;

  return Positioned(
    top: safeTop + 125,
    right: 36,
    child: _glassLargeButton(
      icon: Icons.volume_up_rounded,
      onTap: () {
        debugPrint('[ChatScreen] 音量ボタンが押されました');
      },
    ),
  );
}

  /// 少し大きいガラス風ボタン
  Widget _glassLargeButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 1.6, sigmaY: 1.6),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: onTap,
            child: Container(
              width: 64,
              height: 54,
              decoration: BoxDecoration(
                color: const Color(0xFF2C475F).withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFFB7F35A).withValues(alpha: 0.58),
                  width: 1.2,
                ),
                boxShadow: [
                BoxShadow(
                  color: const Color(0xFFB7F35A).withValues(alpha: 0.16),
                  blurRadius: 14,
                  spreadRadius: 1,
                ),
              ],
              ),
              child: Icon(
                icon,
                color: Colors.white.withValues(alpha: 0.88),
                size: 28,
              ),
            ),
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
            padding: EdgeInsets.only(
              bottom: safeBottom,
              top: 20,
            ),
            // 入力欄の外側をタップしたらフォーカスを外し、キーボードを閉じる。
            // 入力欄タップ直後の誤反応を避けるため、画面全体の GestureDetector ではなく TapRegion を使う。
            child: TapRegion(
              onTapOutside: (_) {
                FocusManager.instance.primaryFocus?.unfocus();
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  //選択された画像があれば、入力欄の上にプレビューを表示
                  Consumer<CameraProvider>(
                    builder: (context, provider, child) {
                      if (!provider.hasImage) return const SizedBox.shrink();

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12, left: 24, right: 24),
                        child: SizedBox(
                          height: 76, // 枠線やバツボタンが見切れないよう少し高さを確保
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal, // 横スクロール
                            itemCount: provider.selectedImagePaths.length,
                            itemBuilder: (context, index) {
                              final imagePath = provider.selectedImagePaths[index];
                              
                              return Padding(
                                padding: const EdgeInsets.only(right: 12, top: 6), // 画像同士の間隔
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    // ガラス風の枠線で囲まれた画像のプレビュー
                                    Container(
                                      width: 70,
                                      height: 70,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: Colors.white30, width: 1.5),
                                        image: DecorationImage(
                                          image: FileImage(File(imagePath)),
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      top: -6,
                                      right: -6,
                                      child: GestureDetector(
                                        // 全体のクリアから、このインデックス（index）の画像だけを消す処理
                                        onTap: () => provider.removeImageAt(index),
                                        child: Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: const BoxDecoration(
                                            color: Colors.black87,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(Icons.close, color: Colors.white, size: 14),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
                  //既存の入力値
                  const ChatInput(),
                ],
              ),
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
// 赤線で指定した位置に合わせて、ボタンを個別に配置する
// ====================================================
Widget _buildWideControlBar(BuildContext context) {
  final safeTop = MediaQuery.of(context).padding.top;

  return Stack(
    children: [
      // 左側にメニューボタンを配置
      Positioned(
        top: safeTop + 20,
        left: 130,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xFFB7F35A).withValues(alpha: 0.42),
              width: 2,
            ),
          ),
          child: FittedBox(
            fit: BoxFit.contain,
            child: _glassMenuButton(context),
          ),
        ),
      ),

      // 右上に「新しい会話」ボタンを配置
      Positioned(
        top: safeTop + 30,
        right: 100,
        child: _wideGlassButton(
          width: 390,
          onTap: () {
            debugPrint('[ChatScreen] 新しい会話ボタンが押されました');
          },
          child: const Row(
            children: [
              Icon(Icons.chat_bubble_outline_rounded, color: Colors.white, size: 20),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  '新しい会話',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70, size: 24),
            ],
          ),
        ),
      ),

      // 左下に CAPTURE ボタンを配置
      Positioned(
        bottom: 10,
        height: 50,
        right: 520,
        child: _wideGlassButton(
          width: 150,
          onTap: () {
            _showImageSourceSelector(context);
          },
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.camera_alt_rounded, color: Colors.white, size: 20),
              SizedBox(width: 10),
              Text(
                'CAPTURE',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),

      // 右上端に音量ボタンを配置
      Positioned(
        top: safeTop + 30,
        right: 32,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            splashColor: const Color(0xFFB7F35A).withValues(alpha: 0.18),
            onTap: () {
              debugPrint('[ChatScreen] 音量ボタンが押されました');
            },
            child: Container(
              width: 52,
              height: 47,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF2C475F).withValues(alpha: 0.72),
                border: Border.all(
                  color: const Color(0xFFB7F35A).withValues(alpha: 0.42),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFB7F35A).withValues(alpha: 0.12),
                    blurRadius: 14,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: const Icon(
                Icons.volume_up_rounded,
                color: Colors.white,
                size: 28,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

// PC・全画面用の横長ボタンの見た目をまとめる
Widget _wideGlassButton({
  required double width,
  required VoidCallback onTap,
  required Widget child,
}) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 1.6, sigmaY: 1.6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          splashColor: const Color(0xFFB7F35A).withValues(alpha: 0.18),
          highlightColor: Colors.white.withValues(alpha: 0.08),
          onTap: onTap,
          child: Container(
            width: width,
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF2C475F).withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: const Color(0xFFB7F35A).withValues(alpha: 0.42),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFB7F35A).withValues(alpha: 0.12),
                  blurRadius: 14,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: child,
          ),
        ),
      ),
    ),
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
  
  double screenWidthRatio(BuildContext context, double ratio) {
    final width = MediaQuery.of(context).size.width * ratio;
    return width.clamp(300.0, 500.0);  
  }
}