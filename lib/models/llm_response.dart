//LLMResponseのJSONデータの定義(設計図)
// lib/models/llm_response.dart
// =============================================================================
// サーバーから受信するJSONメッセージのモデルクラス
// =============================================================================
//

int? _readNullableInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
// 【このファイルの役割】
// WebSocket でサーバーから受信した JSON を Dart オブジェクトに変換するためのクラス。
// 全てのメッセージ type（chat / filler_audio / session_start / error など）を
// この1クラスで表現する。
//
// 【設計方針】
// 「未知のフィールド・未知の type にクラッシュしない」を最優先。
// サーバー側がスキーマを拡張しても、Flutter 側は無視するだけで動き続ける設計。
//
// 【参考】
// JSON スキーマ仕様: RAiM_serverside/docs/json-schema.md

class LLMResponse {
  /// メッセージ種別: "chat" / "filler_audio" / "session_start" / "error" など
  ///
  /// 未指定の場合は "chat" 扱い（旧 OllamaService 互換性のため）
  /// 未知の type が来てもエラーにせず、そのまま保持する
  /// → 受信側（ChatProvider）で switch する時に default で無視できる
  final String type;

  /// 応答テキスト本文
  /// session_start や error など、text を持たないメッセージでは空文字
  final String text;

  /// 感情ラベル: happy / sad / angry / surprised / neutral / caring など
  ///
  /// Unity 側の立ち絵切替に使用。
  /// 未対応の値が来たら Unity 側で neutral にフォールバックする運用
  final String emotion;

  /// 感情強度: 0.0〜1.0
  /// 0.0 = 弱い、1.0 = 最大強度
  /// Unity 側で表情の濃淡やアニメ大小の制御に使う
  final double intensity;


  // ============================================================
  // v2.2 複数感情情報
  // ============================================================
  // 新仕様では emotion/intensity だけでなく、
  // emotions + overallIntensity で複数感情を Unity に送る。
  final Map<String, double> emotions;
  final double overallIntensity;
  /// セッションID
  ///
  /// session_start メッセージで運ばれる識別子。
  /// 他の type では null。
  /// このIDを Flutter 側で保持して、以降の送信で含めるとサーバーが履歴を引ける。
  // ============================================================
  // セッション・チャンク管理
  // ============================================================
  // session_start / text_chunk / audio_chunk などで使う識別情報。
  // 分割された文章や音声を管理するために使う。
  final String? sessionId;
  final String? chunkId;
  final bool isFirst;
  final bool isFiller;
  // ============================================================
  // 音声ストリーミング情報
  // ============================================================
  // audio_chunk で届くサーバー生成音声。
  // Base64 を AudioPlayQueue でデコードして再生する。
  final String? audioBase64;
  final String? format;
  /// 分割音声のパーツ番号（0始まり）。単一音声では null。
  final int? partIndex;

  /// 分割音声の総パーツ数。単一音声では null。
  final int? partCount;

  /// このパーツが分割音声の末尾であることを示すフラグ。
  final bool isLast;
   // ============================================================
  // 返答完了・シーン情報
  // ============================================================
  // chat_end で届く最終全文や、
  // Unity 側の演出切り替えに使える情報。
  final String? fullText;
  final String? sceneId;
  // ============================================================
  // ツール実行情報
  // ============================================================
  // tool_call で届く検索・外部処理の状態表示に使う。
  // UI では「調べています...」のような表示に使う。
  /// 会話スレッドの識別子
  ///
  /// chat_end で返る。クライアントはこれを保持し、次回の送信で
  /// threadId として送り返すことで同じスレッドに追記できる。
  /// 新規作成された場合も、採番結果がここで分かる。
  ///
  /// metadata には入らない（サーバー側でスレッドが確定する前に
  /// 送信されるイベントのため）。
  final String? threadId;

  /// 受信した JSON そのもの
  ///
  /// thread_list / thread_history のように、LLMResponse の固定フィールドでは
  /// 表現しきれない構造（配列など）を扱うために保持する。
  /// 通常の chat 処理では使わない。
  final Map<String, dynamic> raw;

  final String? tool;
  final String? description;
  final int? estimatedSeconds;

  LLMResponse({
    this.type = 'chat',
    this.text = '',
    this.emotion = 'neutral',
    this.intensity = 0.5,
    this.sessionId,
    this.emotions = const {'neutral': 1.0},
    this.overallIntensity = 0.5,
    this.chunkId,
    this.isFirst = false,
    this.isFiller = false,
    this.audioBase64,
    this.format,
    this.partIndex,
    this.partCount,
    this.isLast = false,
    this.fullText,
    this.sceneId,
    this.threadId,
    this.raw = const {},
    this.tool,
    this.description,
    this.estimatedSeconds,
  });

  /// JSON から LLMResponse を組み立てる
  //
  /// 全てのフィールドを null 安全に処理する。
  /// 未指定なら全てデフォルト値にフォールバックする。
  /// これにより:
  /// - サーバー側でフィールドを追加してもクラッシュしない
  /// - text が無い session_start メッセージも問題なく扱える
  /// - 型が違ってもデフォルト値で吸収する
  factory LLMResponse.fromJson(Map<String, dynamic> json) {
    // ============================================================
    // emotions の変換
    // ============================================================
    // サーバーから来た emotions を Map<String, double> に変換する。
    // emotions が無い旧形式では emotion/intensity から代わりに作る。
    Map<String, double> emotionsMap = {};
    final rawEmotions = json['emotions'];

    if (rawEmotions is Map) {
      rawEmotions.forEach((key, value) {
        if (key is String && value is num) {
          emotionsMap[key] = value.toDouble();
        }
      });
    }

  if (emotionsMap.isEmpty) {
      final emo = (json['emotion'] as String?) ?? 'neutral';
      final intensity = (json['intensity'] as num?)?.toDouble() ?? 0.5;
      emotionsMap = {emo: intensity};
    }

    // ============================================================
    // overall_intensity の変換
    // ============================================================
    // 新仕様では overall_intensity を優先。
    // 無い場合は旧形式の intensity を使って互換性を保つ。
    final overall = (json['overall_intensity'] as num?)?.toDouble()
        ?? (json['intensity'] as num?)?.toDouble()
        ?? 0.5;

    // ============================================================
    // JSON から LLMResponse を作成
    // ============================================================
    // 無い項目はデフォルト値にして、未知のJSONでも落ちにくくする。
    return LLMResponse(
      type: (json['type'] as String?) ?? 'chat',
      text: (json['text'] as String?) ?? '',
      emotion: (json['emotion'] as String?) ?? 'neutral',
      intensity: (json['intensity'] as num?)?.toDouble() ?? 0.5,
      sessionId: json['session_id'] as String?,
      emotions: emotionsMap,
      overallIntensity: overall,
      chunkId: json['chunk_id'] as String?,
      isFirst: (json['is_first'] as bool?) ?? false,
      isFiller: (json['is_filler'] as bool?) ?? false,
      audioBase64: json['audio'] as String?,
      format: json['format'] as String?,
      partIndex: _readNullableInt(json['part_index']),
      partCount: _readNullableInt(json['part_count']),
      isLast: (json['is_last'] as bool?) ?? false,
      fullText: json['full_text'] as String?,
      sceneId: json['scene_id'] as String?,
      threadId: json['threadId'] as String?,
      raw: json,
      tool: json['tool'] as String?,
      description: json['description'] as String?,
      estimatedSeconds: json['estimated_seconds'] as int?,
    );
  }

  // ─── type 判定用のゲッター（switch を書きやすくする） ───
   // サーバーから届いたメッセージ種類を ChatProvider で判定しやすくする。
  bool get isMetadata => type == 'metadata';
  bool get isTextChunk => type == 'text_chunk';
  bool get isAudioChunk => type == 'audio_chunk';
  bool get isToolCall => type == 'tool_call';
  bool get isChatEnd => type == 'chat_end';
  bool get isBubbleBreak => type == 'bubble_break';

  /// スレッド一覧の応答か
  bool get isThreadList => type == 'thread_list';

  /// スレッド履歴の応答か
  bool get isThreadHistory => type == 'thread_history';

  /// スレッド削除の応答か
  bool get isThreadDeleted => type == 'thread_deleted';

  /// 通常応答か（UI に吹き出し追加するべきか）
  bool get isChat => type == 'chat';

  /// つなぎ言葉か（UI に追加せず、音声だけ再生するべきか）
  bool get isFillerAudio => type == 'filler_audio';

  /// セッション開始通知か（sessionId を保持するべきか）
  bool get isSessionStart => type == 'session_start';

  /// エラー通知か
  bool get isError => type == 'error';
}
