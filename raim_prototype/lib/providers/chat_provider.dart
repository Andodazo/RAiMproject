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
    notifyListeners();  // UIに「変わったよ」と通知
    
    // 2. ローディング開始
    _isLoading = true;
    notifyListeners();
    
    // 3. LLMサービスを呼ぶ
    try {
      final LLMResponse response = await _llmService.sendMessage(text);
      
      // 4. LLM応答を履歴に追加
      _messages.add(Message(
        text: response.text,
        role: MessageRole.assistant,
        timestamp: DateTime.now(),
        emotion: response.emotion,
        intensity: response.intensity,
      ));
    } catch (e) {
      // エラー時は仮のメッセージを表示
      _messages.add(Message(
        text: "エラーが発生しました: $e",
        role: MessageRole.assistant,
        timestamp: DateTime.now(),
      ));
    } finally {
      // 5. ローディング終了
      _isLoading = false;
      notifyListeners();
    }
  }
}