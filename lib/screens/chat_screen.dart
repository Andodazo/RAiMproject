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
      backgroundColor: const Color(0xFF1a1a2e),
      body: isWideScreen 
          ? _buildWideLayout(context) 
          : _buildNarrowLayout(context),
    );
  }
  
  /// 背景画像（共通）
  Widget _buildBackground() {
    return Positioned.fill(
      child: Image.asset(
        'assets/images/background.png',
        fit: BoxFit.cover,
      ),
    );
  }
  
  /// 背景に黒の半透明オーバーレイ（キャラを引き立てる）
  Widget _buildBackgroundOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.3),
      ),
    );
  }
  
  /// スマホ・縦長レイアウト
  Widget _buildNarrowLayout(BuildContext context) {
    return Stack(
      children: [
        // ① 背景画像（一番下）
        _buildBackground(),
        
        // ② 背景に薄い黒オーバーレイ（キャラを引き立てる）
        _buildBackgroundOverlay(),
        
        // ③ キャラ表示
        const Positioned.fill(
          child: CharacterDisplay(),
        ),
        
        // ④ 上部タイトル
        Positioned(
          top: MediaQuery.of(context).padding.top,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: const Text(
              'RAiM',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
                shadows: [
                  Shadow(blurRadius: 8, color: Colors.black87),
                ],
              ),
            ),
          ),
        ),
        
        // ⑤ 下部チャット
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: MediaQuery.of(context).size.height * 0.5,
          child: Column(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.0),
                        Colors.black.withOpacity(0.4),
                      ],
                    ),
                  ),
                  child: const MessageList(),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
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
      ],
    );
  }
  
  /// PC・横長レイアウト
  Widget _buildWideLayout(BuildContext context) {
    return Stack(
      children: [
        // ① 背景画像（一番下）
        _buildBackground(),
        
        // ② 背景オーバーレイ
        _buildBackgroundOverlay(),
        
        // ③ キャラ表示
        const Positioned.fill(
          child: CharacterDisplay(),
        ),
        
        // ④ 左上タイトル
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
                Shadow(blurRadius: 12, color: Colors.black.withOpacity(0.8)),
              ],
            ),
          ),
        ),
        
        // ⑤ 右サイドチャットパネル
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
                const Expanded(
                  child: MessageList(),
                ),
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