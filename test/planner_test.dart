// 予定とメモ（機能1）: 通知の時刻・一覧の同期・Windows の一言・チャットのカード。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/models/message.dart';
import 'package:raim_prototype/models/planner_card.dart';
import 'package:raim_prototype/models/planner_item.dart';
import 'package:raim_prototype/providers/chat_provider.dart';
import 'package:raim_prototype/providers/planner_controller.dart';
import 'package:raim_prototype/services/app_notifications.dart';
import 'package:raim_prototype/services/llm_service.dart';
import 'package:raim_prototype/services/planner/device_calendar.dart';
import 'package:raim_prototype/services/planner/planner_notifications.dart';
import 'package:raim_prototype/services/planner/planner_reminder_runner.dart';
import 'package:raim_prototype/services/planner/planner_schedule.dart';
import 'package:raim_prototype/widgets/planner_card_view.dart';
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

  final List<PlannerReminder> snoozed = [];

  @override
  Future<void> snooze(PlannerReminder reminder) async => snoozed.add(reminder);

  @override
  Future<void> clear() async => scheduled = [];
}

class FakePlannerService implements PlannerService {
  List<PlannerItem> items = [];
  String lastFollowUpId = '';
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
    String followUpId = '',
  }) async {
    lastFollowUpId = followUpId;
    items = [
      ...items.where((i) => i.itemId != followUpId),
      PlannerItem(itemId: 'ev_new0000aa', kind: 'event', title: title, date: date, time: time, source: source),
    ];
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

  final List<Map<String, dynamic>> itemUpdates = [];
  bool failUpdates = false;

  @override
  Future<List<PlannerItem>> addPlannerMemo(String text) async {
    items = [...items, PlannerItem(itemId: 'mm_new0000aa', kind: 'memo', title: '', date: '', text: text)];
    return items;
  }

  @override
  Future<List<PlannerItem>> addPlannerList(String title, List<String> entries) async {
    items = [
      ...items,
      PlannerItem(
        itemId: 'ls_new0000aa',
        kind: 'list',
        title: title,
        date: '',
        entries: [for (var i = 0; i < entries.length; i++) PlannerListEntry(id: 'e0000000$i', text: entries[i])],
      ),
    ];
    return items;
  }

  @override
  Future<List<PlannerItem>> updatePlannerItem(String itemId, Map<String, dynamic> changes) async {
    itemUpdates.add(changes);
    if (failUpdates) throw StateError('offline');
    items = [
      for (final i in items)
        if (i.itemId == itemId)
          i.copyWith(
            text: changes['text'] as String?,
            title: changes['title'] as String?,
            entries: changes['entries'] is List
                ? [
                    for (final (n, e) in (changes['entries'] as List).indexed)
                      PlannerListEntry.fromJson({
                        ...(e as Map<String, dynamic>),
                        if ((e['id'] ?? '') == '') 'id': 'enew$n',
                      }),
                  ]
                : null,
          )
        else
          i,
    ];
    return items;
  }
}

class BriefLlm extends ScriptedLlm implements GreetingService, BriefService {
  BriefLlm() : super(const []);

  int briefs = 0;
  int greetings = 0;

  @override
  Stream<LLMResponse> sendGreeting({String? threadId}) async* {
    greetings++;
  }

  @override
  Stream<LLMResponse> sendBrief({String? threadId}) async* {
    briefs++;
    for (final raw in const [
      {'type': 'metadata'},
      {
        'type': 'client_action', 'action': 'planner.show', 'actionId': 'b1',
        'params': {
          'brief': true,
          'items': [
            {'itemId': 'ev_1', 'kind': 'event', 'title': 'バイト', 'date': '2026-11-11', 'time': '15:00'},
          ],
        },
      },
      {'type': 'text_chunk', 'text': '今日は15時からバイトだね'},
      {'type': 'chat_end', 'full_text': '今日は15時からバイトだね'},
    ]) {
      yield LLMResponse.fromJson(raw);
    }
  }
}

/// 本物の RaimServerService と同じく、届いたものを全部 incomingStream にも流す会話サービス
class PushLlm extends ScriptedLlm implements ServerPushService {
  PushLlm(super.script);

  final StreamController<LLMResponse> incoming = StreamController<LLMResponse>.broadcast();

  @override
  Stream<LLMResponse> get incomingStream => incoming.stream;

  @override
  Stream<LLMResponse> sendMessage(
    String userInput, {
    List<Message> history = const [],
    List<Map<String, dynamic>>? images,
    String? requestId,
    String? threadId,
  }) async* {
    await for (final response in super.sendMessage(userInput, history: history, images: images)) {
      incoming.add(response);
      yield response;
    }
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

  group('タイマー', () {
    PlannerItem timer(String id, {int minutes = 3, String title = 'タイマー'}) => PlannerItem(
          itemId: id,
          kind: 'timer',
          title: title,
          date: '',
          durationSec: minutes * 60,
          endsAt: now.toUtc().add(Duration(minutes: minutes)),
        );

    test('サーバーの形を読めて、鳴る時刻と長さを出せる', () {
      final item = PlannerItem.fromJson({
        'itemId': 'tm_abcdef12',
        'kind': 'timer',
        'title': 'パスタ',
        'durationSec': 90,
        'endsAt': '2026-11-11T06:03:00.000Z',
      });
      expect(item.isTimer, isTrue);
      expect(item.whenLabel, '15:03 に鳴る');
      expect(item.durationLabel, '1分30秒');
      expect(formatTimerDuration(5400), '1時間30分');
      expect(PlannerItem.fromJson(item.toJson()).endsAt, item.endsAt);
    });

    test('鳴る時刻に1回だけ知らせる。本文は長さと名前から作る', () {
      final plain = PlannerSchedule.remindersFor(timer('tm_1'), now.toUtc());
      expect(plain.single.slot, 'timer');
      expect(plain.single.isTimer, isTrue);
      expect(plain.single.body, '3分たったよ');
      final named = PlannerSchedule.remindersFor(timer('tm_2', title: 'パスタ'), now.toUtc());
      expect(named.single.body, 'パスタの時間だよ（3分のタイマー）');
      final past = timer('tm_3', minutes: -1);
      expect(PlannerSchedule.remindersFor(past, now.toUtc()), isEmpty);
      expect(PlannerReminder.parsePayload('planner:tm_1:snooze')?.slot, 'snooze');
    });

    test('Windows のボタンの返事を、本文の押しとボタンに分ける', () {
      expect(AppNotifications.parseResponse('planner:tm_1:timer', 'planner:tm_1:timer'),
          (payload: 'planner:tm_1:timer', actionId: null));
      expect(AppNotifications.parseResponse('planner:tm_1:timer#snooze', 'planner:tm_1:timer#snooze'),
          (payload: 'planner:tm_1:timer', actionId: 'snooze'));
      expect(AppNotifications.parseResponse('planner:tm_1:timer', 'stop'),
          (payload: 'planner:tm_1:timer', actionId: 'stop'));
      expect(AppNotifications.parseResponse('planner:tm_1:timer', null),
          (payload: 'planner:tm_1:timer', actionId: null));
    });

    test('通知を押したらライムが話す。「5分後にもう一回」でこの端末だけもう1回鳴らす', () async {
      final notifier = FakeNotifier();
      final taps = StreamController<String>.broadcast();
      final actions = StreamController<AppNotificationAction>.broadcast();
      final spoken = <String>[];
      final service = FakePlannerService()..items = [timer('tm_a', title: 'パスタ')];
      final controller = PlannerController(
        service: service,
        notifier: notifier,
        notificationTaps: taps.stream,
        takeLaunchPayload: () => null,
        notificationActions: actions.stream,
        takeLaunchAction: () => null,
        requestPermission: () async {},
        speak: (itemId, slot, {live = false}) async {
          spoken.add(slot);
          return true;
        },
        liveReminders: false,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.timers.single.itemId, 'tm_a');
      expect(controller.events, isEmpty);
      await controller.rescheduleNow();
      expect(notifier.scheduled.single.slot, 'timer');

      taps.add('planner:tm_a:timer');
      taps.add('planner:tm_a:snooze');
      actions.add(const AppNotificationAction(payload: 'planner:tm_a:timer', actionId: 'stop'));
      actions.add(const AppNotificationAction(payload: 'planner:tm_a:timer', actionId: 'snooze'));
      await Future<void>.delayed(Duration.zero);
      expect(spoken, ['timer', 'timer']);
      final snooze = notifier.snoozed.single;
      expect(snooze.slot, 'snooze');
      expect(snooze.at, now.toUtc().add(const Duration(minutes: 5)));
      expect(snooze.body, 'パスタの時間だよ（3分のタイマー）');
      expect(snooze.id, isNot(notifier.scheduled.single.id));
      await taps.close();
      await actions.close();
    });

    test('Windows ではタイマーも、鳴る時刻にライムが話す（予定より遅く、ぎりぎりに動く）', () async {
      final notifier = FakeNotifier();
      final spoken = <String>[];
      final controller = PlannerController(
        service: FakePlannerService()
          ..items = [
            // 2秒後に鳴るタイマー
            PlannerItem(
              itemId: 'tm_a',
              kind: 'timer',
              title: 'タイマー',
              date: '',
              durationSec: 60,
              endsAt: now.toUtc().add(const Duration(seconds: 2)),
            ),
            event('ev_a', '2026-11-11', time: '23:30'),
          ],
        notifier: notifier,
        notificationTaps: const Stream.empty(),
        takeLaunchPayload: () => null,
        notificationActions: const Stream.empty(),
        takeLaunchAction: () => null,
        requestPermission: () async {},
        speak: (itemId, slot, {live = false}) async {
          spoken.add('$itemId:$slot');
          return true;
        },
        liveReminders: true,
        isLocked: () => false,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.rescheduleNow();
      expect(notifier.scheduled.map((r) => r.slot), containsAll(['timer', 'before']));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(spoken, ['tm_a:timer']);
      expect(notifier.cancelled, [PlannerSchedule.notificationId('tm_a', 'timer')]);
      expect(PlannerReminderRunner.leadFor(notifier.scheduled.firstWhere((r) => r.isTimer)),
          PlannerReminderRunner.timerLead);
    });
  });

  group('メモ帳', () {
    PlannerItem shopping() => const PlannerItem(
          itemId: 'ls_aaaaaa00',
          kind: 'list',
          title: '買うもの',
          date: '',
          entries: [
            PlannerListEntry(id: 'e00000001', text: '牛乳'),
            PlannerListEntry(id: 'e00000002', text: '卵', checked: true, checkedAt: '2026-11-11T01:00:00Z'),
          ],
        );

    PlannerController build(FakePlannerService service) {
      final controller = PlannerController(
        service: service,
        notifier: FakeNotifier(),
        notificationTaps: const Stream.empty(),
        takeLaunchPayload: () => null,
        notificationActions: const Stream.empty(),
        takeLaunchAction: () => null,
        requestPermission: () async {},
        liveReminders: false,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('メモとリストを読めて、保存の形に戻せる。通知は予約しない', () {
      final item = PlannerItem.fromJson({
        'itemId': 'ls_1',
        'kind': 'list',
        'title': '買うもの',
        'entries': [
          {'id': 'e00000001', 'text': '牛乳', 'checked': false},
          {'id': 'e00000002', 'text': '卵', 'checked': true, 'checkedAt': '2026-11-11T01:00:00Z'},
          {'id': 'e00000003', 'text': ' '},
        ],
      });
      expect(item.isList, isTrue);
      expect(item.entries.map((e) => e.text), ['牛乳', '卵']);
      expect(item.openEntries.single.text, '牛乳');
      expect(PlannerItem.fromJson(item.toJson()).entries.last.checkedAt, '2026-11-11T01:00:00Z');
      final memo = PlannerItem.fromJson({'itemId': 'mm_1', 'kind': 'memo', 'text': '駐輪場は3階'});
      expect(memo.isMemo, isTrue);
      expect(PlannerSchedule.remindersForAll([item, memo], now.toUtc()), isEmpty);
    });

    test('チェック・項目の追加と削除は、先に画面を変えてから送る。失敗したら戻す', () async {
      final service = FakePlannerService()..items = [shopping()];
      final controller = build(service);
      await controller.refresh();
      expect(controller.lists.single.title, '買うもの');

      await controller.toggleEntry('ls_aaaaaa00', 'e00000001', true);
      expect(service.itemUpdates.last['entries'][0]['checked'], isTrue);
      expect(controller.lists.single.entries.first.checked, isTrue);

      // 外したチェックは、付けた時刻も送らない
      await controller.toggleEntry('ls_aaaaaa00', 'e00000002', false);
      expect((service.itemUpdates.last['entries'][1] as Map).containsKey('checkedAt'), isFalse);

      await controller.addEntry('ls_aaaaaa00', 'パン');
      expect(controller.lists.single.entries.map((e) => e.text), ['牛乳', '卵', 'パン']);
      expect((service.itemUpdates.last['entries'][2] as Map).containsKey('id'), isFalse);

      service.failUpdates = true;
      await expectLater(controller.removeEntries('ls_aaaaaa00', {'e00000001'}), throwsStateError);
      expect(controller.lists.single.entries.length, 3);
    });

    test('ライムが「メモ何あったっけ」に答えたらメモのカード、リストに足したら足した分だけ取り消せるカード', () async {
      final llm = ScriptedLlm([
        {'type': 'metadata'},
        {
          'type': 'client_action', 'action': 'planner.updated', 'actionId': 'a1',
          'params': {
            'item': shopping().toJson(),
            'addedEntryIds': ['e00000001'],
          },
        },
        {
          'type': 'client_action', 'action': 'planner.show', 'actionId': 'a2',
          'params': {
            'items': [
              {'itemId': 'mm_1', 'kind': 'memo', 'text': '駐輪場は3階'},
            ],
          },
        },
        {'type': 'text_chunk', 'text': '入れたよ'},
        {'type': 'chat_end', 'full_text': '入れたよ'},
      ]);
      final chat = ChatProvider(llm, FakeUnity(), audioQueue: FakeAudioQueue(), clock: () => now);
      addTearDown(chat.dispose);
      await chat.sendUserMessage('買うものに牛乳足して');
      final cards = chat.messages.map((m) => m.plannerCard).whereType<PlannerCard>().toList();
      expect(cards.length, 2);
      expect(cards[0].isListAddition, isTrue);
      expect(cards[0].addedEntryIds, ['e00000001']);
      expect(cards[1].type, PlannerCardType.show);
      expect(cards[1].isActionable, isFalse);
      expect(cards[1].showItems.single.text, '駐輪場は3階');
    });
  });

  group('メモ帳の画面', () {
    Future<(PlannerController, FakePlannerService)> pump(WidgetTester tester, Widget child) async {
      final service = FakePlannerService()
        ..items = [
          const PlannerItem(
            itemId: 'ls_aaaaaa00',
            kind: 'list',
            title: '買うもの',
            date: '',
            entries: [PlannerListEntry(id: 'e00000001', text: '牛乳')],
          ),
          const PlannerItem(itemId: 'mm_1', kind: 'memo', title: '', date: '', text: '駐輪場は3階'),
        ];
      final controller = PlannerController(
        service: service,
        notifier: FakeNotifier(),
        notificationTaps: const Stream.empty(),
        takeLaunchPayload: () => null,
        notificationActions: const Stream.empty(),
        takeLaunchAction: () => null,
        requestPermission: () async {},
        liveReminders: false,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider.value(value: controller, child: child),
        ),
      ));
      await tester.pump();
      return (controller, service);
    }

    testWidgets('メモタブにメモとリストが出て、チェックできる', (tester) async {
      final (controller, service) = await pump(
        tester,
        const PlannerPanel(initialTab: PlannerTab.memo, swipeToDelete: false),
      );
      expect(find.text('駐輪場は3階'), findsOneWidget);
      expect(find.text('買うもの'), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(controller.lists.single.entries.single.checked, isTrue);
      expect(service.itemUpdates, hasLength(1));
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('メモのカードはリストをその場でチェックできる', (tester) async {
      final list = PlannerItem.fromJson({
        'itemId': 'ls_aaaaaa00', 'kind': 'list', 'title': '買うもの',
        'entries': [{'id': 'e00000001', 'text': '牛乳'}],
      });
      final (controller, _) = await pump(
        tester,
        PlannerCardView(card: PlannerCard.show([list], at: now)),
      );
      expect(find.text('買うもの'), findsOneWidget);
      expect(find.text('牛乳'), findsOneWidget);
      await tester.tap(find.text('牛乳'));
      await tester.pump();
      expect(controller.lists.single.entries.single.checked, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  // 2026-11-13: スマホの「カレンダーにも入れる」
  group('カレンダーにも入れる', () {
    test('時刻のある予定は日本時間で1時間、日付だけなら終日', () {
      final timed = deviceCalendarEntryFor(
        const PlannerItem(itemId: 'ev_1', kind: 'event', title: '面接', date: '2026-11-14', time: '10:00', note: 'スーツ'),
      )!;
      expect(timed.title, '面接');
      expect(timed.description, 'スーツ');
      expect(timed.allDay, isFalse);
      expect(timed.start, DateTime.utc(2026, 11, 14, 1, 0));
      expect(timed.end, DateTime.utc(2026, 11, 14, 2, 0));

      final allDay = deviceCalendarEntryFor(event('ev_2', '2026-11-15'))!;
      expect(allDay.allDay, isTrue);
      expect([allDay.start.year, allDay.start.month, allDay.start.day], [2026, 11, 15]);
      expect(allDay.end, allDay.start);

      expect(deviceCalendarEntryFor(event('ev_3', 'あした')), isNull);
    });

    testWidgets('「入れたよ」のカードに出る。取り消したら・タイマー・Windows では出ない', (tester) async {
      Future<void> show(PlannerCard card, {bool compact = false}) => tester.pumpWidget(MaterialApp(
            home: Scaffold(body: PlannerCardView(card: card, compact: compact, showCalendarButton: true)),
          ));
      final added = PlannerCard.added(event('ev_1', '2026-11-14', time: '10:00', title: '面接'), at: now);
      await show(added);
      expect(find.text('カレンダーにも入れる'), findsOneWidget);

      await show(added.withState(PlannerCardState.undone));
      expect(find.text('カレンダーにも入れる'), findsNothing);

      await show(added, compact: true);
      expect(find.text('カレンダーにも入れる'), findsNothing);

      final timer = PlannerItem.fromJson(const {
        'itemId': 'tm_1', 'kind': 'timer', 'title': 'タイマー', 'endsAt': '2026-11-11T02:33:00Z', 'durationSec': 180,
      });
      await show(PlannerCard.added(timer, at: now));
      expect(find.text('カレンダーにも入れる'), findsNothing);

      // 「予定に入れる？」は、入れたあとに出る
      final suggest = PlannerCard.suggest(const PlannerCandidate(title: '映画', date: '2026-11-14'), at: now);
      await show(suggest);
      expect(find.text('カレンダーにも入れる'), findsNothing);
      await show(suggest.withState(PlannerCardState.accepted));
      expect(find.text('カレンダーにも入れる'), findsOneWidget);

      // テストの端末（スマホではない）では、省略すると出ない
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PlannerCardView(card: added))));
      expect(find.text('カレンダーにも入れる'), findsNothing);
    });
  });

  group('朝のまとめ', () {
    test('今日これからの予定があるか（過ぎた時刻の予定は数えない）', () async {
      final service = FakePlannerService()..items = [event('ev_a', '2026-11-11', time: '09:00')];
      final controller = PlannerController(
        service: service,
        notifier: FakeNotifier(),
        notificationTaps: const Stream.empty(),
        takeLaunchPayload: () => null,
        notificationActions: const Stream.empty(),
        takeLaunchAction: () => null,
        requestPermission: () async {},
        liveReminders: false,
        clock: () => now, // 11:30 JST
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.hasUpcomingEventsToday(), isFalse);
      service.items = [...service.items, event('ev_b', '2026-11-11')];
      await controller.refresh();
      expect(controller.hasUpcomingEventsToday(), isTrue);
    });

    test('その日はじめてで予定があれば、くじを引かずにまとめを頼む。2回目は頼まない', () async {
      final llm = BriefLlm();
      ChatProvider build() => ChatProvider(
            llm,
            FakeUnity(),
            audioQueue: FakeAudioQueue(),
            clock: () => now,
            greetOnLaunchEnabled: () => true,
            greetDice: () => 0.99, // くじは外れ
            hasPlansToday: () => true,
          );
      final first = build();
      addTearDown(first.dispose);
      await first.greetOnLaunch();
      expect(llm.briefs, 1);
      expect(llm.greetings, 0);
      final card = first.messages.last.plannerCard!;
      expect(card.type, PlannerCardType.show);
      expect(card.showItems.single.title, 'バイト');

      final second = build();
      addTearDown(second.dispose);
      await second.greetOnLaunch();
      expect(llm.briefs, 1);
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

    // 2026-11-13: サーバーは返事の終わりを先に送り、「予定に入れる？」はそのあとに送るようにした
    test('返事の終わりのあとに届いた「予定に入れる？」も、返事のあとにカードで出る', () async {
      final llm = PushLlm(const [
        {'type': 'metadata'},
        {'type': 'text_chunk', 'text': 'いいね'},
        {'type': 'chat_end', 'full_text': 'いいね'},
      ]);
      final chat = ChatProvider(llm, FakeUnity(), audioQueue: FakeAudioQueue(), clock: () => now);
      addTearDown(chat.dispose);
      await chat.sendUserMessage('土曜に映画なんだ');
      expect(chat.isLoading, isFalse);
      expect(chat.messages.where((m) => m.plannerCard != null), isEmpty);

      llm.incoming.add(LLMResponse.fromJson(const {
        'type': 'client_action', 'action': 'planner.suggest', 'actionId': 'r1_action_0',
        'params': {'candidate': {'title': '映画', 'date': '2026-11-14'}},
      }));
      await Future<void>.delayed(Duration.zero);
      expect(chat.messages.map((m) => m.plannerCard == null ? m.text : 'card'), ['土曜に映画なんだ', 'いいね', 'card']);
      expect(chat.messages.last.plannerCard!.type, PlannerCardType.suggest);
    });

    test('返事の途中に届いた操作は、受信が2つの道で届いてもカードは1つ', () async {
      final llm = PushLlm(const [
        {'type': 'metadata'},
        {
          'type': 'client_action', 'action': 'planner.added', 'actionId': 'r2_action_0',
          'params': {'item': {'itemId': 'ev_1', 'kind': 'event', 'title': '面接', 'date': '2026-11-14', 'time': '10:00'}},
        },
        {'type': 'text_chunk', 'text': '入れといたよ'},
        {'type': 'chat_end', 'full_text': '入れといたよ'},
      ]);
      final chat = ChatProvider(llm, FakeUnity(), audioQueue: FakeAudioQueue(), clock: () => now);
      addTearDown(chat.dispose);
      await chat.sendUserMessage('金曜10時に面接入れといて');
      await Future<void>.delayed(Duration.zero);
      // カードは返事より前に出ない
      expect(chat.messages.map((m) => m.plannerCard == null ? m.text : 'card'), ['金曜10時に面接入れといて', '入れといたよ', 'card']);
    });

    // 2026-11-13: カードは次に送ったら消す（会話の記録にも残さない）
    test('次のメッセージを送ったら、前のカードは消える（Windows の入力欄の上からも）', () async {
      final llm = ScriptedLlm.sequence(const [
        [
          {'type': 'metadata'},
          {
            'type': 'client_action', 'action': 'planner.added', 'actionId': 'c1',
            'params': {'item': {'itemId': 'ev_1', 'kind': 'event', 'title': '面接', 'date': '2026-11-14', 'time': '10:00'}},
          },
          {'type': 'text_chunk', 'text': '入れといたよ'},
          {'type': 'chat_end', 'full_text': '入れといたよ'},
        ],
        [
          {'type': 'metadata'},
          {'type': 'text_chunk', 'text': 'がんばってね'},
          {'type': 'chat_end', 'full_text': 'がんばってね'},
        ],
      ]);
      final chat = ChatProvider(llm, FakeUnity(), audioQueue: FakeAudioQueue(), clock: () => now);
      addTearDown(chat.dispose);
      await chat.sendUserMessage('金曜10時に面接入れといて');
      final card = chat.activePlannerCard!;
      expect(chat.messages.where((m) => m.plannerCard != null), hasLength(1));

      await chat.sendUserMessage('緊張する');
      expect(chat.messages.map((m) => m.plannerCard == null ? m.text : 'card'),
          ['金曜10時に面接入れといて', '入れといたよ', '緊張する', 'がんばってね']);
      expect(chat.activePlannerCard, isNull);
      // 消えたカードを押しても何も起きない
      expect(chat.updatePlannerCard(card, PlannerCardState.undone), isNull);
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

  group('あとで聞くこと', () {
    PlannerController build(FakePlannerService service, {StreamController<LLMResponse>? incoming}) {
      final controller = PlannerController(
        service: service,
        incoming: incoming?.stream,
        notifier: FakeNotifier(),
        notificationTaps: const Stream.empty(),
        takeLaunchPayload: () => null,
        notificationActions: const Stream.empty(),
        takeLaunchAction: () => null,
        requestPermission: () async {},
        liveReminders: false,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    const followUp = {
      'itemId': 'fu_1', 'kind': 'followup', 'title': 'テスト', 'date': '2026-11-12', 'importance': 'normal',
    };

    test('「予定に入れる？」が出たら、あとで聞くことに入る（予定には入らない、通知もしない）', () async {
      final incoming = StreamController<LLMResponse>.broadcast();
      final controller = build(FakePlannerService(), incoming: incoming);
      incoming.add(LLMResponse.fromJson({
        'type': 'client_action', 'action': 'planner.suggest',
        'params': {
          'candidate': {'title': 'テスト', 'date': '2026-11-12', 'followUpId': 'fu_1'},
          'item': followUp,
        },
      }));
      await Future<void>.delayed(Duration.zero);
      expect(controller.followUps.single.itemId, 'fu_1');
      expect(controller.events, isEmpty);
      expect(PlannerSchedule.remindersForAll(controller.items, now.toUtc()), isEmpty);

      // ライムが同じことを予定に入れたら、あとで聞くことは消える
      incoming.add(LLMResponse.fromJson({
        'type': 'client_action', 'action': 'planner.added',
        'params': {
          'item': {'itemId': 'ev_x', 'kind': 'event', 'title': 'テスト', 'date': '2026-11-12'},
          'removedIds': ['fu_1'],
        },
      }));
      await Future<void>.delayed(Duration.zero);
      expect(controller.followUps, isEmpty);
      expect(controller.events.single.itemId, 'ev_x');
      await incoming.close();
    });

    test('候補は followUpId を持ち、入れるときにサーバーへ渡す', () async {
      final candidate = PlannerCandidate.fromJson({'title': 'テスト', 'date': '2026-11-12', 'followUpId': 'fu_1'})!;
      expect(candidate.followUpId, 'fu_1');
      final service = FakePlannerService()..items = [PlannerItem.fromJson(followUp)];
      final controller = build(service);
      await controller.refresh();
      await controller.addEvent(
        title: candidate.title, date: candidate.date, source: 'suggest', followUpId: candidate.followUpId,
      );
      expect(service.lastFollowUpId, 'fu_1');
      expect(controller.followUps, isEmpty);
      expect(controller.events.single.source, 'suggest');
    });

    testWidgets('予定の画面の下に小さく出て、消せる', (tester) async {
      final service = FakePlannerService()..items = [PlannerItem.fromJson(followUp)];
      final controller = build(service);
      await controller.refresh();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider.value(
            value: controller,
            child: const PlannerPanel(swipeToDelete: false),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('あとで聞くこと'), findsOneWidget);
      expect(find.text('テスト'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.pump();
      expect(controller.followUps, isEmpty);
      expect(find.text('あとで聞くこと'), findsNothing);
      await tester.pump(const Duration(milliseconds: 400));
    });
  });
}
