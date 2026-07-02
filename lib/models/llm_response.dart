//LLMResponseのJSONデータの定義(設計図)
// lib/models/llm_response.dart
// =============================================================================
// サーバーから受信するJSONメッセージのモデルクラス
// =============================================================================
//
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

  /// セッションID
  ///
  /// session_start メッセージで運ばれる識別子。
  /// 他の type では null。
  /// このIDを Flutter 側で保持して、以降の送信で含めるとサーバーが履歴を引ける。
  final String? sessionId;

  LLMResponse({
    this.type = 'chat',
    required this.text,
    required this.emotion,
    required this.intensity,
    this.sessionId,
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
    return LLMResponse(
      type: (json['type'] as String?) ?? 'chat',
      text: (json['text'] as String?) ?? '',
      emotion: (json['emotion'] as String?) ?? 'neutral',
      intensity: (json['intensity'] as num?)?.toDouble() ?? 0.5,
      sessionId: json['session_id'] as String?,
    );
  }

  // ─── type 判定用のゲッター（switch を書きやすくする） ───

  /// 通常応答か（UI に吹き出し追加するべきか）
  bool get isChat => type == 'chat';

  /// つなぎ言葉か（UI に追加せず、音声だけ再生するべきか）
  bool get isFillerAudio => type == 'filler_audio';

  /// セッション開始通知か（sessionId を保持するべきか）
  bool get isSessionStart => type == 'session_start';

  /// エラー通知か
  bool get isError => type == 'error';
}