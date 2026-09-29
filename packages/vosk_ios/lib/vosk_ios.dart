/// Vosk を iOS アプリに静的リンクするためだけのプラグイン。
///
/// Dart 側の API は持たない。アプリは `DynamicLibrary.process()` で
/// libvosk の関数を直接探して呼ぶ（lib/services/vosk/vosk_engine.dart）。
library;
