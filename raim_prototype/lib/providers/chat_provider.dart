import 'package:flutter/foundation.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/services/llm_service.dart';

class ChatProvider extends ChangeNotifier {
  // 使うLLMサービス（Mock or Ollama or Bedrock）
  final LLMService _llmService;
  
  // チャット履歴
  final List<Message> _messages = [];
  
  // LLM応答待ち中かどうか
  bool _isLoading = false;
  
  // コンストラクタ：使うサービスを受け取る
  ChatProvider(this._llmService);
  
  // 外から読み取り専用でアクセス
  List<Message> get messages => List.unmodifiable(_messages);
  bool get isLoading => _isLoading;
  
  // ユーザーがメッセージを送信する
  Future<void> sendMessage(String text) async {
    // 1. ユーザーメッセージを履歴に追加
    _messages.add(Message(
      text: text,
      role: MessageRole.user,
      timestamp: DateTime.now(),
    ));
    notifyListeners();
    
    // 2. ローディング開始
    _isLoading = true;
    notifyListeners();
    
    // 3. LLMサービスを呼ぶ（履歴を渡す）
    try {
      // 直近10往復だけ送る（ユーザー＋AI×10ペア = 20件）
      final recentHistory = _messages.length > 21
          ? _messages.sublist(_messages.length - 21, _messages.length - 1)
          : _messages.sublist(0, _messages.length - 1);
      
      final LLMResponse response = await _llmService.sendMessage(
        text,
        history: recentHistory,
      );
      
      // 4. LLM応答を履歴に追加
      _messages.add(Message(
        text: response.text,
        role: MessageRole.assistant,
        timestamp: DateTime.now(),
        emotion: response.emotion,
        intensity: response.intensity,
      ));
    } catch (e) {
      _messages.add(Message(
        text: "エラーが発生しました: $e",
        role: MessageRole.assistant,
        timestamp: DateTime.now(),
      ));
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}