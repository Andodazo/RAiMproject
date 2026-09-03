import 'package:flutter/foundation.dart';

/// RAiM 全体で使うログ出力。
///
/// `print` / `debugPrint` を直接呼ばず、必ずここを通す。
///
/// 【なぜ必要か】
/// 以前はサーバーから届いた生メッセージ、会話本文、画像パス、音声の Base64、
/// OAuth の callback URL（認可コード入り）をそのまま出力していた。
/// release ビルドでも出るため、端末のログに個人情報と資格情報が残っていた。
///
/// 【ルール】
/// - 本文・トークン・URL・Base64・ファイルパスは **渡さない**。
///   長さや件数だけを出す。長さが要るときは [size] を使う。
/// - どうしても値が要る場合だけ [redact] を通す（中身は出ない）。
/// - release ビルドでは [RaimLogLevel.error] までしか出ない。
class RaimLog {
  RaimLog._();

  /// 出力する下限レベル。
  ///
  /// release では error のみ。開発中は debug まで全部出す。
  ///
  /// 注意: 既定を [RaimLogLevel.info] にすると、[d] の呼び出しは
  /// すべて捨てられてコンソールが無言になる（RAiM のログはほぼ [d] のため）。
  /// 絞りたいときは main() でここを差し替える。
  static RaimLogLevel level =
      kReleaseMode ? RaimLogLevel.error : RaimLogLevel.debug;

  /// デバッグ用。開発中の細かい流れ。
  static void d(String message) => _write(RaimLogLevel.debug, message);

  /// 通常の動作ログ。状態遷移など。
  static void i(String message) => _write(RaimLogLevel.info, message);

  /// 想定内だが気にしたい事象。
  static void w(String message) => _write(RaimLogLevel.warn, message);

  /// 失敗。release でも出る。
  static void e(String message, [Object? error]) {
    _write(
      RaimLogLevel.error,
      error == null ? message : '$message: $error',
    );
  }

  /// 中身を出さずに大きさだけ表す。
  ///
  /// 例: `RaimLog.d('audio_chunk 受信 ${RaimLog.size(base64)}')`
  static String size(Object? value) {
    if (value == null) return '(null)';
    if (value is String) return '${value.length}文字';
    if (value is List) return '${value.length}件';
    if (value is Map) return '${value.length}項目';
    return '(不明)';
  }

  /// 値そのものは出さず、存在と長さだけを出す。
  ///
  /// 先頭数文字も出さない。Base64 やトークンは先頭だけでも十分手掛かりになるため。
  static String redact(String? value) {
    if (value == null) return '(null)';
    if (value.isEmpty) return '(空)';
    return '(伏字 ${value.length}文字)';
  }

  static void _write(RaimLogLevel messageLevel, String message) {
    if (messageLevel.index > level.index) return;
    // ここだけが唯一の出力口。debugPrint は長い行を切らずに出す。
    debugPrint('${messageLevel.label} $message');
  }
}

/// 数値が小さいほど重大。[RaimLog.level] との比較に使う。
enum RaimLogLevel {
  none('[NONE]'),
  error('[E]'),
  warn('[W]'),
  info('[I]'),
  debug('[D]');

  const RaimLogLevel(this.label);

  final String label;
}
