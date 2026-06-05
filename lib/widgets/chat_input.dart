import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';

class ChatInput extends StatefulWidget {
  const ChatInput({super.key});
  
  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _controller = TextEditingController();
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    
    context.read<ChatProvider>().sendUserMessage(text);
    _controller.clear();
  }
  
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              // ★ テキスト色を白に
              style: const TextStyle(color: Colors.white, fontSize: 15),
              cursorColor: Colors.white,
              decoration: InputDecoration(
                hintText: '何でも話してね',

                // ★ここに追加
              suffixIcon: IconButton(
                icon: const Icon(
                  Icons.mic_rounded,
                  color: Colors.white70,
                ),
                onPressed: () {
                  debugPrint('[ChatInput] 音声入力ボタンが押されました');
                },
              ),
                // ★ ヒント色を薄い白に
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                // ★ 背景を半透明白で塗る
                filled: true,
                fillColor: Colors.white.withOpacity(0.15),
                // ★ 枠線を白系に
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
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          // ★ 送信ボタンを目立つように
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF8BC34A),  // ライムグリーン
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
              icon: const Icon(Icons.send, color: Colors.white),
              onPressed: _sendMessage,
            ),
          ),
        ],
      ),
    );
  }
}