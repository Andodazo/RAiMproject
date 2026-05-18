import 'package:flutter/foundation.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/services/llm_service.dart';
import 'package:raim_prototype/services/unity_communicator.dart';

class ChatProvider extends ChangeNotifier {
  final LLMService _llmService;
  final UnityCommunicator _unityBridge;
  
  final List<Message> _messages = [];
  bool _isLoading = false;
  
  ChatProvider(this._llmService, this._unityBridge);
  
  List<Message> get messages => List.unmodifiable(_messages);
  bool get isLoading => _isLoading;
  
  Future<void> sendUserMessage(String text) async {
    _messages.add(Message(
      text: text,
      role: MessageRole.user,
      timestamp: DateTime.now(),
    ));
    notifyListeners();
    
    _isLoading = true;
    notifyListeners();
    
    try {
      final recentHistory = _messages.length > 21
          ? _messages.sublist(_messages.length - 21, _messages.length - 1)
          : _messages.sublist(0, _messages.length - 1);
      
      final LLMResponse response = await _llmService.sendMessage(
        text,
        history: recentHistory,
      );
      
      _messages.add(Message(
        text: response.text,
        role: MessageRole.assistant,
        timestamp: DateTime.now(),
        emotion: response.emotion,
        intensity: response.intensity,
      ));
      
      _unityBridge.sendEmotion(
        text: response.text,
        emotion: response.emotion,
        intensity: response.intensity,
      );
      
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