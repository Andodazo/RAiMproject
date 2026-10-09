import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/services/mobile_layout.dart';

/// サーバーにつながらない（offline）間、ライムの頭の右上に「Zzz」を浮かべる（スマホのみ）。
///
/// 立ち絵は Unity 側で寝ている絵に切り替わる（ChatProvider → sendSleeping）。
/// 寝ている間も再接続は続けていて、つながれば自動で起きる。話しかけても起こせる。
class SleepingZzz extends StatelessWidget {
  const SleepingZzz({super.key});

  /// 画面の横幅に対する、Z を出し始める位置（中央からの右へのずれ）。
  /// ライムは画面の横の中央に立っている。
  static const double rightOfCenter = 0.10;

  /// 頭のてっぺんから下へのずれ（画面の高さに対する割合）
  static const double belowHeadTop = 0.03;

  /// 頭の位置をまだ測っていないときの代わり（NightOfficePresentation の既定値）
  static const double fallbackHeadTop = 0.22;

  @override
  Widget build(BuildContext context) {
    final offline = context.select<ChatProvider, bool>((c) => c.isOffline);
    if (!offline) return const SizedBox.shrink();

    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<double?>(
          valueListenable: MobileLayout.headTop,
          builder: (context, headTop, _) {
            final size = MediaQuery.sizeOf(context);
            final top = ((headTop ?? fallbackHeadTop) + belowHeadTop) *
                size.height;
            final left = size.width * (0.5 + rightOfCenter);
            return Stack(
              children: [
                Positioned(left: left, top: top, child: const _FloatingZ()),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 3つの Z が順に浮かび上がって消えていく
class _FloatingZ extends StatefulWidget {
  const _FloatingZ();

  @override
  State<_FloatingZ> createState() => _FloatingZState();
}

class _FloatingZState extends State<_FloatingZ>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2700),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Z が動ける範囲。左下から右上へ浮かぶ
    return SizedBox(
      width: 90,
      height: 90,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < 3; i++) _z((_controller.value + i / 3) % 1.0),
          ],
        ),
      ),
    );
  }

  Widget _z(double t) {
    // 出始めと消え際をなめらかにする
    final opacity = t < 0.2
        ? t / 0.2
        : t > 0.7
            ? (1 - t) / 0.3
            : 1.0;
    final scale = 0.6 + 0.6 * t;
    return Positioned(
      left: 34 * t,
      bottom: 56 * t,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.bottomLeft,
          child: const Text(
            'Z',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              shadows: [
                Shadow(color: Color(0xFFB7F35A), blurRadius: 8),
                Shadow(color: Colors.black54, blurRadius: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
