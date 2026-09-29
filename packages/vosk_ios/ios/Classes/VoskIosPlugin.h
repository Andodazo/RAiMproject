#import <Flutter/Flutter.h>

/// Vosk を iOS アプリに静的リンクするためだけのプラグイン。
/// Dart からは FFI で直接呼ぶので、Flutter とのやり取りは持たない。
@interface VoskIosPlugin : NSObject <FlutterPlugin>
@end
