#import "VoskIosPlugin.h"

#if VOSK_IOS_LINKED
#import "vosk_api.h"

// Dart は FFI（DynamicLibrary.process）でこれらの関数を名前で探して呼ぶ。
// ObjC / Swift のどこからも参照されていないと、リンカが「使われていない」と
// みなして libvosk.a から取り込まないので、ここで参照を持っておく。
// __attribute__((used)) は、この配列自体が捨てられないようにするため。
__attribute__((used)) static void *const kVoskIosKeepSymbols[] = {
  (void *)vosk_set_log_level,
  (void *)vosk_model_new,
  (void *)vosk_model_free,
  (void *)vosk_recognizer_new,
  (void *)vosk_recognizer_new_grm,
  (void *)vosk_recognizer_set_max_alternatives,
  (void *)vosk_recognizer_set_words,
  (void *)vosk_recognizer_accept_waveform,
  (void *)vosk_recognizer_result,
  (void *)vosk_recognizer_partial_result,
  (void *)vosk_recognizer_final_result,
  (void *)vosk_recognizer_reset,
  (void *)vosk_recognizer_free,
};
#endif

@implementation VoskIosPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  // 何もしない（Dart は FFI で直接呼ぶ）
}

@end
