import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';

/// VOICEVOX を使った TTS サービス（audioplayers 版）
class TTSService {
  final String baseUrl;
  
  // ==========================================
  // VOICEVOX 女性キャラクター話者IDリスト（標準スタイル）
  // ==========================================
  //  2 : 四国めたん (はっきりした芯のある声)
  //  3 : ずんだもん (元気な少女声)
  //  8 : 春日部つむぎ (元気なギャル風)
  //  9 : 波音リツ (クール・低めな女性声)
  // 10 : 雨晴はう (優しくおっとりした看護師ボイス)
  // 14 : 冥鳴ひまり (可愛らしい超ロリボイス)
  // 16 : 九州そら (お姉さん・サイエンス系ボイス)
  // 20 : もち子さん (お姉さん・少し低めで落ち着いた声)
  // 47 : ナースロボ＿タイプＴ (少しミステリアスなロボ声)
  // 54 : 夜桜よる (クールで知的なお姉さん声)
  //
  // --- 定番＆東北ファミリー ---
  // 11 : 東北ずん子 (おっとりしたお姉さん声)
  // 12 : 東北きりたん (しっかりものの妹系ボイス)
  // 13 : 東北イタコ (セクシーな気風のいいお姉さん声)
  // 23 : whiteCUL (爽やかで聞き取りやすい声)
  // 29 : No.7 (ツンデレ・クール系の少女声)
  // 43 : 櫻歌ミコ (独特な可愛らしさのあるロリ系ボイス)
  // 46 : SAYO (落ち着いた芯のある大人の女性声)
  // 51 : あいえるたん (元気で明るいテック系ボイス)
  // 52 : 夜語トバリ (ダウナーで落ち着いた大人の女性声)
  // 53 : ぞん子 (エネルギッシュでサイバー感のある声)
  //
  // --- 最新・追加キャラクター ---
  // 66 : ユーレイちゃん (少しハスキーで儚げな声)
  // 74 : ミタマ (和風でミステリアスな少女声)
  // 76 : 里石ユカ (ナチュラルで親しみやすい女性声)
  final int speakerId; 
  
  final AudioPlayer _audioPlayer = AudioPlayer();
  
  TTSService({
    this.baseUrl = 'http://localhost:50021',
    // this.baseUrl = 'http://100.x.x.x:50021',    // 自宅PCのVOICEVOX
    this.speakerId = 8,  // ← 別の声にしたい時は、ここ数値を上のリストのIDに変えてね！
  });
  
  Future<void> initialize() async {
    print('TTSService（VOICEVOX, 話者ID=$speakerId）初期化完了');
  }
  
  Future<void> speak(String text) async {
    try {
      await _audioPlayer.stop();
      
      // Step 1: audio_query
      final queryUri = Uri.parse(
        '$baseUrl/audio_query?text=${Uri.encodeQueryComponent(text)}&speaker=$speakerId',
      );
      
      final queryResponse = await http.post(queryUri);
      
      if (queryResponse.statusCode != 200) {
        print('VOICEVOX audio_query エラー: ${queryResponse.statusCode}');
        return;
      }
      
      // Step 2: synthesis
      final synthesisUri = Uri.parse('$baseUrl/synthesis?speaker=$speakerId');
      
      final synthesisResponse = await http.post(
        synthesisUri,
        headers: {'Content-Type': 'application/json'},
        body: queryResponse.body,
      );
      
      if (synthesisResponse.statusCode != 200) {
        print('VOICEVOX synthesis エラー: ${synthesisResponse.statusCode}');
        return;
      }
      
      // Step 3: WAVバイナリを audioplayers で再生
      final Uint8List audioData = synthesisResponse.bodyBytes;
      
      await _audioPlayer.play(BytesSource(audioData));
      
      print('TTS発話: $text');
    } catch (e) {
      print('VOICEVOX TTS エラー: $e');
    }
  }
  
  Future<void> stop() async {
    await _audioPlayer.stop();
  }
  
  void dispose() {
    _audioPlayer.dispose();
  }
}