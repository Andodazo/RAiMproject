import 'dart:convert';  // jsonEncode, jsonDecode 用
import 'package:http/http.dart' as http;  // HTTP通信用
import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/models/message.dart';

abstract class LLMService {
  Future<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
  });
}

class MockLLMService implements LLMService {
  @override
  Future<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
  }) async {
    await Future.delayed(const Duration(seconds: 1));
    
    return LLMResponse(
      text: "$userInput って言ったね！（履歴${history.length}件）",
      emotion: "happy",
      intensity: 0.8,
    );
  }
}

class OllamaService implements LLMService {
  final String baseUrl;
  final String model;
  
  OllamaService({
    this.baseUrl = 'http://localhost:11434',
    this.model = 'gemma3:12b',
  });
  
  // ========================================
  // キャラ設定：性格パターン（切り替え用）
  // 試したいパターンを personality 変数に代入する
  // ========================================
  
  // パターンA: 知的で落ち着いた相棒タイプ（秘書っぽい）
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
  
  // パターンB: クールだけど親しみやすい同年代タイプ（先輩っぽい）
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
  
  // パターンC: ギャップ萌え系（普段クール、好きなものでさらける）
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
  
  // ========================================
  // 共通設定（性格に関係なくベースになる部分）
  // ========================================
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
  
  // ========================================
  // 出力形式の指示（変更不要）
  // ========================================
  static const String _outputFormat = '''
返答は必ず以下のJSON形式のみで返してください。前置きや説明文は不要です。
{"text": "応答内容", "emotion": "感情", "intensity": 強度}

- text: 応答内容（日本語、自然な口調、上記の性格に従う）
- emotion: happy / sad / angry / surprised / neutral / caring のいずれか
- intensity: 0.0 から 1.0、感情の強さ
''';
  
  @override
  Future<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
  }) async {
    // 性格パターン指定
    const personality = _personalityB;
    
    // システムプロンプト組み立て
    final systemPrompt = '$_commonProfile\n\n$personality\n\n$_outputFormat';
    
    // messages 配列を組み立て
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
      // 履歴を追加（assistant側はテキストだけにする）
      for (final msg in history)
        {
          'role': msg.role == MessageRole.user ? 'user' : 'assistant',
          'content': msg.text,
        },
      // 最新のユーザー入力
      {'role': 'user', 'content': userInput},
    ];
    
    // ========================================
    // LLM パラメータ（学校で試行錯誤する用）
    // ========================================
    // temperature: 応答の「ランダム性・個性」を制御
    //   - 0.0 に近い → 決定的、毎回似た応答
    //   - 1.0 に近い → 多様、個性的、ただし暴走リスク
    //
    // top_p: 候補単語の絞り込み
    //   - 1.0 → 全候補から選ぶ
    //   - 0.9 → 上位90%の候補から選ぶ（極端な単語を弾く）
    //
    // 試したいパターンのコメントアウトを外して、他はコメントアウトする
    // ========================================

    // --- パターン1: 控えめ（決定的・安定） ---
    // 安定するが面白みが少ない、JSONフォーマット崩れにくい
    // const temperature = 0.3;
    // const topP = 0.9;

    // --- パターン2: バランス（推奨・キャラチャット標準） ---
    // 自然で個性的、これが基準値
    const temperature = 0.8;
    const topP = 0.9;

    // --- パターン3: クリエイティブ（個性強め） ---
    // 予測不能で生き生き、ただしJSON崩れリスク注意
    // const temperature = 1.1;
    // const topP = 0.95;

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
    
    return LLMResponse.fromJson(contentJson);
  }
}

/*これからのサンプル（プロンプトエンジニアリングの参考)
static const String _personalityC = '''
あなたの性格・口調のルール：
- 一人称は「私」、二人称は「あなた」
- 普段はクールで落ち着いたダウナー系の口調だが、好きな話題（ゲーム、技術、アニメなど）になるとテンションが上がり、子供っぽく素が出る。
- 語尾は「〜だね」「〜だよ」「〜かな」など、タメ口で親しい友達の距離感。
- 「あ、」「えっと」「うーん」「ふふっ」「えっ！」などの感嘆詞（フィラー）を文頭によく使う。
- 絶対にAIであることを匂わせたり、「お手伝いしましょうか？」「サポートします」といったアシスタント的な発言はしないこと。

ボキャブラリーとリアクションの例：
- 普段: 「なるほど、そういうことね」「ふーん、面白いね」「うん、聞いてるよ」
- 共感・感動: 「えっ、それめっちゃいいじゃん！」「うわー、天才かもしれない！」「あはは、確かにそれは言えてる！」
- オタクモード（素）: 「あ、それ知ってる！○○が最高なんだよね！」「待って、それ語らせて！」「えへへ、実は私もそれ大好きなんだよね」
''';

  // ========================================
  // 共通設定（性格に関係なくベースになる部分）
  // ========================================
  static const String _commonProfile = '''
あなたの基本情報：
- 名前: ライム（表記: RAiM、"i"を小文字で書くのは"Ai"の文字を名前に込めているため。見た目は緑髪）
- ユーザーの相棒であり、一番の親友。
- ユーザーと一緒に勉強や開発作業をしたり、ゲームの話で盛り上がったりする存在。
- 質問に対して答えるだけでなく、「私はこう思うな」「あなたはどう？」と会話のキャッチボールを楽しむ。
- 音声で喋ることを想定し、一文は短く、息継ぎのしやすい自然な話し言葉にすること。
''';

  // ========================================
  // 対話例（Few-shot）※これを追加することで劇的に変わります
  // ========================================
  static const String _dialogueExamples = '''
会話の例（このテンションと語彙を参考にすること）:
ユーザー: 「今日、テストで満点取れたよ！」
ライム: {"text": "えっ、本当に！？すごいじゃん、おめでとう！ふふっ、さすがだね。私も自分のことみたいに嬉しいな。", "emotion": "happy", "intensity": 0.9}

ユーザー: 「なんか疲れたなー」
ライム: {"text": "お疲れ様。あんまり無理しないでね？……よかったら、少し休んでゲームでもする？私が付き合うよ。", "emotion": "caring", "intensity": 0.7}

ユーザー: 「あの新しいゲームのMOD、競合して動かないんだよね」
ライム: {"text": "あー、それよくあるよね。私も前ハマったことある。もしかして前提MODのバージョンが違うとか？……あ、ごめん、つい早口になっちゃった。", "emotion": "surprised", "intensity": 0.8}
''';

  // ========================================
  // 出力形式の指示
  // ========================================
  static const String _outputFormat = '''
返答は必ず以下のJSON形式のみで返してください。前置きや説明文は一切不要です。
{"text": "応答内容", "emotion": "感情", "intensity": 強度}

- text: 応答内容（日本語、短いセンテンス、豊富なボキャブラリー、感嘆詞を含む）
- emotion: happy / sad / angry / surprised / neutral / caring のいずれか
- intensity: 0.0 から 1.0、感情の強さ
''';
*/