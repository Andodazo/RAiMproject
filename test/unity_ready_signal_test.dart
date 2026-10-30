import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/unity_ready_signal.dart';

void main() {
  setUp(UnityReadySignal.reset);

  test('unity.ready が届いたら準備完了になる', () {
    UnityReadySignal.handleMessage('{"type":"unity.ready"}');
    expect(UnityReadySignal.ready.value, isTrue);
  });

  test('ほかのメッセージや JSON でない文字列では変わらない', () {
    UnityReadySignal.handleMessage('{"type":"unity.clicked"}');
    UnityReadySignal.handleMessage('touch');
    UnityReadySignal.handleMessage('[1,2]');
    expect(UnityReadySignal.ready.value, isFalse);
  });

  // testWidgets の中ではタイマーの時間を進められる
  testWidgets('合図が届かなくても、待ち始めてから決まった時間がたったら準備完了になる',
      (tester) async {
    UnityReadySignal.startWaiting();

    await tester.pump(
      UnityReadySignal.fallbackDelay - const Duration(seconds: 1),
    );
    expect(UnityReadySignal.ready.value, isFalse);

    await tester.pump(const Duration(seconds: 1));
    expect(UnityReadySignal.ready.value, isTrue);
  });

  test('whenReady は、準備ができたときに1回だけ呼ぶ', () {
    var calls = 0;
    UnityReadySignal.whenReady(() => calls++);
    expect(calls, 0);

    UnityReadySignal.handleMessage('{"type":"unity.ready"}');
    expect(calls, 1);

    // 一度立ったら戻さないが、念のため立て直しても二重には呼ばない
    UnityReadySignal.ready.value = false;
    UnityReadySignal.ready.value = true;
    expect(calls, 1);
  });

  test('whenReady は、もう準備ができていればすぐ呼ぶ', () {
    UnityReadySignal.handleMessage('{"type":"unity.ready"}');
    var calls = 0;
    UnityReadySignal.whenReady(() => calls++);
    expect(calls, 1);
  });

  testWidgets('準備完了のあとに待ち始めても、何もしない', (tester) async {
    UnityReadySignal.handleMessage('{"type":"unity.ready"}');
    UnityReadySignal.startWaiting();

    await tester.pump(UnityReadySignal.fallbackDelay);
    expect(UnityReadySignal.ready.value, isTrue);
  });
}
