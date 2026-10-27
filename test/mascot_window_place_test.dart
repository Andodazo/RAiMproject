// 入力小窓の置き場所（会話ログや ☰ パネルを開いたらライムの横）の確認

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/mascot_window_service.dart';

void main() {
  const width = MascotWindowService.windowWidth;
  const bar = MascotWindowService.barHeight;
  const log = MascotWindowService.logHeight;
  const area = Rect.fromLTWH(0, 0, 1920, 1040);

  // ライム: 中心X=1000、足元Y=900、Unity ウィンドウの上端=300（高さ600 → 半分の幅108）
  Offset place(double height, {double centerX = 1000, Rect? workArea = area}) =>
      MascotWindowService.placeWindow(
        centerX: centerX,
        footY: 900,
        characterTop: 300,
        area: workArea,
        height: height,
        collapsedHeight: bar,
        gapBelow: 0,
      );

  test('入力バーだけのときは、ライムの足元の真下に置く', () {
    final p = place(bar);
    expect(p.dx, 1000 - width / 2);
    expect(p.dy, 900);
  });

  test('会話ログを開いたら、ライムの左に置き、下端は入力バーと同じ高さ', () {
    final p = place(log);
    final halfWidth = 600 * MascotWindowService.characterAspect / 2;
    expect(p.dx + width, closeTo(1000 - halfWidth - MascotWindowService.sideGap, 0.01));
    expect(p.dy + log, 900 + bar);
  });

  test('左に入らなければ、ライムの右に置く', () {
    final p = place(log, centerX: 300);
    final halfWidth = 600 * MascotWindowService.characterAspect / 2;
    expect(p.dx, closeTo(300 + halfWidth + MascotWindowService.sideGap, 0.01));
  });

  test('どちらにも入らなければ、広い方に置いて画面の中へ押し戻す', () {
    const narrow = Rect.fromLTWH(0, 0, 900, 1040);
    final p = place(log, centerX: 500, workArea: narrow);
    expect(p.dx, greaterThanOrEqualTo(0));
    expect(p.dx + width, lessThanOrEqualTo(900));
  });

  test('画面の下に入らないときは、上へ押し戻す', () {
    final p = MascotWindowService.placeWindow(
      centerX: 1000,
      footY: 1030,
      characterTop: 400,
      area: area,
      height: bar,
      collapsedHeight: bar,
      gapBelow: 0,
    );
    expect(p.dy + bar, lessThanOrEqualTo(1040));
  });
}
