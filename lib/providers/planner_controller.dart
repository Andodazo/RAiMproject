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
  PlannerReminderRunner? _runner;

  StreamSubscription<LLMResponse>? _incomingSub;
  StreamSubscription<RaimConnectionState>? _connectionSub;
  StreamSubscription<String>? _tapSub;

  static const String _cacheKey = 'planner.items';
  static const String _askedKey = 'planner.askedNotificationPermission';

  List<PlannerItem> _items = const [];
  bool _loading = false;
  bool _loaded = false;
  String? _error;
  int _generation = 0;
  Timer? _rescheduleTimer;

  /// 予定（日付の順）。終わって7日たったものはサーバーが返さない
  List<PlannerItem> get items => _items;
  List<PlannerItem> get events => _items.where((i) => i.isEvent).toList();
  bool get isLoading => _loading;

  /// 一度でもサーバーか端末の保存から読めたか
  bool get isLoaded => _loaded;
  String? get error => _error;

  /// 端末に保存しておいた一覧を読み、通知を押して起動したならライムに話してもらう。
  Future<void> start() async {
    await _loadCache();
    final launch = _takeLaunchPayload();
    if (launch != null) _onNotificationTap(launch);
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
  }) async {
    final before = _items.map((i) => i.itemId).toSet();
    final items = await _service.addPlannerEvent(
      title: title,
      date: date,
      time: time,
      note: note,
      source: source,
    );
    await _setItems(items);
    final added = items.where((i) => !before.contains(i.itemId));
    return added.isEmpty ? null : added.first;
  }

  /// 予定を直す（直すところだけ）
  Future<void> updateEvent(String itemId, Map<String, String> changes) async {
    await _setItems(await _service.updatePlannerEvent(itemId, changes));
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
    final next = _items.where((i) => i.itemId != item.itemId).toList();
    if (action == 'planner.added' || action == 'planner.updated') {
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
    RaimLog.d('[Planner] 予定の通知が押されました: ${parsed.slot}');
    unawaited(speak(parsed.itemId, parsed.slot));
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
    final reminders = PlannerSchedule.remindersForAll(_items, _clock().toUtc());
    _runner?.update(reminders);
    if (reminders.isNotEmpty) await _askPermissionOnce();
    try {
      await _notifier.replaceAll(reminders);
    } catch (e) {
      RaimLog.w('[Planner] 通知を予約できませんでした: ${e.runtimeType}');
    }
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
    _rescheduleTimer?.cancel();
    _runner?.dispose();
    super.dispose();
  }
}
