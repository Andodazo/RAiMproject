//送信処理・画像添付状態の取得・送信後のリセット・ボタンのデザイン
import 'dart:io';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/providers/camera_provider.dart';
// 開発検証用
import 'package:raim_prototype/providers/auth_provider.dart';
import 'package:raim_prototype/services/raim_server_service.dart';

class ChatInput extends StatefulWidget {
  const ChatInput({super.key});
  
  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _controller = TextEditingController();
  // Windows版で Enter / Shift + Enter を判定するためのフォーカス管理
  final FocusNode _inputFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();

  // 入力欄にフォーカスがあるときのキー入力を監視する
    _inputFocusNode.onKeyEvent = _handleInputKeyEvent;
  }

  // Windows版のみ:
 // Shift + Enter は改行、Enterのみは送信にする
  KeyEventResult _handleInputKeyEvent(FocusNode node, KeyEvent event) {
    if (!Platform.isWindows || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;

    if (!isEnter) {
      return KeyEventResult.ignored;
    }

    // Shift + Enter の場合は TextField に任せて改行する
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }

    // Enterのみの場合は送信する
    _sendMessage();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    // 使い終わった FocusNode を破棄する
    _inputFocusNode.dispose();

    // 使い終わった TextEditingController を破棄する
    _controller.dispose();
    super.dispose();
  }
  
  void _sendMessage() {
    final text = _controller.text.trim();
    //CameraProviderの状態を取得
    final cameraProvider = context.read<CameraProvider>();
    final hasImage = cameraProvider.hasImage;
    // リスト型のゲッターをそのまま取得
    final imagePaths = cameraProvider.selectedImagePaths;
    final base64List = cameraProvider.selectedImagesBase64;
    //テキストも画像も両方空っぽなら何もせず終了
    if (text.isEmpty && !hasImage) return;

    //[検証用ログ]送信ボタンが押されたときのデータをログに出す
    debugPrint('[ChatInput]メッセージを送信します: text="$text", hasImage=$hasImage');
    if (hasImage && base64List != null) {
      debugPrint('[ChatInput]連動する画像パス: $imagePaths');
      // すべての画像のBase64の頭15文字をインデックス付きでログ出力
      for (int i = 0; i < base64List.length; i++) {
        final base64str = base64List[i];
        final preview = base64str.length > 15 ? '${base64str.substring(0, 15)}...' : base64str;
        debugPrint('[ChatInput] 画像[$i] Base64(部分): $preview');
      }
    }
    //クリアされる前に、現在の画像パスのコピーを作成しておく（安全のため）
    final pathsToSend = imagePaths != null ? List<String>.from(imagePaths) : null;
    // Base64 も同様にコピーする
    // sendUserMessage は async で、内部の最初の await で制御が戻る。
    // その隙に clearImage() が走るため、参照のまま渡すと空になる
    final base64ToSend = base64List != null ? List<String>.from(base64List) : null;
    // サーバーへ送信
    context.read<ChatProvider>().sendUserMessage(
      text,
      images: base64ToSend,
      filePaths: pathsToSend, //画面表示用のファイルパスをChatProviderに渡す
      );
    _controller.clear();
    cameraProvider.clearImage(); //キープされていた画像とプレビューをクリア
  }
  
  @override
  Widget build(BuildContext context) {
  return TapRegion(
    // 追加：入力欄の外を押したときにキーボードを閉じる
    onTapOutside: (_) {
      FocusManager.instance.primaryFocus?.unfocus();
    },

    // 追加：画像と入力欄を縦に並べる
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 追加：選択した画像を入力欄の上に表示
        const _SelectedImagePreview(),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  // Enterキーの処理を受け取るために FocusNode を設定する
                  focusNode: _inputFocusNode,
                  controller: _controller,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  minLines: 1,
                  maxLines: 4,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                  ),
                  cursorColor: Colors.white,
                  decoration: InputDecoration(
                    hintText: '何でも話してね',

                    // マイクボタン
                    suffixIcon: IconButton(
                      icon: const Icon(
                        Icons.mic_rounded,
                        color: Colors.white70,
                      ),
                      onPressed: () {
                        debugPrint(
                          '[ChatInput] 音声入力ボタンが押されました',
                        );
                      },
                    ),

                    hintStyle: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                    ),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.15),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(
                        color: Colors.white.withOpacity(0.3),
                        width: 1,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: const BorderSide(
                        color: Colors.white,
                        width: 1.5,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // 送信ボタン
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF8BC34A),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: IconButton(
                  icon: const Icon(
                    Icons.send,
                    color: Colors.white,
                  ),
                  onPressed: _sendMessage,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
}
//選択した画像を送信前にプレビュー表示し、不要な画像を削除
class _SelectedImagePreview extends StatelessWidget {
  const _SelectedImagePreview();

  @override
  Widget build(BuildContext context) {
    return Consumer<CameraProvider>(
      builder: (context, provider, child) {
        if (!provider.hasImage) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 6, 24, 6),
          child: SizedBox(
            height: 76,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: provider.selectedImagePaths.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final imagePath = provider.selectedImagePaths[index];

                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 70,
                        height: 70,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white30,
                            width: 1.5,
                          ),
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
                          onTap: () => provider.removeImageAt(index),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Colors.black87,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 14,
                            ),
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
    );
  }
}


/// ハンバーガーメニューボタン
//class ChatMenuButton extends StatelessWidget {
class ChatMenuButton extends StatefulWidget {//開発検証用
  const ChatMenuButton({
    super.key,
    required this.onSettings,
    required this.onLogout,
    this.isWide = false,
  });

  final VoidCallback onSettings;
  final VoidCallback onLogout;
  final bool isWide;
  //開発検証用---------------------------------------------------
  @override
  State<ChatMenuButton> createState() => _ChatMenuButtonState();
}
  class _ChatMenuButtonState extends State<ChatMenuButton> {
  bool _isSwitching = false;
  static const String awsUrl = 'wss://d1403ont6098ah.cloudfront.net/dev';
  static const String localUrl = 'ws://100.81.35.109:8080'; 
  //-----------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    // --現在の RaimServerService から接続先URLを取得(開発検証用)
    final raimService = context.read<RaimServerService>();
    final currentUrl = raimService.serverUrl;
    final isAws = currentUrl.contains('cloudfront.net');
    //--------------------------------------------------------
    return PopupMenuButton<String>(
      tooltip: 'メニュー',
      color: Colors.black.withValues(alpha: 0.88),
      offset: const Offset(0, 56),
      onOpened: _removeFocus,
      onCanceled: _removeFocus,
      onSelected: (value) async{ //asyncは開発検証を消すときに消す
        _removeFocus();

        switch (value) {
          //開発検証用------------------------------
          case 'switch_server':
            // すでに切り替え中ならタップを無視（ロック）
            if (_isSwitching) return;
            _isSwitching = true;

            try {
              final currentUrl = raimService.serverUrl;
              final isAws = currentUrl.contains('cloudfront.net');
              final targetUrl = isAws ? localUrl : awsUrl;
              // 古いポップアップを全て消去してから「切り替え中」を出す
              ScaffoldMessenger.of(context).clearSnackBars();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('サーバー切り替え中...'),
                  duration: Duration(seconds: 1),
                ),
              );

              final authProvider = context.read<AuthProvider>();
              final token = await authProvider.getValidAccessToken();

              // 実際の切り替え処理
              await raimService.switchServer(targetUrl, accessToken: token);

              if (context.mounted) {
                setState(() {});
                //古いポップアップを消去してから「完了通知」を出す
                ScaffoldMessenger.of(context).clearSnackBars();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(isAws ? 'Tailscale に切り替えました' : 'AWS に切り替えました'),
                  ),
                );
              }
            } finally {
              // 成功・失敗にかかわらず、処理が終わったら必ずロック解除
              _isSwitching = false;
            }
            break;
          //widgetは検証が終わったら消す
          case 'settings':
            widget.onSettings();
            break;
          case 'logout':
            widget.onLogout();
            break;
        }
      },
      itemBuilder: (context) => /*const*/ [
        // 接続先切り替えメニュー項目(開発検証用)
        PopupMenuItem(
          value: 'switch_server',
          child: Row(
            children: [
              Icon(
                Icons.swap_horiz_rounded,
                color: isAws ? const Color(0xFFB7F35A) : Colors.orangeAccent,
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '接続先切り替え',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  Text(
                    isAws ? '現在: AWS (CloudFront)' : '現在: Tailscale / Local',
                    style: TextStyle(
                      color: isAws ? const Color(0xFFB7F35A) : Colors.orangeAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        //------------------------------------
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'settings',
          child: Row(
            children: [
              Icon(
                Icons.settings_rounded,
                color: Colors.white70,
              ),
              SizedBox(width: 12),
              Text(
                '設定',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'logout',
          child: Row(
            children: [
              Icon(
                Icons.logout_rounded,
                color: Colors.white70,
              ),
              SizedBox(width: 12),
              Text(
                'ログアウトして終了',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      ],
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: 1.4,
            sigmaY: 1.4,
          ),
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF172433)
                  .withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color:const Color(0xFFB7F35A)
                        .withValues(alpha: 0.42),
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.menu_rounded,
              color: Colors.white70,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }

  void _removeFocus() {
    FocusManager.instance.primaryFocus?.unfocus();
  }
}

/// 「新しい会話」ボタン
class ChatNewConversationButton extends StatelessWidget {
  const ChatNewConversationButton({
    super.key,
    required this.onTap,
    this.isWide = false,
  });

  final VoidCallback onTap;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    return _ChatGlassButton(
      width: isWide ? 390 : null,
      height: isWide ? 44 : 48,
      isAccent: isWide,
      onTap: onTap,
      child: Row(
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            color: Colors.white,
            size: isWide ? 20 : 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '新しい会話',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: isWide ? 15 : 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            color: Colors.white70,
            size: isWide ? 24 : 22,
          ),
        ],
      ),
    );
  }
}

/// CAPTUREボタン
class ChatCaptureButton extends StatelessWidget {
  const ChatCaptureButton({
    super.key,
    required this.onTap,
    this.isWide = false,
  });

  final VoidCallback onTap;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    return _ChatGlassButton(
      width: isWide ? 150 : null,
      height: isWide ? 44 : 48,
      isAccent: isWide,
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.camera_alt_rounded,
            color: Colors.white,
            size: isWide ? 20 : 18,
          ),
          const SizedBox(width: 8),
          Text(
            'CAPTURE',
            style: TextStyle(
              color: Colors.white,
              fontSize: isWide ? 13 : 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// 音量ボタン
class ChatVolumeButton extends StatelessWidget {
  const ChatVolumeButton({
    super.key,
    required this.onTap,
    this.isWide = false,
  });

  final VoidCallback onTap;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    return _ChatGlassButton(
      width: isWide ? 52 : 64,
      height: isWide ? 47 : 54,
      borderRadius: isWide ? 26 : 18,
      isAccent: true,
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Icon(
        Icons.volume_up_rounded,
        color: Colors.white,
        size: 28,
      ),
    );
  }
}

/// 共通のガラス風ボタン
class _ChatGlassButton extends StatelessWidget {
  const _ChatGlassButton({
    required this.height,
    required this.onTap,
    required this.child,
    this.width,
    this.padding =
        const EdgeInsets.symmetric(horizontal: 14),
    this.borderRadius = 18,
    this.isAccent = false,
  });

  final double? width;
  final double height;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final bool isAccent;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final borderColor = const Color(0xFFB7F35A).withValues(alpha: 0.42);

    final backgroundColor = const Color(0xFF2C475F).withValues(alpha: 0.72);

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: 1.6,
          sigmaY: 1.6,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius:
                BorderRadius.circular(borderRadius),
            splashColor: Colors.white.withValues(alpha: 0.18),
            highlightColor:
                Colors.white.withValues(alpha: 0.10),
            onTap: onTap,
            child: Container(
              width: width,
              height: height,
              padding: padding,
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius:
                    BorderRadius.circular(borderRadius),
                border: Border.all(
                  color: borderColor,
                  width: 2,
                ),
                boxShadow: isAccent
                    ? [
                        BoxShadow(
                          color: const Color(0xFFB7F35A)
                              .withValues(alpha: 0.12),
                          blurRadius: 14,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showImageSourceSelector(
  BuildContext context,
) async {
  // 現在のshowModalBottomSheet処理
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
