import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raim_prototype/services/unity_ready_signal.dart';

/// Unity の準備ができるまで、ライムに電話をかけているような画面を出す（スマホのみ）。
///
/// 以前は Unity の起動画面（Made with Unity）がそのまま見えていた。
/// Unity の起動画面は切ってあり、代わりにこの画面を Unity の上に重ねる。
/// 上のバーと入力欄はこの画面より手前にあるので、待っている間も文字は打てる。
///
/// Unity から準備完了が届いたら「つながりました」を少し見せてから消す。
/// 何かの理由で届かなくても、[timeout] たったら消す。
class RaimCallingOverlay extends StatefulWidget {
  const RaimCallingOverlay({super.key});

  static const Duration timeout = Duration(seconds: 10);

  @override
  State<RaimCallingOverlay> createState() => _RaimCallingOverlayState();
}

class _RaimCallingOverlayState extends State<RaimCallingOverlay> {
  static const Color _background = Color(0xFF14141F);

  /// 「つながりました」を見せておく時間
  static const Duration _connectedHold = Duration(milliseconds: 700);
  static const Duration _fadeDuration = Duration(milliseconds: 400);

  Timer? _timeoutTimer;
  Timer? _holdTimer;

  bool _connected = false;
  bool _fading = false;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    if (UnityReadySignal.ready.value) {
      // もう Unity が起動している（ログアウト後に戻ってきたときなど）
      _gone = true;
      return;
    }
    UnityReadySignal.ready.addListener(_onReadyChanged);
    _timeoutTimer =
        Timer(RaimCallingOverlay.timeout, () => _finish(connected: false));
  }

  @override
  void dispose() {
    UnityReadySignal.ready.removeListener(_onReadyChanged);
    _timeoutTimer?.cancel();
    _holdTimer?.cancel();
    super.dispose();
  }

  void _onReadyChanged() {
    if (UnityReadySignal.ready.value) _finish(connected: true);
  }

  void _finish({required bool connected}) {
    if (!mounted || _connected || _fading || _gone) return;
    _timeoutTimer?.cancel();
    setState(() => _connected = connected);
    _holdTimer = Timer(connected ? _connectedHold : Duration.zero, () {
      if (mounted) setState(() => _fading = true);
    });
  }

  void _onFadeEnd() {
    if (!_fading || !mounted) return;
    setState(() => _gone = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return const SizedBox.shrink();

    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _fading ? 0 : 1,
        duration: _fadeDuration,
        onEnd: _onFadeEnd,
        child: ColoredBox(
          color: _background,
          child: Align(
            alignment: const Alignment(0, -0.2),
            child: RaimCallingCard(connected: _connected),
          ),
        ),
      ),
    );
  }
}

/// ライムの顔のまわりに輪が広がり、「発信中...」と出る部品。
///
/// スマホの起動待ち（縦並び）と、Windows の入力小窓（横並び）で使う。
class RaimCallingCard extends StatefulWidget {
  const RaimCallingCard({
    super.key,
    required this.connected,
    this.horizontal = false,
    this.faceSize = 120,
  });

  /// true なら「つながりました」を出す
  final bool connected;

  /// true なら顔と文字を横に並べる（Windows の小窓用）
  final bool horizontal;

  /// 顔の円の直径。輪はこの2倍まで広がる。
  final double faceSize;

  static const Color accent = Color(0xFFB7F35A);

  @override
  State<RaimCallingCard> createState() => _RaimCallingCardState();
}

class _RaimCallingCardState extends State<RaimCallingCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final faceSize = widget.faceSize;
    // 横並びの小窓では、文字も少し小さくする
    final scale = widget.horizontal ? 0.75 : 1.0;

    final face = SizedBox(
      width: faceSize * 2,
      height: faceSize * 2,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) => CustomPaint(
          painter: _RingsPainter(
            progress: _pulse.value,
            innerRadius: faceSize / 2,
            color: RaimCallingCard.accent,
          ),
          child: child,
        ),
        child: Center(child: _buildFace(faceSize)),
      ),
    );

    final texts = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: widget.horizontal
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Text(
          'RAiM',
          style: TextStyle(
            color: Colors.white,
            fontSize: 28 * scale,
            fontWeight: FontWeight.w600,
            letterSpacing: 4 * scale,
          ),
        ),
        SizedBox(height: 8 * scale),
        AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) => Text(
            _statusText(),
            style: TextStyle(
              color: widget.connected ? RaimCallingCard.accent : Colors.white70,
              fontSize: 15 * scale,
              letterSpacing: 1,
            ),
          ),
        ),
      ],
    );

    if (widget.horizontal) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [face, const SizedBox(width: 4), texts],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [face, const SizedBox(height: 16), texts],
    );
  }

  Widget _buildFace(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1E2024),
        border: Border.all(color: RaimCallingCard.accent, width: 2),
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/images/raim_call_face.png',
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  String _statusText() {
    if (widget.connected) return 'つながりました';
    // 「発信中.」「発信中..」「発信中...」を順に出す
    final dots = (_pulse.value * 3).floor() % 3 + 1;
    return '発信中${'.' * dots}';
  }
}

/// 顔の周りに広がっていく輪（着信・発信の画面によくある波紋）
class _RingsPainter extends CustomPainter {
  _RingsPainter({
    required this.progress,
    required this.innerRadius,
    required this.color,
  });

  final double progress;
  final double innerRadius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;
    // 2本の輪を半周期ずらして出す
    for (final offset in const [0.0, 0.5]) {
      final t = (progress + offset) % 1.0;
      final radius = innerRadius + (maxRadius - innerRadius) * t;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: (1 - t) * 0.5);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
