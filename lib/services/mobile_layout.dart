import 'package:flutter/foundation.dart';

/// スマホのチャット画面で測った並びを、ほかの部品と分け合う。
class MobileLayout {
  MobileLayout._();

  /// ライムの頭のてっぺんの高さ（画面の上からの割合、0〜1）。
  ///
  /// ChatScreen が「新しい会話」のバーの下端から計算して Unity へ送った値。
  /// 寝ているときの「Zzz」を頭の横に出すのに使う。測る前は null。
  static final ValueNotifier<double?> headTop = ValueNotifier<double?>(null);
}
