import 'package:raim_prototype/models/llm_response.dart';

abstract class LLMService {
  Future<LLMResponse> sendMessage(String userInput);
}

class MockLLMService implements LLMService {
  @override
  Future<LLMResponse> sendMessage(String userInput) async {
    // 1秒待つ（実際のLLM応答時間をシミュレート）
    await Future.delayed(const Duration(seconds: 1));
    
    // 固定の応答を返す
    return LLMResponse(
      text: "$userInput って言ったね！",
      emotion: "happy",
      intensity: 0.8,
    );
  }
}