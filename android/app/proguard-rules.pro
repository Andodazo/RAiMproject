# Vosk は JNA 経由でネイティブライブラリを呼ぶ。
# release ビルドで難読化されるとクラスが見つからず、
# 例外も出ないまま音声認識だけが黙って動かなくなる。
-keep class com.sun.jna.* { *; }
-keepclassmembers class * extends com.sun.jna.* { public *; }
