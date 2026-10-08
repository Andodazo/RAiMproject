//送信処理・画像添付状態の取得・送信後のリセット・ボタンのデザイン
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/providers/camera_provider.dart';
import 'package:raim_prototype/providers/voice_controller.dart';
import 'package:raim_prototype/providers/voice_settings_provider.dart';
// 開発検証用
import 'package:raim_prototype/providers/auth_provider.dart';
import 'package:raim_prototype/services/raim_server_service.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/voice/delayed_send.dart';
import 'package:raim_prototype/services/wake_cue.dart';
import 'package:raim_prototype/services/wake_word_service.dart';
import 'package:raim_prototype/config/raim_config.dart';

class ChatInput extends StatefulWidget {
  const ChatInput({super.key});
  
  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _controller = TextEditingController();
  // Windows版で Enter / Shift + Enter を判定するためのフォーカス管理
  final FocusNode _inputFocusNode = FocusNode();

  /// 声で聞き取れた一言（「ねえライム」やマイクボタンのあと）
  StreamSubscription<String>? _utteranceSub;

  /// 「ねえライム」に反応したとき（合図の音と振動を出す）
  StreamSubscription<WakeWordDetection>? _wakeSub;

  /// 聞き取った文を少し待ってから送る（設定「少し待ってから送る」）
  final DelayedSend _delayed = DelayedSend();

  @override
  void initState() {
    super.initState();

  // 入力欄にフォーカスがあるときのキー入力を監視する
    _inputFocusNode.onKeyEvent = _handleInputKeyEvent;

    final voice = context.read<VoiceController>();
    _utteranceSub = voice.utterances.listen(_onUtterance);
    if (Platform.isAndroid || Platform.isIOS) {
      _wakeSub = voice.wakeEvents.listen((_) {
        if (!mounted) return;
        final muted = context.read<VoiceSettingsProvider>().speechMuted;
        unawaited(WakeCue.play(sound: !muted));
      });
    }
  }

  /// 聞き取れた一言を入力欄に入れ、設定に合わせて送る。
  ///
  /// 書きかけがあるときや返事の生成中は、設定に関係なく入力欄に足すだけ。
  /// 「少し待ってから送る」では、待っている間に入力欄を触ると止まる。
  void _onUtterance(String text) {
    if (!mounted) return;
    final placed = placeUtterance(
      typed: _controller.text,
      heard: text,
      busy: context.read<ChatProvider>().isLoading,
    );
    _controller.value = TextEditingValue(
      text: placed.text,
      selection: TextSelection.collapsed(offset: placed.text.length),
    );
    final action = decideUtteranceAction(
      canSend: placed.send,
      mode: context.read<VoiceSettingsProvider>().sendMode,
    );
    switch (action) {
      case UtteranceAction.sendNow:
        _sendMessage();
      case UtteranceAction.sendLater:
        _delayed.start(_sendAfterWaiting);
      case UtteranceAction.keep:
        _delayed.cancel();
    }
  }

  /// 待ち終わったら送る。その間にまた話し始めていたら送らない（文は残る）。
  void _sendAfterWaiting() {
    if (!mounted) return;
    if (context.read<VoiceController>().isTranscribing) return;
    _sendMessage();
  }

  /// 入力欄のプレースホルダ。聞き取り中は途中経過を出す。
  String _hint(VoiceController voice, String heard) {
    if (voice.isTranscribing) return heard.isEmpty ? '聞いてるよ…' : heard;
    final error = voice.sttError;
    if (error != null) return '聞き取れませんでした（$error）';
    return '何でも話してね';
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
    _utteranceSub?.cancel();
    _wakeSub?.cancel();
    _delayed.dispose();

    // 使い終わった FocusNode を破棄する
    _inputFocusNode.dispose();

    // 使い終わった TextEditingController を破棄する
    _controller.dispose();
    super.dispose();
  }
  
  void _sendMessage() {
    // 待っている途中に送信ボタンで送ったときなど、二重に送らない
    _delayed.cancel();
    final chatProvider = context.read<ChatProvider>();

    // 生成中の二重送信を防ぐ。Enter キーからもここを通る。
    if (chatProvider.isLoading) return;

    final text = _controller.text.trim();
    //CameraProviderの状態を取得
    final cameraProvider = context.read<CameraProvider>();
    final isExhibitionDemo = context.read<AuthProvider>().isExhibitionDemo;

    // 展示用デモでは画像添付を使わせない。既に選択状態が残っていた
    // 場合も送信対象にしないよう、ここで破棄する。
    if (isExhibitionDemo && cameraProvider.hasImage) {
      cameraProvider.clearImage();
    }

    final hasImage = !isExhibitionDemo && cameraProvider.hasImage;
    // リスト型のゲッターをそのまま取得
    final imagePaths = cameraProvider.selectedImagePaths;
    final pendingImages = List.of(cameraProvider.selectedImages);
    //テキストも画像も両方空っぽなら何もせず終了
    if (text.isEmpty && !hasImage) return;

    // 本文・画像パス・画像データは出さない。件数だけ記録する。
    RaimLog.d(
      '[ChatInput] 送信 ${RaimLog.size(text)}, '
      '画像=${pendingImages.length}件',
    );
    //クリアされる前に、現在の画像パスのコピーを作成しておく（安全のため）
    // selectedImagePaths は非 null なので null 判定は不要（常に真だった）
    final pathsToSend = List<String>.from(imagePaths);
    // サーバーへ送信
    chatProvider.sendUserMessage(
      text,
      pendingImages: pendingImages,
      filePaths: pathsToSend, //画面表示用のファイルパスをChatProviderに渡す
      );
    _controller.clear();
    // 一時ファイルはアップロードサービスが読み終わってから削除する。
    cameraProvider.clearImage(deleteTemporaryFiles: false);
  }
  
  @override
  Widget build(BuildContext context) {
  final auth = context.watch<AuthProvider>();
  final isExhibitionDemo = auth.isExhibitionDemo;
  final voice = context.watch<VoiceController>();
  final manualMic = context.watch<VoiceSettingsProvider>().manualMicEnabled;
  final talking = voice.isTranscribing;

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
          if (!isExhibitionDemo) const _SelectedImagePreview(),
        // 聞き取った文を送るまでの待ち時間（設定「少し待ってから送る」）
        ListenableBuilder(
          listenable: _delayed,
          builder: (context, _) => !_delayed.isPending
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 16, 0),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'このまま送ります（入力欄を触ると止まります）',
                          style: TextStyle(
                            color: Color(0xFFB7F35A),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _delayed.cancel,
                        child: const Text(
                          '送らない',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // 画像を添える（カメラ / ギャラリー）。以前は画面上部の CAPTURE ボタンだった
              if (!isExhibitionDemo) ...[
                const _AttachImageButton(),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: voice.heardText,
                  builder: (context, heard, _) => TextField(
                    // Enterキーの処理を受け取るために FocusNode を設定する
                    focusNode: _inputFocusNode,
                    controller: _controller,
                    // 送るのを待っている間に触ったり直したりしたら、送らずに止める
                    onTap: _delayed.cancel,
                    onChanged: (_) => _delayed.cancel(),
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
                      hintText: _hint(voice, heard),

                      // マイクボタン。押して話し、もう一度押すか黙ると送る
                      suffixIcon: !manualMic && !talking
                          ? null
                          : IconButton(
                              tooltip: talking ? '話し終わり' : 'マイクで話しかける',
                              icon: Icon(
                                talking
                                    ? Icons.stop_circle_rounded
                                    : Icons.mic_rounded,
                                color: talking
                                    ? const Color(0xFFB7F35A)
                                    : Colors.white70,
                              ),
                              onPressed: talking || voice.canTalk
                                  ? () => voice.toggleTalk()
                                  : null,
                            ),

                      hintStyle: TextStyle(
                        color: talking
                            ? const Color(0xFFB7F35A)
                            : voice.sttError != null
                                ? const Color(0xFFFF8A80)
                                : Colors.white.withValues(alpha: 0.5),
                      ),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.15),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.3),
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
              ),

              const SizedBox(width: 8),

              // 送信ボタン
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF8BC34A),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 送るまでの残り時間。押せばすぐ送る
                    ListenableBuilder(
                      listenable: _delayed,
                      builder: (context, _) => !_delayed.isPending
                          ? const SizedBox.shrink()
                          : SizedBox(
                              width: 44,
                              height: 44,
                              child: TweenAnimationBuilder<double>(
                                key: ValueKey(_delayed.startedAt),
                                tween: Tween<double>(begin: 1.0, end: 0.0),
                                duration: _delayed.delay,
                                builder: (context, value, _) =>
                                    CircularProgressIndicator(
                                  value: value,
                                  strokeWidth: 3,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.send,
                        color: Colors.white,
                      ),
                      onPressed: _sendMessage,
                    ),
                  ],
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
              separatorBuilder: (_, _) => const SizedBox(width: 12),
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
    this.onStationAlarm,
    this.isWide = false,
  });

  final VoidCallback onSettings;
  final VoidCallback onLogout;

  /// 駅アラームを開く。null ならメニューに出さない（対応していない端末）
  final VoidCallback? onStationAlarm;
  final bool isWide;
  //開発検証用---------------------------------------------------
  @override
  State<ChatMenuButton> createState() => _ChatMenuButtonState();
}
  class _ChatMenuButtonState extends State<ChatMenuButton> {
  bool _isSwitching = false;
  // 接続先は RaimConfig に集約した（3箇所に散っていたのをやめる）
  static const String awsUrl = RaimConfig.serverUrl;
  static const String localUrl = RaimConfig.localServerUrl;
  //-----------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    // --現在の RaimServerService から接続先URLを取得(開発検証用)
    final raimService = context.read<RaimServerService>();
    final currentUrl = raimService.serverUrl;
    final isAws = RaimConfig.isAwsUrl(currentUrl);
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
              final isAws = RaimConfig.isAwsUrl(currentUrl);
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
          case 'credits':
          _showCreditsDialog(context);
          break;
          //widgetは検証が終わったら消す
          case 'settings':
            widget.onSettings();
            break;
          case 'station_alarm':
            widget.onStationAlarm?.call();
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
        // メニューに「クレジット表記」ボタンを追加
        PopupMenuItem<String>(
          value: 'credits',
          child: Row(
            children: const [
              Icon(
                Icons.info_outline,
                size: 20,
                color: Colors.white, // ★ アイコンを白にする
              ),
              SizedBox(width: 8),
              Text(
                'クレジット表記',
                style: TextStyle(color: Colors.white), // ★ 文字を白にする
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        if (widget.onStationAlarm != null) ...[
          const PopupMenuItem(
            value: 'station_alarm',
            child: Row(
              children: [
                Icon(Icons.train_rounded, color: Colors.white70),
                SizedBox(width: 12),
                Text('駅アラーム', style: TextStyle(color: Colors.white)),
              ],
            ),
          ),
          const PopupMenuDivider(),
        ],
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
// =============================================================================
// クレジット表記
// =============================================================================
  void _showCreditsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: const Row(
            children: [
              Icon(Icons.record_voice_over, color: Colors.blue),
              SizedBox(width: 8),
              Text('クレジット表記',style: TextStyle(color: Colors.white, fontSize: 18)),
            ],
          ),
          content: const SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
              //クレジット表記を増やしたい場合はここに追加
                Text(
                  '音声合成',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white,),
                ),
                SizedBox(height: 4),
                // 必要に応じて使用している音声モデルを追加
                Text('・VOICEVOX: 春日部つむぎ',style: TextStyle(color: Colors.white70)),
                
                Divider(height: 24, color: Colors.white24),//区切り線
                Text(
                  '音声認識',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white,),
                ),
                SizedBox(height: 4),
                Text('・Vosk（Alpha Cephei、Apache License 2.0）',style: TextStyle(color: Colors.white70)),
                Divider(height: 24, color: Colors.white24),
                Text(
                  '駅データ',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white,),
                ),
                SizedBox(height: 4),
                Text('・station_database（Seo-4d696b75、CC BY 4.0）',style: TextStyle(color: Colors.white70)),
                Divider(height: 24, color: Colors.white24),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
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

  /// タップ時のコールバック
  ///
  /// 引数の BuildContext は「このボタン自身」のもの。
  /// ボタンの真下にメニューを出すために、呼び出し側が位置を取得できるようにする。
  final void Function(BuildContext buttonContext) onTap;

  final bool isWide;

  @override
  Widget build(BuildContext context) {
    // Builder を挟むことで、ボタン自身の位置を指す BuildContext を得る。
    // 外側の context のままだと画面全体の RenderBox になってしまう。
    return Builder(
      builder: (buttonContext) => _ChatGlassButton(
      width: isWide ? 390 : null,
      height: isWide ? 44 : 48,
      isAccent: isWide,
      onTap: () => onTap(buttonContext),
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
      ),
    );
  }
}

/// 入力欄の左の画像ボタン。押すとカメラかギャラリーを選ぶシートが出る。
///
/// 入力欄（白の半透明・角丸）と同じ見た目にして、入力欄の一部に見せる。
class _AttachImageButton extends StatelessWidget {
  const _AttachImageButton();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.15),
      shape: CircleBorder(
        side: BorderSide(
          color: Colors.white.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        tooltip: '画像を添える',
        icon: const Icon(Icons.photo_camera_rounded, color: Colors.white70),
        onPressed: () {
          FocusManager.instance.primaryFocus?.unfocus();
          showImageSourceSelector(context);
        },
      ),
    );
  }
}

/// 音量ボタン。押すとライムの声を消す / 出すを切り替える。
///
/// 状態は VoiceSettingsProvider に保存するので、アプリを閉じても残る。
/// 消したときに喋っている途中なら、その場で止める。
class ChatVolumeButton extends StatelessWidget {
  const ChatVolumeButton({
    super.key,
    this.isWide = false,
  });

  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<VoiceSettingsProvider>();
    final muted = settings.speechMuted;

    return Tooltip(
      message: muted ? 'ライムの声を出す' : 'ライムの声を消す',
      child: _ChatGlassButton(
        width: isWide ? 52 : 56,
        height: isWide ? 47 : 48,
        borderRadius: isWide ? 26 : 18,
        isAccent: !muted,
        padding: EdgeInsets.zero,
        onTap: () {
          final mute = !muted;
          settings.setSpeechMuted(mute);
          if (mute) context.read<ChatProvider>().stopSpeaking();
        },
        child: Icon(
          muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          color: muted ? Colors.white54 : Colors.white,
          size: isWide ? 26 : 24,
        ),
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
