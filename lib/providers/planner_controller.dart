// lib/providers/planner_controller.dart
//
// 予定とメモの一覧を持ち、端末の通知を予約し直す。
//
// 【一覧が変わるきっかけ】
//   - この端末で手で足す・直す・消す（Edge が変えたあとの一覧を返す）
//   - ライムが予定を入れた・直した・消した（client_action の planner.added など）
//   - ほかの端末で変わった（Edge から planner.changed が届く → 読み直す）
//   - つながったとき（寝ている間に変わったかもしれないので読み直す）
//
// 変わるたびに、端末に保存して（電波が無くても一覧と通知が使えるように）、
// 通知を全部入れ直す。Windows では、時刻にライムが話す準備もし直す。
//
// 【タイマー】
// 知らせ方は予定と同じ（Windows は鳴る時刻にライムが話す、スマホは通知を押したら話す）。
// 通知の「5分後にもう一回」が押されたら、この端末だけで5分後にもう1回出す。
// 「止める」は通知が消えるだけ。

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:raim_prototype/models/llm_response.dart';
import 'package:raim_prototype/models/planner_item.dart';
import 'package:raim_prototype/services/app_notifications.dart';
import 'package:raim_prototype/services/planner/planner_notifications.dart';
import 'package:raim_prototype/services/planner/planner_reminder_runner.dart';
import 'package:raim_prototype/services/planner/planner_schedule.dart';
import 'package:raim_prototype/services/planner/windows_lock_state.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/services/raim_server_service.dart'
    show RaimConnectionState;

/// ライムに予定の一言を話してもらう。話せたら true
typedef PlannerSpeak = Future<bool> Function(
  String itemId,
  String slot, {
  bool live,
});

class PlannerController extends ChangeNotifier {
  PlannerController({
    required PlannerService service,
    Stream<LLMResponse>? incoming,
    Stream<RaimConnectionState>? connection,
    PlannerNotifier? notifier,
    PlannerSpeak? speak,
    bool? liveReminders,
    bool Function()? isLocked,
    Stream<String>? notificationTaps,
    String? Function()? takeLaunchPayload,
    Stream<AppNotificationAction>? notificationActions,
    AppNotificationAction? Function()? takeLaunchAction,
    Future<void> Function()? requestPermission,
    DateTime Function()? clock,
  })  : _service = service,
        _notifier = notifier ?? PlannerNotifications(),
        _speak = speak,
        _clock = clock ?? DateTime.now,
        _requestPermission = requestPermission ?? AppNotifications.requestPermission {
    _incomingSub = incoming?.listen(_onIncoming);
    _connectionSub = connection?.listen((state) {
      if (state == RaimConnectionState.connected) unawaited(refresh());
    });
    _tapSub = (notificationTaps ?? AppNotifications.taps).listen(_onNotificationTap);
    _takeLaunchPayload = takeLaunchPayload ?? AppNotifications.takeLaunchPayload;
    _actionSub = (notificationActions ?? AppNotifications.actions).listen(_onNotificationAction);
    _takeLaunchAction = takeLaunchAction ?? AppNotifications.takeLaunchAction;
    final live = liveReminders ?? (!kIsWeb && Platform.isWindows);
    if (live && speak != null) {
      _runner = PlannerReminderRunner(
        notifier: _notifier,
        isLocked: isLocked ?? WindowsLockState.isLocked,
        clock: _clock,
        speak: (r) => speak(r.itemId, r.slot, live: true),
      );
    }
  }

  final PlannerService _service;
  final PlannerNotifier _notifier;
  final PlannerSpeak? _speak;
  final DateTime Function() _clock;
  final Future<void> Function() _requestPermission;
  late final String? Function() _takeLaunchPayload;
  late final AppNotificationAction? Function() _takeLaunchAction;
  PlannerReminderRunner? _runner;

  StreamSubscription<LLMResponse>? _incomingSub;
  StreamSubscription<RaimConnectionState>? _connectionSub;
  StreamSubscription<String>? _tapSub;
  StreamSubscription<AppNotificationAction>? _actionSub;

  static const String _cacheKey = 'planner.items';
  static const String _askedKey = 'planner.askedNotificationPermission';

  List<PlannerItem> _items = const [];
  bool _loading = false;
  bool _loaded = false;
  String? _error;
  int _generation = 0;
  Timer? _rescheduleTimer;

  /// 次のタイマーが鳴ったら一覧を描き直す（鳴ったタイマーを「動いている」から外す）
  Timer? _timerTick;

  /// 予定（日付の順）。終わって7日たったものはサーバーが返さない
  List<PlannerItem> get items => _items;
  List<PlannerItem> get events => _items.where((i) => i.isEvent).toList();

  /// 今日これからの予定があるか（朝のまとめに使う。日付だけの予定と、まだ始まっていない予定）
  bool hasUpcomingEventsToday() {
    final jst = _clock().toUtc().add(const Duration(hours: 9));
    final today = plannerDateString(jst);
    final clock = '${jst.hour.toString().padLeft(2, '0')}:${jst.minute.toString().padLeft(2, '0')}';
    return _items.any((i) => i.isEvent && i.date == today && (!i.hasTime || i.time.compareTo(clock) >= 0));
  }

  /// あとで聞くこと（日付の順）。「予定に入れる？」が押されなかったもの
  List<PlannerItem> get followUps =>
      _items.where((i) => i.isFollowUp).toList()..sort(PlannerItem.compare);

  /// メモ（新しい順）
  List<PlannerItem> get memos =>
      _items.where((i) => i.isMemo).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// リスト（作った順）
  List<PlannerItem> get lists =>
      _items.where((i) => i.isList).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  /// まだ鳴っていないタイマー（鳴る順）
  List<PlannerItem> get timers {
    final now = _clock().toUtc();
    return _items.where((i) => i.isRunningAt(now)).toList();
  }
  bool get isLoading => _loading;

  /// 一度でもサーバーか端末の保存から読めたか
  bool get isLoaded => _loaded;
  String? get error => _error;

  /// 端末に保存しておいた一覧を読み、通知を押して起動したならライムに話してもらう。
  Future<void> start() async {
    await _loadCache();
    final launch = _takeLaunchPayload();
    if (launch != null) _onNotificationTap(launch);
    final launchAction = _takeLaunchAction();
    if (launchAction != null) _onNotificationAction(launchAction);
  }

  /// サーバーから読み直す。失敗しても今の一覧は残す
  Future<void> refresh() async {
    final generation = _generation;
    _loading = true;
    notifyListeners();
    try {
      final items = await _service.fetchPlanner();
      if (generation != _generation) return;
      _error = null;
      await _setItems(items);
    } catch (e) {
      if (generation != _generation) return;
      RaimLog.d('[Planner] 読めませんでした: ${e.runtimeType}');
      _error = '読み込めませんでした';
    } finally {
      if (generation == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// 手で予定を足す。[source] は 'manual' か 'suggest'
  Future<PlannerItem?> addEvent({
    required String title,
    required String date,
    String time = '',
    String note = '',
    String source = 'manual',
    String followUpId = '',
  }) async {
    final before = _items.map((i) => i.itemId).toSet();
    final items = await _service.addPlannerEvent(
      title: title,
      date: date,
      time: time,
      note: note,
      source: source,
      followUpId: followUpId,
    );
    await _setItems(items);
    final added = items.where((i) => !before.contains(i.itemId));
    return added.isEmpty ? null : added.first;
  }

  /// 予定を直す（直すところだけ）
  Future<void> updateEvent(String itemId, Map<String, String> changes) async {
    await _setItems(await _service.updatePlannerEvent(itemId, changes));
  }

  /// メモを手で足す
  Future<void> addMemo(String text) async {
    await _setItems(await _service.addPlannerMemo(text));
  }

  /// リストを手で作る
  Future<void> addList(String title, {List<String> entries = const []}) async {
    await _setItems(await _service.addPlannerList(title, entries));
  }

  /// メモの文を直す
  Future<void> updateMemo(String itemId, String text) async {
    await _setItems(await _service.updatePlannerItem(itemId, {'text': text}));
  }

  /// リストの名前を直す
  Future<void> renameList(String itemId, String title) async {
    await _setItems(await _service.updatePlannerItem(itemId, {'title': title}));
  }

  /// リストの項目を入れ替える（足す・消す・チェック）。
  /// 押した感じが遅れないよう、先に画面を変えてからサーバーへ送る。失敗したら戻す。
  Future<void> setListEntries(String itemId, List<PlannerListEntry> entries) async {
    final before = _items;
    final index = _items.indexWhere((i) => i.itemId == itemId);
    if (index >= 0) {
      final next = [..._items];
      next[index] = next[index].copyWith(entries: entries);
      _items = List.unmodifiable(next);
      notifyListeners();
    }
    try {
      await _setItems(await _service.updatePlannerItem(itemId, {
        'entries': entries.map((e) => e.toJson()).toList(),
      }));
    } catch (_) {
      _items = before;
      notifyListeners();
      rethrow;
    }
  }

  /// リストの項目のチェックを付ける・外す
  Future<void> toggleEntry(String listId, String entryId, bool checked) async {
    final list = findItem(listId);
    if (list == null) return;
    await setListEntries(listId, [
      for (final e in list.entries) e.id == entryId ? e.withChecked(checked) : e,
    ]);
  }

  /// リストに項目を足す
  Future<void> addEntry(String listId, String text) async {
    final list = findItem(listId);
    final value = text.trim();
    if (list == null || value.isEmpty) return;
    await setListEntries(listId, [...list.entries, PlannerListEntry(id: '', text: value)]);
  }

  /// リストから項目を消す
  Future<void> removeEntries(String listId, Set<String> entryIds) async {
    final list = findItem(listId);
    if (list == null) return;
    await setListEntries(listId, list.entries.where((e) => !entryIds.contains(e.id)).toList());
  }

  /// 予定を消す
  Future<void> deleteItem(String itemId) async {
    await _setItems(await _service.deletePlannerItem(itemId));
  }

  PlannerItem? findItem(String itemId) {
    for (final item in _items) {
      if (item.itemId == itemId) return item;
    }
    return null;
  }

  /// ログアウトしたら、前の人の予定と通知を残さない
  Future<void> resetForSignOut() async {
    _generation++;
    _items = const [];
    _loaded = false;
    _error = null;
    _loading = false;
    _rescheduleTimer?.cancel();
    _timerTick?.cancel();
    _runner?.update(const []);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
    } catch (_) {
      // 消せなくても次のログインで上書きされる
    }
    await _notifier.clear();
  }

  // ──────────────────────────────────────────
  // サーバーから届くもの
  // ──────────────────────────────────────────

  void _onIncoming(LLMResponse response) {
    if (response.isPlannerChanged) {
      unawaited(refresh());
      return;
    }
    if (!response.isClientAction) return;
    final action = response.action;
    if (!action.startsWith('planner.')) return;
    final raw = response.actionParams['item'];
    if (raw is! Map) return;
    final item = PlannerItem.fromJson(raw.map((k, v) => MapEntry(k.toString(), v)));
    if (item.itemId.isEmpty) return;
    // ライムが予定を入れたら、同じことの「あとで聞くこと」はサーバーが消している
    final removed = response.actionParams['removedIds'] is List
        ? (response.actionParams['removedIds'] as List).whereType<String>().toSet()
        : const <String>{};
    final next = _items.where((i) => i.itemId != item.itemId && !removed.contains(i.itemId)).toList();
    if (action == 'planner.added' || action == 'planner.updated') {
      next.add(item);
    } else if (action == 'planner.suggest' && item.isFollowUp) {
      // 「予定に入れる？」を出したときに、サーバーが「あとで聞くこと」として持った
      next.add(item);
    } else if (action != 'planner.deleted') {
      return;
    }
    unawaited(_setItems(next));
  }

  void _onNotificationTap(String payload) {
    final parsed = PlannerReminder.parsePayload(payload);
    if (parsed == null) return;
    final speak = _speak;
    if (speak == null) return;
    // 「もう一回」の通知も、ライムにはタイマーとして話してもらう
    final slot = PlannerSlot.isTimer(parsed.slot) ? PlannerSlot.timer : parsed.slot;
    RaimLog.d('[Planner] 予定の通知が押されました: $slot');
    unawaited(speak(parsed.itemId, slot));
  }

  void _onNotificationAction(AppNotificationAction action) {
    final parsed = PlannerReminder.parsePayload(action.payload);
    if (parsed == null || !PlannerSlot.isTimer(parsed.slot)) return;
    if (action.actionId != AppNotifications.snoozeActionId) return;
    // 鳴って10分たつとサーバーの一覧から消えるので、無ければ決まり文句
    final item = findItem(parsed.itemId);
    final body = item != null && item.isTimer
        ? PlannerSchedule.timerBody(item)
        : 'タイマーの時間だよ';
    final now = _clock().toUtc();
    final reminder = PlannerSchedule.snoozeFor(
      PlannerReminder(
        id: PlannerSchedule.notificationId(parsed.itemId, parsed.slot),
        itemId: parsed.itemId,
        slot: parsed.slot,
        at: now,
        title: PlannerSchedule.notificationTitle,
        body: body,
      ),
      now,
    );
    RaimLog.d('[Planner] タイマーを5分後にもう一回鳴らします');
    unawaited(_notifier.snooze(reminder));
  }

  // ──────────────────────────────────────────
  // 一覧の入れ替えと、保存・通知
  // ──────────────────────────────────────────

  Future<void> _setItems(List<PlannerItem> items) async {
    final sorted = [...items]..sort(PlannerItem.compare);
    _items = List.unmodifiable(sorted);
    _loaded = true;
    notifyListeners();
    await _saveCache(sorted);
    _scheduleReschedule();
  }

  /// 続けて変わったときに何度も入れ直さないよう、少し待ってからまとめて入れ直す
  void _scheduleReschedule() {
    _rescheduleTimer?.cancel();
    _rescheduleTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(rescheduleNow());
    });
  }

  /// 通知を入れ直す（テストからも呼ぶ）
  @visibleForTesting
  Future<void> rescheduleNow() async {
    final now = _clock().toUtc();
    final reminders = PlannerSchedule.remindersForAll(_items, now);
    _runner?.update(reminders);
    _armTimerTick(now);
    if (reminders.isNotEmpty) await _askPermissionOnce();
    try {
      await _notifier.replaceAll(reminders);
    } catch (e) {
      RaimLog.w('[Planner] 通知を予約できませんでした: ${e.runtimeType}');
    }
  }

  void _armTimerTick(DateTime now) {
    _timerTick?.cancel();
    _timerTick = null;
    final running = timers;
    if (running.isEmpty) return;
    final wait = running.first.endsAt!.difference(now) + const Duration(seconds: 1);
    _timerTick = Timer(wait.isNegative ? Duration.zero : wait, () {
      notifyListeners();
      _armTimerTick(_clock().toUtc());
    });
  }

  /// 予定が入って初めて、通知の許可を聞く（起動直後にいきなり聞かない）
  Future<void> _askPermissionOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_askedKey) == true) return;
      await prefs.setBool(_askedKey, true);
      await _requestPermission();
    } catch (_) {
      // 聞けなくても予約は試す
    }
  }

  Future<void> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || _loaded) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final items = decoded
          .whereType<Map>()
          .map((m) => PlannerItem.fromJson(m.map((k, v) => MapEntry(k.toString(), v))))
          .where((i) => i.itemId.isNotEmpty)
          .toList()
        ..sort(PlannerItem.compare);
      if (_loaded) return;
      _items = List.unmodifiable(items);
      _loaded = true;
      notifyListeners();
      _scheduleReschedule();
    } catch (e) {
      RaimLog.d('[Planner] 保存しておいた一覧を読めませんでした: ${e.runtimeType}');
    }
  }

  Future<void> _saveCache(List<PlannerItem> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode(items.map((i) => i.toJson()).toList()),
      );
    } catch (_) {
      // 保存できなくても、画面と通知は動く
    }
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    _connectionSub?.cancel();
    _tapSub?.cancel();
    _actionSub?.cancel();
    _rescheduleTimer?.cancel();
    _timerTick?.cancel();
    _runner?.dispose();
    super.dispose();
  }
}
