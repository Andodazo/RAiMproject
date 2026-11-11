// 予定とメモ（機能1）: 通知の時刻・一覧の同期・Windows の一言・チャットのカード。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/models/planner_card.dart';
import 'package:raim_prototype/models/planner_item.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/providers/planner_controller.dart';
import 'package:raim_prototype/services/llm_service.dart';
import 'package:raim_prototype/services/planner/planner_notifications.dart';
import 'package:raim_prototype/services/planner/planner_reminder_runner.dart';
import 'package:raim_prototype/services/planner/planner_schedule.dart';
import 'package:raim_prototype/widgets/planner_panel.dart';

import 'review/support/fakes.dart';

// 2026-11-11 11:30 JST
final now = DateTime.utc(2026, 11, 11, 2, 30);

PlannerItem event(
  String id,
  String date, {
  String time = '',
  String title = '歯医者',
  Map<String, String> lines = const {},
}) =>
    PlannerItem(itemId: id, kind: 'event', title: title, date: date, time: time, lines: lines);

class FakeNotifier implements PlannerNotifier {
  List<PlannerReminder> scheduled = [];
  final List<int> cancelled = [];
  final List<int> shown = [];
  int replaced = 0;

  @override
  Future<void> replaceAll(List<PlannerReminder> reminders) async {
    replaced++;
    scheduled = reminders;
  }

  @override
  Future<void> cancel(PlannerReminder reminder) async => cancelled.add(reminder.id);

  @override
  Future<void> showNow(PlannerReminder reminder) async => shown.add(reminder.id);

  @override
  Future<void> clear() async => scheduled = [];
}

class FakePlannerService implements PlannerService {
  List<PlannerItem> items = [];
  int fetches = 0;

  @override
  Future<List<PlannerItem>> fetchPlanner() async {
    fetches++;
    return items;
  }

  @override
  Future<List<PlannerItem>> addPlannerEvent({
    required String title,
    required String date,
    String time = '',
    String note = '',
    String source = 'manual',
  }) async {
    items = [...items, PlannerItem(itemId: 'ev_new0000aa', kind: 'event', title: title, date: date, time: time, source: source)];
    return items;
  }

  @override
  Future<List<PlannerItem>> updatePlannerEvent(String itemId, Map<String, String> changes) async {
    items = [
      for (final i in items)
        if (i.itemId == itemId)
          PlannerItem(itemId: i.itemId, kind: 'event', title: changes['title'] ?? i.title, date: changes['date'] ?? i.date, time: changes['time'] ?? i.time)
        else
          i,
    ];
    return items;
  }

  @override
  Future<List<PlannerItem>> deletePlannerItem(String itemId) async {
    items = items.where((i) => i.itemId != itemId).toList();
    return items;
  }
}

class ReminderLlm extends ScriptedLlm implements GreetingService, ReminderService {
  ReminderLlm(super.script);

  final List<String> reminders = [];
  int greetings = 0;

  @override
  Stream<LLMResponse> sendGreeting({String? threadId}) async* {
    greetings++;
    yield LLMResponse.fromJson({'type': 'chat_end', 'full_text': 'やっほー'});
  }

  @override
  Stream<LLMResponse> sendReminder({required String itemId, required String slot, String? threadId}) async* {
    reminders.add('$itemId:$slot');
    for (final json in const [
      {'type': 'text_chunk', 'text': 'このあと15時に歯医者だよ'},
      {'type': 'chat_end', 'full_text': 'このあと15時に歯医者だよ'},
    ]) {
      await Future<void>.delayed(Duration.zero);
      yield LLMResponse.fromJson(json);
    }
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('予定の形', () {
    test('日付と時刻を読める', () {
      expect(formatPlannerDate('2026-11-14'), '11/14(土)');
      expect(isPlannerDate('2026-02-30'), isFalse);
      expect(normalizePlannerTime('9:05'), '09:05');
      expect(normalizePlannerTime('10時'), '10:00');
      expect(normalizePlannerTime('１０：３０'), '10:30');
      expect(normalizePlannerTime(''), '');
      expect(normalizePlannerTime('25:00'), isNull);
      final item = PlannerItem.fromJson({
        'itemId': 'ev_1', 'title': '面接', 'date': '2026-11-14', 'time': '10:00',
        'lines': {'eve': '準備できてる？', 'junk': 1}, 'enriched': true,
      });
      expect(item.whenLabel, '11/14(土) 10:00');
      expect(item.lines, {'eve': '準備できてる？'});
      expect(PlannerCandidate.fromJson({'title': 'x', 'date': '来週'}), isNull);
    });

    test('編集で変わったところだけ送る', () {
      final item = event('ev_1', '2026-11-14', time: '10:00');
      const draft = PlannerDraft(title: '歯医者', date: '2026-11-14', time: '16:30');
      expect(draft.changesFrom(item), {'time': '16:30'});
    });
  });

  group('知らせる時刻', () {
    test('時刻のある予定は前の日の21時と1時間前（日本時間）', () {
      final r = PlannerSchedule.remindersFor(event('ev_1', '2026-11-14', time: '10:00'), now);
      expect(r.map((x) => x.slot), [PlannerSlot.eve, PlannerSlot.before]);
      expect(r[0].at, DateTime.utc(2026, 11, 13, 12)); // 11/13 21:00 JST
      expect(r[1].at, DateTime.utc(2026, 11, 14, 0)); // 11/14 09:00 JST
      expect(r[0].title, 'ライム');
      expect(r[0].body, '歯医者の準備、できてる？（明日 10:00 歯医者）');
      expect(r[1].body, 'そろそろ歯医者だよ。いってらっしゃい（10:00 歯医者）');
    });

    test('日付だけの予定は当日の朝8時。保存した文を使う', () {
      final r = PlannerSchedule.remindersFor(
        event('ev_2', '2026-11-12', lines: {'morning': 'ゴミの日だよ'}),
        now,
      );
      expect(r.single.slot, PlannerSlot.morning);
      expect(r.single.at, DateTime.utc(2026, 11, 11, 23)); // 11/12 08:00 JST
      expect(r.single.body, 'ゴミの日だよ（今日 歯医者）');
    });

    test('過ぎた時刻は予約しない', () {
      // 今日 12:00 の予定: 前の日の夜は過ぎていて、1時間前（11:00）も過ぎている
      expect(PlannerSchedule.remindersFor(event('ev_3', '2026-11-11', time: '12:00'), now), isEmpty);
      final later = PlannerSchedule.remindersFor(event('ev_4', '2026-11-11', time: '15:00'), now);
      expect(later.map((x) => x.slot), [PlannerSlot.before]);
    });

    test('通知の ID は同じ予定なら同じで、駅アラームと重ならない', () {
      final a = PlannerSchedule.notificationId('ev_1', 'eve');
      expect(a, PlannerSchedule.notificationId('ev_1', 'eve'));
      expect(a, isNot(PlannerSchedule.notificationId('ev_1', 'before')));
      expect(PlannerSchedule.isPlannerId(a), isTrue);
      expect(PlannerSchedule.isPlannerId(7201), isFalse);
      final r = PlannerSchedule.remindersFor(event('ev_1', '2026-11-14', time: '10:00'), now).first;
      expect(PlannerReminder.parsePayload(r.payload), (itemId: 'ev_1', slot: 'eve'));
      expect(PlannerReminder.parsePayload('station'), isNull);
    });
  });

  group('一覧と同期', () {
    PlannerController build(
      FakePlannerService service, {
      FakeNotifier? notifier,
      StreamController<LLMResponse>? incoming,
      StreamController<String>? taps,
      List<String>? spoken,
      String? launch,
    }) {
      final controller = PlannerController(
        service: service,
        incoming: incoming?.stream,
        notifier: notifier ?? FakeNotifier(),
        notificationTaps: (taps ?? StreamController<String>.broadcast()).stream,
        takeLaunchPayload: () => launch,
        requestPermission: () async {},
        speak: (itemId, slot, {live = false}) async {
          spoken?.add('$itemId:$slot:$live');
          return true;
        },
        liveReminders: false,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('読み直すと日付の順に並べて、通知を予約し直す', () async {
      final service = FakePlannerService()
        ..items = [event('ev_b', '2026-11-20'), event('ev_a', '2026-11-14', time: '10:00')];
      final notifier = FakeNotifier();
      final controller = build(service, notifier: notifier);
      await controller.refresh();
      expect(controller.events.map((e) => e.itemId), ['ev_a', 'ev_b']);
      await controller.rescheduleNow();
      expect(notifier.scheduled.map((r) => r.slot), ['eve', 'before', 'morning']);
    });

    test('ライムが入れた・消した予定と、ほかの端末の変更が反映される', () async {
      final service = FakePlannerService();
      final incoming = StreamController<LLMResponse>.broadcast();
      final controller = build(service, incoming: incoming);
      incoming.add(LLMResponse.fromJson({
        'type': 'client_action', 'action': 'planner.added',
        'params': {'item': {'itemId': 'ev_x', 'kind': 'event', 'title': '面接', 'date': '2026-11-14'}},
      }));
      await Future<void>.delayed(Duration.zero);
      expect(controller.events.single.title, '面接');

      incoming.add(LLMResponse.fromJson({
        'type': 'client_action', 'action': 'planner.deleted',
        'params': {'item': {'itemId': 'ev_x'}},
      }));
      await Future<void>.delayed(Duration.zero);
      expect(controller.events, isEmpty);

      service.items = [event('ev_y', '2026-11-15')];
      incoming.add(LLMResponse.fromJson({'type': 'planner.changed'}));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(service.fetches, 1);
      expect(controller.events.single.itemId, 'ev_y');
      await incoming.close();
    });

    test('通知を押したら（起動のときも）ライムに予定の一言を頼む', () async {
      final taps = StreamController<String>.broadcast();
      final spoken = <String>[];
      final controller = build(
        FakePlannerService(),
        taps: taps,
        spoken: spoken,
        launch: 'planner:ev_1:morning',
      );
      await controller.start();
      taps.add('planner:ev_2:before');
      taps.add('station');
      await Future<void>.delayed(Duration.zero);
      expect(spoken, ['ev_1:morning:false', 'ev_2:before:false']);
      await taps.close();
    });

    test('ログアウトしたら一覧と通知を消す', () async {
      final service = FakePlannerService()..items = [event('ev_a', '2026-11-14', time: '10:00')];
      final notifier = FakeNotifier();
      final controller = build(service, notifier: notifier);
      await controller.refresh();
      await controller.rescheduleNow();
      await controller.resetForSignOut();
      expect(controller.events, isEmpty);
      expect(notifier.scheduled, isEmpty);
    });
  });

  group('Windows で時刻が来たとき', () {
    final reminder = PlannerSchedule.remindersFor(event('ev_1', '2026-11-11', time: '15:00'), now).single;

    PlannerReminderRunner runner(FakeNotifier n, {bool locked = false, bool spoke = true, DateTime? at}) =>
        PlannerReminderRunner(
          notifier: n,
          isLocked: () => locked,
          speak: (_) async => spoke,
          clock: () => at ?? reminder.at,
        );

    test('話せたら予約した通知を取り消すだけ', () async {
      final n = FakeNotifier();
      await runner(n).fire(reminder);
      expect(n.cancelled, [reminder.id]);
      expect(n.shown, isEmpty);
    });

    test('話せなかったら保存しておいた文で通知を出す', () async {
      final n = FakeNotifier();
      await runner(n, spoke: false).fire(reminder);
      expect(n.shown, [reminder.id]);
    });

    test('ロック中や、時刻を大きく過ぎていたら喋らない（予約した通知に任せる）', () async {
      final locked = FakeNotifier();
      await runner(locked, locked: true).fire(reminder);
      expect(locked.cancelled, isEmpty);
      final late = FakeNotifier();
      await runner(late, at: reminder.at.add(const Duration(minutes: 10))).fire(reminder);
      expect(late.cancelled, isEmpty);
      expect(late.shown, isEmpty);
    });
  });

  group('チャットのカード', () {
    test('ライムが予定を入れたら、返事のあとに「入れたよ」カードが並ぶ', () async {
      final llm = ScriptedLlm(const [
        {'type': 'metadata'},
        {
          'type': 'client_action', 'action': 'planner.added', 'actionId': 'a1',
          'params': {'item': {'itemId': 'ev_1', 'kind': 'event', 'title': '面接', 'date': '2026-11-14', 'time': '10:00'}},
        },
        {'type': 'text_chunk', 'text': '入れといたよ'},
        {'type': 'chat_end', 'full_text': '入れといたよ'},
      ]);
      final chat = ChatProvider(llm, FakeUnity(), audioQueue: FakeAudioQueue(), clock: () => now);
      addTearDown(chat.dispose);
      await chat.sendUserMessage('金曜10時に面接入れといて');
      expect(chat.messages.map((m) => m.plannerCard == null ? m.text : 'card'), ['金曜10時に面接入れといて', '入れといたよ', 'card']);
      final card = chat.messages.last.plannerCard!;
      expect(card.type, PlannerCardType.added);
      expect(card.whenLabel, '11/14(土) 10:00');
      expect(chat.activePlannerCard, same(card));

      final busy = chat.updatePlannerCard(card, PlannerCardState.busy)!;
      chat.updatePlannerCard(busy, PlannerCardState.undone);
      expect(chat.messages.last.plannerCard!.state, PlannerCardState.undone);
    });

    test('返事が失敗したらカードは出さない。「予定に入れる？」も同じ流れで出る', () async {
      final failing = ScriptedLlm(const [
        {
          'type': 'client_action', 'action': 'planner.suggest', 'actionId': 'a2',
          'params': {'candidate': {'title': '歯医者', 'date': '2026-11-14'}},
        },
        {'type': 'error', 'text': 'だめ'},
      ]);
      final chat = ChatProvider(failing, FakeUnity(), audioQueue: FakeAudioQueue(), clock: () => now);
      addTearDown(chat.dispose);
      await chat.sendUserMessage('土曜歯医者なんだよね');
      expect(chat.messages.where((m) => m.plannerCard != null), isEmpty);

      final ok = ScriptedLlm(const [
        {
          'type': 'client_action', 'action': 'planner.suggest', 'actionId': 'a3',
          'params': {'candidate': {'title': '歯医者', 'date': '2026-11-14'}},
        },
        {'type': 'chat_end', 'full_text': 'がんばって'},
      ]);
      final chat2 = ChatProvider(ok, FakeUnity(), audioQueue: FakeAudioQueue(), clock: () => now);
      addTearDown(chat2.dispose);
      await chat2.sendUserMessage('土曜歯医者なんだよね');
      expect(chat2.messages.last.plannerCard!.type, PlannerCardType.suggest);
    });

    test('予定の一言を話したら、その回の話しかけはしない', () async {
      final llm = ReminderLlm(const []);
      final chat = ChatProvider(
        llm,
        FakeUnity(),
        audioQueue: FakeAudioQueue(),
        greetOnLaunchEnabled: () => true,
      );
      addTearDown(chat.dispose);
      final spoke = await chat.speakReminder('ev_1', 'before', live: true);
      expect(spoke, isTrue);
      expect(llm.reminders, ['ev_1:before']);
      expect(chat.messages.single.text, contains('歯医者'));
      await chat.greetOnLaunch();
      expect(llm.greetings, 0);
    });
  });
}
