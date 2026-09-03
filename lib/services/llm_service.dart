// lib/services/llm_service.dart
//
// 変更点（v2）:
// - sendMessage の戻り値を Future<LLMResponse> → Stream<LLMResponse> に変更
// - つなぎ言葉（filler_audio）と本回答（chat）の2回受信に対応
// - 将来 tool_call / proactive_message などが来ても同じ仕組みで処理可能
// - OllamaService（Ollama 直叩き）は AWS 移行で不要になったため削除

import 'dart:async';
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/models/message.dart';

/// LLM 通信の抽象インターフェース
/// 1つのユーザー入力に対して、複数のレスポンスが来る可能性があるため Stream を返す。
abstract class LLMService {
  Stream<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
    List<Map<String, dynamic>>? images, // ★ オプション引数に画像配列を追加
    String? threadId, // 会話スレッドの指定（省略時はサーバー側が判断）
  });
}

// ─────────────────────────────────────────────
// MockLLMService（テスト用、Stream対応）
// ─────────────────────────────────────────────
class MockLLMService implements LLMService {
  @override
  Stream<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
    List<Map<String, dynamic>>? images, // ★ 型を合わせるために追加
    String? threadId, // インターフェースに合わせる（この実装では未使用）
  }) async* {
    await Future.delayed(const Duration(seconds: 1));
    yield LLMResponse(
      type: 'chat',
      text: "$userInput って言ったね！（履歴${history.length}件）",
      emotion: "happy",
      intensity: 0.8,
    );
  }
}
