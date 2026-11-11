// lib/widgets/planner_memo_panel.dart
//
// 「予定とメモ」画面のメモタブと、チェックできるリストの部品。
//
// メモ帳は、ライムに頼む・聞くのが基本（安藤さんと決めた）。ここは控えで、
// 電波が無いときや手で直すとき用なので、目立たせない。
// 最後に読んだ一覧は端末に保存してあるので、圏外でも見られる（PlannerController）。
//
// メモやリストそのものを消すときは1回確かめる。リストの項目はすぐ消す・チェックする。
// チェックした項目は次の日に消える（サーバーが外す）。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:raim_prototype/models/planner_item.dart';
import 'package:raim_prototype/providers/planner_controller.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/widgets/voice_settings_panel.dart';

/// リストの項目（チェックボックス付き）。カードと画面の両方で使う。
///
/// 一覧が変わったら（ほかの端末やライムがチェックしても）すぐ描き直す。
class PlannerListEntries extends StatelessWidget {
  const PlannerListEntries({
    super.key,
    required this.listId,
    required this.textColor,
    required this.mutedColor,
    required this.accentColor,
    this.fontScale = 1.0,
    this.removable = false,
    this.fallback,
    this.maxEntries,
  });

  final String listId;
  final Color textColor;
  final Color mutedColor;
  final Color accentColor;
  final double fontScale;

  /// 項目の横に × を出す（画面のとき）
  final bool removable;

  /// 一覧にまだ無いとき（読み直す前）に見せる中身
  final PlannerItem? fallback;

  /// 出す項目の数（カードでは抑える）
  final int? maxEntries;

  @override
  Widget build(BuildContext context) {
    final planner = context.watch<PlannerController>();
    final list = planner.findItem(listId) ?? fallback;
    if (list == null) {
      return Text('このリストはもう無いよ', style: TextStyle(color: mutedColor, fontSize: 12 * fontScale));
    }
    final entries = maxEntries == null || list.entries.length <= maxEntries!
        ? list.entries
        : list.entries.take(maxEntries!).toList();
    if (entries.isEmpty) {
      return Text('（項目はまだ無いよ）', style: TextStyle(color: mutedColor, fontSize: 12 * fontScale));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries)
          _EntryRow(
            entry: entry,
            textColor: textColor,
            mutedColor: mutedColor,
            accentColor: accentColor,
            fontScale: fontScale,
            onChanged: (checked) => _run(
              context,
              () => planner.toggleEntry(listId, entry.id, checked),
            ),
            onRemove: removable
                ? () => _run(context, () => planner.removeEntries(listId, {entry.id}))
                : null,
          ),
        if (entries.length < list.entries.length)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2),
            child: Text(
              'ほかに${list.entries.length - entries.length}件',
              style: TextStyle(color: mutedColor, fontSize: 11.5 * fontScale),
            ),
          ),
      ],
    );
  }

  static Future<void> _run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      RaimLog.d('[PlannerList] 変えられませんでした: ${e.runtimeType}');
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('変えられませんでした。電波のあるところでもう一度試してね')),
      );
    }
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.textColor,
    required this.mutedColor,
    required this.accentColor,
    required this.fontScale,
    required this.onChanged,
    this.onRemove,
  });

  final PlannerListEntry entry;
  final Color textColor;
  final Color mutedColor;
  final Color accentColor;
  final double fontScale;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!entry.checked),
      borderRadius: BorderRadius.circular(6),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            height: 30,
            child: Checkbox(
              value: entry.checked,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: accentColor,
              side: BorderSide(color: mutedColor),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          Expanded(
            child: Text(
              entry.text,
              style: TextStyle(
                color: entry.checked ? mutedColor : textColor,
                fontSize: 13 * fontScale,
                decoration: entry.checked ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          if (onRemove != null)
            IconButton(
              tooltip: '項目を消す',
              icon: const Icon(Icons.close, size: 14),
              color: mutedColor,
              splashRadius: 14,
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

/// 「予定とメモ」画面のメモタブの中身（ListView の中に並べる）
class PlannerMemoSection extends StatefulWidget {
  const PlannerMemoSection({
    super.key,
    this.palette = VoiceSettingsPalette.dark,
    this.fontScale = 1.0,
  });

  final VoiceSettingsPalette palette;
  final double fontScale;

  @override
  State<PlannerMemoSection> createState() => _PlannerMemoSectionState();
}

class _PlannerMemoSectionState extends State<PlannerMemoSection> {
  static const String _newMemo = '__memo__';
  static const String _newList = '__list__';

  /// 書いている途中のもの（新しいメモ・新しいリスト・直しているメモの id）
  String? _editing;

  /// 「消しますか？」と確かめているメモ・リスト
  String? _confirming;

  bool _busy = false;
  String? _error;

  final TextEditingController _field = TextEditingController();
  final Map<String, TextEditingController> _entryFields = {};

  VoiceSettingsPalette get _p => widget.palette;
  double get _fs => widget.fontScale;

  @override
  void dispose() {
    _field.dispose();
    for (final c in _entryFields.values) {
      c.dispose();
    }
    super.dispose();
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
        _field.clear();
      });
    } catch (e) {
      RaimLog.d('[PlannerMemo] $failMessage: ${e.runtimeType}');
      if (mounted) setState(() => _error = failMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startEditing(String key, [String initial = '']) {
    setState(() {
      _editing = key;
      _confirming = null;
      _field.text = initial;
    });
  }

  @override
  Widget build(BuildContext context) {
    final planner = context.watch<PlannerController>();
    final memos = planner.memos;
    final lists = planner.lists;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _note('ライムに「メモして」「買うものに牛乳足して」と頼むと入ります。'
            '「メモ何あったっけ？」と聞くとカードで出します。チェックした項目は次の日に消えます。'),
        if (_error != null) _note(_error!, color: _p.error),
        Row(
          children: [
            _addButton('メモを足す', Icons.note_add_outlined, () => _startEditing(_newMemo)),
            _addButton('リストを作る', Icons.checklist, () => _startEditing(_newList)),
          ],
        ),
        if (_editing == _newMemo)
          _editor(
            hint: '駐輪場は3階',
            maxLines: 3,
            onSave: (text) => _run(() => planner.addMemo(text), '足せませんでした。もう一度試してください'),
          ),
        if (_editing == _newList)
          _editor(
            hint: 'リストの名前（例: 買うもの）',
            onSave: (text) => _run(() => planner.addList(text), '作れませんでした。もう一度試してください'),
          ),
        if (memos.isEmpty && lists.isEmpty && _editing == null)
          _note('まだメモはありません。'),
        if (memos.isNotEmpty) ...[
          _label('メモ'),
          ...memos.map((m) => _memoRow(m, planner)),
        ],
        for (final list in lists) ..._listBlock(list, planner),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _memoRow(PlannerItem memo, PlannerController planner) {
    if (_editing == memo.itemId) {
      return _editor(
        hint: 'メモ',
        maxLines: 3,
        onSave: (text) => _run(
          () async {
            if (text != memo.text) await planner.updateMemo(memo.itemId, text);
          },
          '直せませんでした。もう一度試してください',
        ),
      );
    }
    final confirming = _confirming == memo.itemId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _busy ? null : () => _startEditing(memo.itemId, memo.text),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(memo.text, style: TextStyle(color: _p.text, fontSize: 13.5 * _fs, height: 1.35)),
                ),
                _trash(memo.itemId, confirming),
              ],
            ),
          ),
        ),
        if (confirming)
          _confirmRow(
            question: 'このメモを消しますか？',
            onYes: () => _run(() => planner.deleteItem(memo.itemId), '消せませんでした。もう一度試してください'),
          ),
      ],
    );
  }

  List<Widget> _listBlock(PlannerItem list, PlannerController planner) {
    final confirming = _confirming == list.itemId;
    final field = _entryFields.putIfAbsent(list.itemId, TextEditingController.new);
    Future<void> addEntry() async {
      final text = field.text.trim();
      if (text.isEmpty) return;
      field.clear();
      await _run(() => planner.addEntry(list.itemId, text), '足せませんでした。もう一度試してください');
    }

    return [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            Icon(Icons.checklist, size: 15 * _fs, color: _p.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                list.title,
                style: TextStyle(color: _p.text, fontSize: 13.5 * _fs, fontWeight: FontWeight.w600),
              ),
            ),
            _trash(list.itemId, confirming),
          ],
        ),
      ),
      if (confirming)
        _confirmRow(
          question: '「${list.title}」を項目ごと消しますか？',
          onYes: () => _run(() => planner.deleteItem(list.itemId), '消せませんでした。もう一度試してください'),
        ),
      PlannerListEntries(
        listId: list.itemId,
        textColor: _p.text,
        mutedColor: _p.muted,
        accentColor: _p.accent,
        fontScale: _fs,
        removable: true,
      ),
      Row(
        children: [
          const SizedBox(width: 32),
          Expanded(
            child: TextField(
              controller: field,
              enabled: !_busy,
              style: TextStyle(color: _p.text, fontSize: 13 * _fs),
              decoration: InputDecoration(
                isDense: true,
                hintText: '項目を足す',
                hintStyle: TextStyle(color: _p.muted, fontSize: 12.5 * _fs),
                border: InputBorder.none,
              ),
              onSubmitted: (_) => addEntry(),
            ),
          ),
          IconButton(
            tooltip: '足す',
            icon: const Icon(Icons.add, size: 16),
            color: _p.accent,
            splashRadius: 15,
            visualDensity: VisualDensity.compact,
            onPressed: _busy ? null : addEntry,
          ),
        ],
      ),
    ];
  }

  Widget _editor({required String hint, required ValueChanged<String> onSave, int maxLines = 1}) {
    void save() {
      final text = _field.text.trim();
      if (text.isEmpty) return;
      onSave(text);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _field,
            autofocus: true,
            enabled: !_busy,
            minLines: 1,
            maxLines: maxLines,
            style: TextStyle(color: _p.text, fontSize: 13.5 * _fs),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(color: _p.muted, fontSize: 13 * _fs),
              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: _p.line)),
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: _p.accent)),
            ),
            onSubmitted: maxLines == 1 ? (_) => save() : null,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _busy ? null : () => setState(() => _editing = null),
                child: Text('やめる', style: TextStyle(color: _p.muted, fontSize: 12 * _fs)),
              ),
              TextButton(
                onPressed: _busy ? null : save,
                child: Text('保存', style: TextStyle(color: _p.accent, fontSize: 12 * _fs)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _addButton(String label, IconData icon, VoidCallback onPressed) => TextButton.icon(
        onPressed: _busy ? null : onPressed,
        icon: Icon(icon, size: 16, color: _p.accent),
        label: Text(label, style: TextStyle(color: _p.accent, fontSize: 13 * _fs)),
      );

  Widget _trash(String itemId, bool confirming) => IconButton(
        tooltip: '消す',
        icon: const Icon(Icons.delete_outline, size: 16),
        color: _p.muted,
        splashRadius: 16,
        visualDensity: VisualDensity.compact,
        onPressed: _busy
            ? null
            : () => setState(() {
                  _confirming = confirming ? null : itemId;
                  _editing = null;
                }),
      );

  Widget _confirmRow({required String question, required VoidCallback onYes}) => Container(
        margin: const EdgeInsets.only(top: 2, bottom: 4),
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
        decoration: BoxDecoration(
          border: Border.all(color: _p.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(child: Text(question, style: TextStyle(color: _p.muted, fontSize: 11.5 * _fs))),
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
