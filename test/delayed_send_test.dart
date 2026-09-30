import 'package:flutter_test/flutter_test.dart';
import 'package:raim_prototype/providers/voice_settings_provider.dart';
import 'package:raim_prototype/services/voice/delayed_send.dart';

void main() {
  group('decideUtteranceAction', () {
    test('設定ごとに、すぐ送る・待って送る・入れるだけ', () {
      expect(
        decideUtteranceAction(canSend: true, mode: VoiceSendMode.immediate),
        UtteranceAction.sendNow,
      );
      expect(
        decideUtteranceAction(canSend: true, mode: VoiceSendMode.delayed),
        UtteranceAction.sendLater,
      );
      expect(
        decideUtteranceAction(canSend: true, mode: VoiceSendMode.manual),
        UtteranceAction.keep,
      );
    });

    test('書きかけや返事の生成中は、設定に関係なく入れるだけ', () {
      for (final mode in VoiceSendMode.values) {
        expect(
          decideUtteranceAction(canSend: false, mode: mode),
          UtteranceAction.keep,
        );
      }
    });
  });

  group('DelayedSend', () {
    // 本物のタイマーで確かめるので、待ち時間は短くしておく
    const delay = Duration(milliseconds: 60);
    Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

    test('待ち時間が過ぎたら送る', () async {
      final d = DelayedSend(delay: delay);
      var sent = 0;
      d.start(() => sent++);
      expect(d.isPending, isTrue);

      await wait(20);
      expect(sent, 0);

      await wait(80);
      expect(sent, 1);
      expect(d.isPending, isFalse);
      d.dispose();
    });

    test('取り消したら送らない', () async {
      final d = DelayedSend(delay: delay);
      var sent = 0;
      d.start(() => sent++);
      await wait(20);
      d.cancel();
      await wait(100);
      expect(sent, 0);
      expect(d.isPending, isFalse);
      d.dispose();
    });

    test('待っている途中にもう一度始めたら、待ち直して1回だけ送る', () async {
      final d = DelayedSend(delay: delay);
      var sent = 0;
      d.start(() => sent++);
      await wait(40);
      d.start(() => sent++);
      await wait(40);
      expect(sent, 0);
      await wait(60);
      expect(sent, 1);
      d.dispose();
    });
  });
}
