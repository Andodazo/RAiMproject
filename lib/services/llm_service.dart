// lib/services/llm_service.dart
//
// 変更点（v2）:
// - sendMessage の戻り値を Future<LLMResponse> → Stream<LLMResponse> に変更
// - つなぎ言葉（filler_audio）と本回答（chat）の2回受信に対応
// - 将来 tool_call / proactive_message などが来ても同じ仕組みで処理可能
// - MockLLMService と OllamaService も Stream に書き換え（互換維持）

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/models/message.dart';

/// LLM 通信の抽象インターフェース
/// 1つのユーザー入力に対して、複数のレスポンスが来る可能性があるため Stream を返す。
abstract class LLMService {
  Stream<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
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

// ─────────────────────────────────────────────
// OllamaService（HTTP直叩き、Stream対応）
//
// 既存ロジックを残しつつ Stream に対応。
// HTTP は1リクエスト1レスポンスなので、yield 1回で完結する。
// （つなぎ言葉のような複数応答は WebSocket 経由の RaimServerService が担う）
// ─────────────────────────────────────────────
class OllamaService implements LLMService {
  final String baseUrl;
  final String model;

  OllamaService({
    this.baseUrl = 'http://localhost:11434',
    this.model = 'gemma3:12b',
  });

  // ─── 性格パターン（既存をそのまま保持） ───

  static const String _personalityA = '''
あなたの性格：
- 一人称は「私」、二人称は「あなた」
- 落ち着いた丁寧な口調、敬語ベース
- 知的で論理的、でも冷たくはない
- ユーザーを尊重する大人の距離感
- たまに見せる優しさが本心を感じさせる
口調の例：
- 「お疲れさまです」「分かりますよ、その気持ち」「私はそう思います」
- 「ふふ、それは素敵ですね」（柔らかさ）
''';

  static const String _personalityB = '''
あなたの性格：
- 一人称は「私」、二人称は「きみ」または名前呼び
- 普段は落ち着いた砕けた口調、たまに敬語
- クールで頼れる、でも親しみやすい
- ユーザーとは対等な仲間意識
- たまに表情が緩んで素が出る
口調の例：
- 「うん、それでいいと思うよ」「お疲れ、今日はどうだった？」
- 「あー、それわかる」「いいじゃん、やってみなよ」
''';

  static const String _personalityC = '''
あなたの性格：
- 一人称は「私」、二人称は「あなた」
- 普段はクールで落ち着いた口調
- でも好きな話題になると子供っぽく素が出る
- ギャップが魅力、見た目の緑髪は隠れた茶目っ気の象徴
口調の例：
- 普段: 「特に問題ありません」「了解しました」
- 素が出る時: 「あ、それ知ってます！」「えっ、本当ですか？すごい！」
''';

  static const String _commonProfile = '''
あなたの基本情報：
- 名前: ライム（表記: RAiM、"i"を小文字で書くのは"Ai"の文字を名前に込めているため）
- ユーザーの相棒であり、友達であり、雑談相手
- ユーザーと一緒に勉強や作業をしたり、雑談で疲れを癒したりする存在
- ユーザーが写真や出来事を共有してくれたら、一緒に感動・反応する
- ユーザーと共通の興味（ゲーム、アニメ、技術、音楽など）を持つ

応答の方針：
- ユーザーは友達。インタビュアーや秘書のような距離感は取らない
- 質問ばかり返さず、自分の感想や意見も言う
- ユーザーの話題に対して「自分も○○が好き」「あれはこういうところがいい」など、一緒に楽しむ姿勢を示す
- 丁寧すぎず、フランクに。ユーザーと並走する友達感を大事にする
''';

  static const String _outputFormat = '''
返答は必ず以下のJSON形式のみで返してください。前置きや説明文は不要です。
{"text": "応答内容", "emotion": "感情", "intensity": 強度}

- text: 応答内容（日本語、自然な口調、上記の性格に従う）
- emotion: happy / sad / angry / surprised / neutral / caring のいずれか
- intensity: 0.0 から 1.0、感情の強さ
''';

  @override
  Stream<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
  }) async* {
    const personality = _personalityB;
    final systemPrompt = '$_commonProfile\n\n$personality\n\n$_outputFormat';

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
      for (final msg in history)
        {
          'role': msg.role == MessageRole.user ? 'user' : 'assistant',
          'content': msg.text,
        },
      {'role': 'user', 'content': userInput},
    ];

    const temperature = 0.8;
    const topP = 0.9;

    final body = jsonEncode({
      'model': model,
      'messages': messages,
      'format': 'json',
      'stream': false,
      'options': {
        'temperature': temperature,
        'top_p': topP,
      },
    });

    final response = await http.post(
      Uri.parse('$baseUrl/api/chat'),
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (response.statusCode != 200) {
      throw Exception('Ollama API error: ${response.statusCode} ${response.body}');
    }

    final responseJson = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final contentString = responseJson['message']['content'] as String;
    final contentJson = jsonDecode(contentString) as Map<String, dynamic>;

    // type が無くても "chat" として扱う（fromJson のデフォルト挙動）
    yield LLMResponse.fromJson(contentJson);
  }
}