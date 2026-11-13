import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/widgets/raim_calling_overlay.dart';

// つながらないときのおやすみ画面（2026-11-13）
void main() {
  Widget host(RaimSleepScreen screen) => MaterialApp(
        home: Scaffold(body: RaimSleepOverlay(screen: screen)),
      );

  testWidgets('つながっていれば何も出さない', (tester) async {
    await tester.pumpWidget(host(RaimSleepScreen.none));
    expect(find.byType(RaimCallingCard), findsNothing);
  });

  testWidgets('寝ているときは寝顔と「おやすみ中…」、話しかけたら「発信中」', (tester) async {
    await tester.pumpWidget(host(RaimSleepScreen.sleeping));
    expect(find.text('おやすみ中…'), findsOneWidget);
    expect(find.text('話しかけたら起こすね'), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, 'assets/images/raim_sleep_face.png');

    await tester.pumpWidget(host(RaimSleepScreen.waking));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('発信中'), findsOneWidget);
    expect(find.text('話しかけたら起こすね'), findsNothing);
    final awake = tester.widget<Image>(find.byType(Image));
    expect((awake.image as AssetImage).assetName, 'assets/images/raim_call_face.png');

    // つながったら「つながりました」を少し見せて消える
    await tester.pumpWidget(host(RaimSleepScreen.none));
    await tester.pump();
    expect(find.text('つながりました'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(RaimCallingCard), findsNothing);
  });

  testWidgets('寝ていて裏のつなぎ直しでつながったら、そのまま消える', (tester) async {
    await tester.pumpWidget(host(RaimSleepScreen.sleeping));
    await tester.pumpWidget(host(RaimSleepScreen.none));
    await tester.pump();
    expect(find.text('つながりました'), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(RaimCallingCard), findsNothing);
  });

  testWidgets('Windows の細い列では「RAiM」を出さない', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            height: 54,
            child: RaimCallingCard(
              connected: false,
              sleeping: true,
              horizontal: true,
              faceSize: 25,
              showTitle: false,
            ),
          ),
        ),
      ),
    ));
    expect(find.text('RAiM'), findsNothing);
    expect(find.text('おやすみ中…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
