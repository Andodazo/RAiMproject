// lib/widgets/planner_panel.dart
//
// 予定とメモ。Windows の入力小窓とスマホの両方で同じものを使う。
//
// ライムに頼んだ予定と、手で入れた予定が日付の順に並ぶ（Windows とスマホで同じもの）。
// 押すと直せて、スマホは横にスワイプ、Windows はごみ箱で消せる。手で足すこともできる。
// 知らせる時刻は、前の日の夜と1時間前（時間が無ければ当日の朝）。
//
// 日付はダイアログを開かずに選ぶ（Windows の小窓ではダイアログが開きにくいため）。
//
// 上のタブで「予定」と「メモ」を切り替える。メモタブの中身は planner_memo_panel.dart。

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:raim_prototype/models/planner_item.dart';
import 'package:raim_prototype/providers/planner_controller.dart';
import 'package:raim_prototype/services/planner/device_calendar.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/widgets/planner_memo_panel.dart';
import 'package:raim_prototype/widgets/voice_settings_panel.dart';

/// 「予定とメモ」のタブ
enum PlannerTab { schedule, memo }

/// スマホではボトムシートで開く。
Future<void> showPlannerSheet(BuildContext context, {PlannerTab tab = PlannerTab.schedule}) {
  final planner = context.read<PlannerController>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xF2111418),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => ChangeNotifierProvider.value(
      value: planner,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Padding(
          // 文字を打つときにキーボードで隠れないように
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
              child: PlannerPanel(showTitle: true, initialTab: tab),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 日本時間の今日
String plannerTodayJst([DateTime? now]) => plannerDateString(
      (now ?? DateTime.now()).toUtc().add(const Duration(hours: 9)),
    );

class PlannerPanel extends StatefulWidget {
  const PlannerPanel({
    super.key,
    this.palette = VoiceSettingsPalette.dark,
    this.showTitle = false,
    this.fontScale = 1.0,
    this.swipeToDelete,
    this.initialTab = PlannerTab.schedule,
  });

  /// 開いたときのタブ
  final PlannerTab initialTab;

  final VoiceSettingsPalette palette;
  final bool showTitle;

  /// Windows の小窓では文字を少し小さくする。
  final double fontScale;

  /// スワイプで消すか（省略時はスマホだけ）
  final bool? swipeToDelete;

  @override
  State<PlannerPanel> createState() => _PlannerPanelState();
}

class _PlannerPanelState extends State<PlannerPanel> {
  /// 直している予定。新しく足すときは [_newKey]
  String? _editing;
  static const String _newKey = '__new__';

  /// 「消しますか？」と確かめている予定
  String? _confirming;

  bool _busy = false;
  String? _error;

  late PlannerTab _tab = widget.initialTab;

  VoiceSettingsPalette get _p => widget.palette;
  double get _fs => widget.fontScale;

  bool get _swipe =>
      widget.swipeToDelete ?? (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<PlannerController>().refresh();
    });
  }

  Future<void> _run(Future<void> Function() action, String failMessage) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      setState(() {
        _editing = null;
        _confirming = null;
      });
    } catch (e) {
      RaimLog.d('[PlannerPanel] $failMessage: ${e.runtimeType}');
      if (!mounted) return;
      setState(() => _error = failMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final planner = context.watch<PlannerController>();
    final today = plannerTodayJst();
    final events = planner.events;
    final upcoming = events.where((e) => e.date.compareTo(today) >= 0).toList();
    final past = events.where((e) => e.date.compareTo(today) < 0).toList();
    final timers = planner.timers;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      shrinkWrap: true,
      children: [
        if (widget.showTitle)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '予定とメモ',
              style: TextStyle(color: _p.text, fontSize: 16 * _fs, fontWeight: FontWeight.w600),
            ),
          ),
        _tabs(),
        if (_tab == PlannerTab.memo)
          PlannerMemoSection(palette: _p, fontScale: _fs)
        else
          ..._scheduleChildren(planner, events, upcoming, past, timers),
      ],
    );
  }

  Widget _tabs() {
    Widget tab(String label, PlannerTab value) {
      final selected = _tab == value;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(label, style: TextStyle(fontSize: 12 * _fs, color: selected ? _p.surface : _p.text)),
          selected: selected,
          showCheckmark: false,
          selectedColor: _p.accent,
          backgroundColor: Colors.transparent,
          side: BorderSide(color: selected ? _p.accent : _p.line),
          visualDensity: VisualDensity.compact,
          onSelected: (_) => setState(() {
            _tab = value;
            _editing = null;
            _confirming = null;
          }),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [tab('予定', PlannerTab.schedule), tab('メモ', PlannerTab.memo)]),
    );
  }

  List<Widget> _scheduleChildren(
    PlannerController planner,
    List<PlannerItem> events,
    List<PlannerItem> upcoming,
    List<PlannerItem> past,
    List<PlannerItem> timers,
  ) {
    return [
        _note('ライムに頼んだ予定と、手で入れた予定です。前の日の夜と1時間前'
            '（時間がなければ当日の朝）に知らせます。'),
        if (_editing == _newKey)
          _PlannerEditor(
            palette: _p,
            fontScale: _fs,
            busy: _busy,
            onCancel: () => setState(() => _editing = null),
            onSave: (draft) => _run(
              () async {
                await planner.addEvent(
                  title: draft.title,
                  date: draft.date,
                  time: draft.time,
                  note: draft.note,
                );
              },
              '入れられませんでした。もう一度試してください',
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => setState(() => _editing = _newKey),
              icon: Icon(Icons.add, size: 16, color: _p.accent),
              label: Text('予定を足す', style: TextStyle(color: _p.accent, fontSize: 13 * _fs)),
            ),
          ),
        if (_error != null) _note(_error!, color: _p.error),
        if (timers.isNotEmpty) ...[
          _label('タイマー'),
          ...timers.map((t) => _timerRow(t, planner)),
          Divider(color: _p.line, height: 17),
        ],
        if (!planner.isLoaded && planner.isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          )
        else if (!planner.isLoaded && planner.error != null)
          _retry(planner)
        else if (events.isEmpty)
          _note('まだ予定はありません。「金曜10時に面接、入れといて」のようにライムに頼むか、'
              '「予定を足す」から入れられます。')
        else ...[
          ..._grouped(upcoming, planner),
          if (past.isNotEmpty) ...[
            Divider(color: _p.line, height: 17),
            _label('終わった予定（7日たつと消えます）'),
            ...past.map((e) => _row(e, planner, dim: true)),
          ],
        ],
        if (planner.followUps.isNotEmpty) ...[
          Divider(color: _p.line, height: 17),
          _label('あとで聞くこと'),
          _note('話に出たけれど予定には入れなかったものです。終わったころにライムが「どうだった？」と'
              '聞くことがあります。7日たつと消えます。'),
          ...planner.followUps.map((f) => _followUpRow(f, planner)),
        ],
        const SizedBox(height: 8),
    ];
  }

  List<Widget> _grouped(List<PlannerItem> items, PlannerController planner) {
    final out = <Widget>[];
    String? lastDate;
    final today = plannerTodayJst();
    final tomorrow = plannerDateString(parsePlannerDate(today)!.add(const Duration(days: 1)));
    for (final item in items) {
      if (item.date != lastDate) {
        lastDate = item.date;
        final rel = item.date == today
            ? '今日 '
            : item.date == tomorrow
                ? '明日 '
                : '';
        out.add(_label('$rel${item.dateLabel}'));
      }
      out.add(_row(item, planner));
    }
    return out;
  }

  Widget _row(PlannerItem item, PlannerController planner, {bool dim = false}) {
    if (_editing == item.itemId) {
      return _PlannerEditor(
        palette: _p,
        fontScale: _fs,
        busy: _busy,
        initial: item,
        onCancel: () => setState(() => _editing = null),
        onSave: (draft) => _run(
          () async {
            final changes = draft.changesFrom(item);
            if (changes.isEmpty) return;
            await planner.updateEvent(item.itemId, changes);
          },
          '直せませんでした。もう一度試してください',
        ),
      );
    }

    final confirming = _confirming == item.itemId;
    final color = dim ? _p.muted : _p.text;
    final row = InkWell(
      onTap: _busy ? null : () => setState(() {
        _editing = item.itemId;
        _confirming = null;
      }),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 52 * _fs,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  dim ? item.dateLabel : (item.hasTime ? item.time : '終日'),
                  style: TextStyle(color: _p.muted, fontSize: 12 * _fs),
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title, style: TextStyle(color: color, fontSize: 13.5 * _fs, height: 1.35)),
                  if (item.note.isNotEmpty)
                    Text(item.note, style: TextStyle(color: _p.muted, fontSize: 11.5 * _fs, height: 1.35)),
                ],
              ),
            ),
            if (!_swipe)
              IconButton(
                tooltip: '消す',
                icon: const Icon(Icons.delete_outline, size: 16),
                color: _p.muted,
                splashRadius: 16,
                visualDensity: VisualDensity.compact,
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _confirming = confirming ? null : item.itemId;
                          _editing = null;
                        }),
              ),
          ],
        ),
      ),
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        if (confirming)
          _confirmRow(
            question: '「${item.title}」を消しますか？',
            onYes: () => _run(() => planner.deleteItem(item.itemId), '消せませんでした。もう一度試してください'),
          ),
      ],
    );
    if (!_swipe) return content;
    return Dismissible(
      key: ValueKey('planner-${item.itemId}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: _p.error.withValues(alpha: 0.25),
        child: Icon(Icons.delete_outline, color: _p.error),
      ),
      // 消せたときだけ行を消す（失敗したら戻す）
      confirmDismiss: (_) async {
        try {
          await planner.deleteItem(item.itemId);
          return true;
        } catch (e) {
          RaimLog.d('[PlannerPanel] 消せませんでした: ${e.runtimeType}');
          if (mounted) setState(() => _error = '消せませんでした。もう一度試してください');
          return false;
        }
      },
      child: content,
    );
  }

  /// 動いているタイマーの1行。消すとすぐ止まる（聞き返さない）
  Widget _timerRow(PlannerItem item, PlannerController planner) {
    Future<void> stop() => _run(
          () => planner.deleteItem(item.itemId),
          '止められませんでした。もう一度試してください',
        );
    final label = item.title.trim();
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 52 * _fs,
            child: Text(
              item.endsAt == null ? '' : formatJstClock(item.endsAt!),
              style: TextStyle(color: _p.muted, fontSize: 12 * _fs),
            ),
          ),
          Icon(Icons.timer_outlined, size: 15 * _fs, color: _p.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              [
                if (label.isNotEmpty && label != 'タイマー') label,
                if (item.durationLabel.isNotEmpty) '${item.durationLabel}のタイマー',
              ].join('・').ifEmpty('タイマー'),
              style: TextStyle(color: _p.text, fontSize: 13.5 * _fs, height: 1.35),
            ),
          ),
          if (!_swipe)
            IconButton(
              tooltip: '止める',
              icon: const Icon(Icons.delete_outline, size: 16),
              color: _p.muted,
              splashRadius: 16,
              visualDensity: VisualDensity.compact,
              onPressed: _busy ? null : stop,
            ),
        ],
      ),
    );
    if (!_swipe) return row;
    return Dismissible(
      key: ValueKey('planner-${item.itemId}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: _p.error.withValues(alpha: 0.25),
        child: Icon(Icons.delete_outline, color: _p.error),
      ),
      confirmDismiss: (_) async {
        try {
          await planner.deleteItem(item.itemId);
          return true;
        } catch (e) {
          RaimLog.d('[PlannerPanel] 止められませんでした: ${e.runtimeType}');
          if (mounted) setState(() => _error = '止められませんでした。もう一度試してください');
          return false;
        }
      },
      child: row,
    );
  }

  /// あとで聞くことの1行（小さく出す。消すときは聞き返さない）
  Widget _followUpRow(PlannerItem item, PlannerController planner) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 52 * _fs,
            child: Text(item.dateLabel, style: TextStyle(color: _p.muted, fontSize: 11 * _fs)),
          ),
          Expanded(
            child: Text(
              item.title,
              style: TextStyle(color: _p.muted, fontSize: 12 * _fs, height: 1.35),
            ),
          ),
          IconButton(
            tooltip: '消す',
            icon: const Icon(Icons.close, size: 14),
            color: _p.muted,
            splashRadius: 14,
            visualDensity: VisualDensity.compact,
            onPressed: _busy
                ? null
                : () => _run(() => planner.deleteItem(item.itemId), '消せませんでした。もう一度試してください'),
          ),
        ],
      ),
    );
  }

  Widget _retry(PlannerController planner) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(child: _note(planner.error ?? '読み込めませんでした', color: _p.error)),
            TextButton(
              onPressed: planner.refresh,
              child: Text('もう一度', style: TextStyle(color: _p.accent)),
            ),
          ],
        ),
      );

  Widget _confirmRow({required String question, required VoidCallback onYes}) {
    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 4),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        border: Border.all(color: _p.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(question, style: TextStyle(color: _p.muted, fontSize: 11.5 * _fs)),
          ),
          TextButton(
            onPressed: _busy ? null : () => setState(() => _confirming = null),
            child: Text('やめる', style: TextStyle(color: _p.muted, fontSize: 12 * _fs)),
          ),
          TextButton(
            onPressed: _busy ? null : onYes,
            child: Text('消す', style: TextStyle(color: _p.error, fontSize: 12 * _fs)),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Text(
          text,
          style: TextStyle(color: _p.muted, fontSize: 11.5 * _fs, fontWeight: FontWeight.w600),
        ),
      );

  Widget _note(String text, {Color? color}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(color: color ?? _p.muted, fontSize: 11 * _fs, height: 1.4),
        ),
      );
}

/// 編集中の中身
class PlannerDraft {
  const PlannerDraft({required this.title, required this.date, this.time = '', this.note = ''});

  final String title;
  final String date;
  final String time;
  final String note;

  /// 元の予定から変わったところだけ
  Map<String, String> changesFrom(PlannerItem item) => {
        if (title != item.title) 'title': title,
        if (date != item.date) 'date': date,
        if (time != item.time) 'time': time,
        if (note != item.note) 'note': note,
      };
}

/// 予定を足す・直す欄
class _PlannerEditor extends StatefulWidget {
  const _PlannerEditor({
    required this.palette,
    required this.fontScale,
    required this.busy,
    required this.onCancel,
    required this.onSave,
    this.initial,
  });

  final VoiceSettingsPalette palette;
  final double fontScale;
  final bool busy;
  final PlannerItem? initial;
  final VoidCallback onCancel;
  final ValueChanged<PlannerDraft> onSave;

  @override
  State<_PlannerEditor> createState() => _PlannerEditorState();
}

class _PlannerEditorState extends State<_PlannerEditor> {
  late final TextEditingController _title;
  late final TextEditingController _time;
  late final TextEditingController _note;
  late String _date;
  String? _problem;

  VoiceSettingsPalette get _p => widget.palette;
  double get _fs => widget.fontScale;

  @override
  void initState() {
    super.initState();
    final item = widget.initial;
    _title = TextEditingController(text: item?.title ?? '');
    _time = TextEditingController(text: item?.time ?? '');
    _note = TextEditingController(text: item?.note ?? '');
    _date = item?.date ?? plannerTodayJst();
  }

  @override
  void dispose() {
    _title.dispose();
    _time.dispose();
    _note.dispose();
    super.dispose();
  }

  void _shiftDate(int days) {
    final d = parsePlannerDate(_date)!.add(Duration(days: days));
    final today = parsePlannerDate(plannerTodayJst())!;
    // 昨日より前には戻さない（サーバーも受け付けない）
    if (d.isBefore(today.subtract(const Duration(days: 1)))) return;
    setState(() => _date = plannerDateString(d));
  }

  void _save() {
    final title = _title.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (title.isEmpty) {
      setState(() => _problem = '名前を入れてください');
      return;
    }
    final time = normalizePlannerTime(_time.text);
    if (time == null) {
      setState(() => _problem = '時間は 10:00 のように入れてください（なくてもOK）');
      return;
    }
    setState(() => _problem = null);
    widget.onSave(PlannerDraft(
      title: title.length > 40 ? title.substring(0, 40) : title,
      date: _date,
      time: time,
      note: _note.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final today = plannerTodayJst();
    final tomorrow = plannerDateString(parsePlannerDate(today)!.add(const Duration(days: 1)));
    final rel = _date == today
        ? '今日 '
        : _date == tomorrow
            ? '明日 '
            : '';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      decoration: BoxDecoration(
        border: Border.all(color: _p.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field(_title, '予定の名前（例: 歯医者）', maxLength: 40, autofocus: widget.initial == null),
          const SizedBox(height: 6),
          Row(
            children: [
              IconButton(
                tooltip: '前の日',
                icon: const Icon(Icons.chevron_left, size: 18),
                color: _p.muted,
                visualDensity: VisualDensity.compact,
                onPressed: widget.busy ? null : () => _shiftDate(-1),
              ),
              Expanded(
                child: Text(
                  '$rel${formatPlannerDate(_date)}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _p.text, fontSize: 13.5 * _fs),
                ),
              ),
              IconButton(
                tooltip: '次の日',
                icon: const Icon(Icons.chevron_right, size: 18),
                color: _p.muted,
                visualDensity: VisualDensity.compact,
                onPressed: widget.busy ? null : () => _shiftDate(1),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 96 * _fs,
                child: _field(_time, '時間 10:00'),
              ),
            ],
          ),
          Wrap(
            spacing: 6,
            children: [
              _chip('今日', today),
              _chip('明日', tomorrow),
              _chip('1週間後', plannerDateString(parsePlannerDate(today)!.add(const Duration(days: 7)))),
            ],
          ),
          const SizedBox(height: 4),
          _field(_note, 'ひとことメモ（なくてもOK）', maxLength: 100),
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_problem!, style: TextStyle(color: _p.error, fontSize: 11 * _fs)),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // 入っている予定を押したとき（スマホだけ）: OS のカレンダーに写す
              if (widget.initial != null && canAddToDeviceCalendar) ...[
                TextButton.icon(
                  onPressed: widget.busy ? null : () => openDeviceCalendarFor(widget.initial!),
                  icon: Icon(Icons.edit_calendar_outlined, size: 15, color: _p.accent),
                  label: Text('カレンダーにも入れる', style: TextStyle(color: _p.accent, fontSize: 12.5 * _fs)),
                ),
                const Spacer(),
              ],
              TextButton(
                onPressed: widget.busy ? null : widget.onCancel,
                child: Text('やめる', style: TextStyle(color: _p.muted, fontSize: 12.5 * _fs)),
              ),
              TextButton(
                onPressed: widget.busy ? null : _save,
                child: Text(
                  widget.initial == null ? '入れる' : '直す',
                  style: TextStyle(color: _p.accent, fontSize: 12.5 * _fs, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String date) => ActionChip(
        label: Text(label, style: TextStyle(color: _date == date ? _p.accent : _p.muted, fontSize: 11 * _fs)),
        backgroundColor: Colors.transparent,
        side: BorderSide(color: _date == date ? _p.accent : _p.line),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onPressed: widget.busy ? null : () => setState(() => _date = date),
      );

  Widget _field(
    TextEditingController controller,
    String hint, {
    int? maxLength,
    bool autofocus = false,
  }) =>
      TextField(
        controller: controller,
        autofocus: autofocus,
        maxLength: maxLength,
        enabled: !widget.busy,
        style: TextStyle(color: _p.text, fontSize: 13 * _fs),
        cursorColor: _p.accent,
        decoration: InputDecoration(
          isDense: true,
          counterText: '',
          hintText: hint,
          hintStyle: TextStyle(color: _p.muted, fontSize: 12.5 * _fs),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: _p.line),
            borderRadius: BorderRadius.circular(6),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: _p.accent),
            borderRadius: BorderRadius.circular(6),
          ),
          disabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: _p.line),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      );
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
