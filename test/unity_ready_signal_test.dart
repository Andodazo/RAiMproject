import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/services/unity_ready_signal.dart';

void main() {
  setUp(() => UnityReadySignal.ready.value = false);

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
}
