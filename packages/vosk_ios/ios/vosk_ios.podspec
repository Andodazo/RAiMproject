#
# Vosk（libvosk）を iOS アプリに静的リンクするためだけのプラグイン。
#
# libvosk.xcframework は大きい（約170MB）ので Git には入れない。
# Mac で tool/fetch_libvosk.sh を一度実行して Frameworks/ に置く。
# 無い場合もビルドは通る（「ねえライム」と駅アラームが iOS で使えないだけ）。
#
Pod::Spec.new do |s|
  s.name             = 'vosk_ios'
  s.version          = '0.1.0'
  s.summary          = 'Links libvosk statically into the iOS app for Dart FFI.'
  s.homepage         = 'https://github.com/Andodazo/RAiMproject'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'RAiM' => 'raim@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/VoskIosPlugin.h'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.static_framework = true

  # Kaldi（Vosk の中身）は C++ で、行列計算に Accelerate を使う
  s.libraries  = 'c++'
  s.frameworks = 'Accelerate'

  framework = File.join(__dir__, 'Frameworks', 'libvosk.xcframework')
  if File.exist?(framework)
    s.vendored_frameworks = 'Frameworks/libvosk.xcframework'
    s.pod_target_xcconfig = {
      'DEFINES_MODULE' => 'YES',
      'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) VOSK_IOS_LINKED=1',
    }
  else
    Pod::UI.warn 'vosk_ios: Frameworks/libvosk.xcframework がありません。' \
                 'packages/vosk_ios/tool/fetch_libvosk.sh を実行してください。' \
                 '（無くてもビルドは通りますが、iOS で Vosk を使えません）'
    s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  end

  # Dart の FFI は、実行ファイルの中の関数を名前で探す（dlsym）。
  # リリースビルドの既定ではシンボルが消されて見つからなくなるので、
  # 外から見える関数の名前は残す。
  s.user_target_xcconfig = { 'STRIP_STYLE' => 'non-global' }
end
