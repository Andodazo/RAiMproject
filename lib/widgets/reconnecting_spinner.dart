import 'package:flutter/material.dart';

/// つなぎ直している間に入力欄の左に出す、小さいぐるぐる（2026-11-13）。
///
/// 文字（「つなぎ直しているよ…」）は入力欄のヒントに出す。ぐるぐるで「動いている」が
/// 一目で分かるようにする。スマホの入力欄と Windows の入力窓で使う。
class ReconnectingSpinner extends StatelessWidget {
  const ReconnectingSpinner({
    super.key,
    this.size = 16,
    this.padding = const EdgeInsets.all(12),
  });

  final double size;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: SizedBox(
        width: size,
        height: size,
        child: const CircularProgressIndicator(
          strokeWidth: 2,
          color: Colors.white70,
          semanticsLabel: 'つなぎ直しています',
        ),
      ),
    );
  }
}
