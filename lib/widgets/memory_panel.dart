// lib/widgets/memory_panel.dart
//
// ライムが覚えていること。Windows の入力小窓とスマホの両方で同じものを使う。
//
// 【なぜ必要か】
// ライムは会話の要約から「この人はどんな人か」を覚えていて、別の会話でも話題にする。
// 以前は何を覚えているかを見る方法が無く、消すには会話ごと消すしかなかった。
//
// 項目ごとに「忘れさせる」ことができる。消すと元に戻せないので、その場で確かめる
// （Windows の小窓ではダイアログが開きにくいので、行の中で確かめる）。
// 消しても会話の履歴は残る。

import 'package:flutter/material.dart';

import 'package:raim_prototype/models/raim_memory.dart';
import 'package:raim_prototype/services/raim_log.dart';
import 'package:raim_prototype/widgets/voice_settings_panel.dart';

/// スマホではボトムシートで開く。
Future<void> showMemorySheet(BuildContext context, MemoryService service) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xF2111418),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: MemoryPanel(service: service, showTitle: true),
        ),
      ),
    ),
  );
}

class MemoryPanel extends StatefulWidget {
  const MemoryPanel({
    super.key,
    required this.service,
    this.palette = VoiceSettingsPalette.dark,
    this.showTitle = false,
    this.fontScale = 1.0,
  });

  final MemoryService service;
  final VoiceSettingsPalette palette;
  final bool showTitle;

  /// Windows の小窓では文字を少し小さくする。
  final double fontScale;

  @override
  State<MemoryPanel> createState() => _MemoryPanelState();
}

class _MemoryPanelState extends State<MemoryPanel> {
  RaimMemory? _memory;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  /// 「忘れさせる？」と確かめている項目。全部のときは [_confirmAll]
  String? _confirming;
  bool _confirmAll = false;

  VoiceSettingsPalette get _p => widget.palette;
  double get _fs => widget.fontScale;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final memory = await widget.service.fetchMemory();
      if (!mounted) return;
      setState(() => _memory = memory);
    } catch (e) {
      RaimLog.d('[MemoryPanel] 読めませんでした: $e');
      if (!mounted) return;
      setState(() => _error = '読み込めませんでした');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forget({String? item, bool all = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final memory = await widget.service.forgetMemory(
        items: item == null ? const [] : [item],
        all: all,
      );
      if (!mounted) return;
      setState(() {
        _memory = memory;
        _confirming = null;
        _confirmAll = false;
      });
    } catch (e) {
      RaimLog.d('[MemoryPanel] 消せませんでした: $e');
      if (!mounted) return;
      setState(() => _error = '消せませんでした。もう一度試してください');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final memory = _memory;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      shrinkWrap: true,
      children: [
        if (widget.showTitle)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'ライムが覚えていること',
              style: TextStyle(
                color: _p.text,
                fontSize: 16 * _fs,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        _note('会話の中でライムが覚えたことです。忘れさせても、会話の履歴は残ります。'),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (memory == null)
          _retry()
        else if (memory.isEmpty)
          _note('まだ覚えていることはありません。たくさん話すと、少しずつ覚えていきます。')
        else ...[
          if (memory.facts.isNotEmpty) ...[
            _label('話してくれたこと'),
            for (final item in memory.facts) _itemRow(item),
          ],
          if (memory.relationship.isNotEmpty) ...[
            _label('ライムが感じたこと'),
            for (final item in memory.relationship) _itemRow(item),
          ],
          Divider(color: _p.line, height: 17),
          _forgetAllRow(),
        ],
        if (_error != null && memory != null) _note(_error!, color: _p.error),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _retry() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(child: _note(_error ?? '読み込めませんでした', color: _p.error)),
            TextButton(
              onPressed: _load,
              child: Text('もう一度', style: TextStyle(color: _p.accent)),
            ),
          ],
        ),
      );

  Widget _itemRow(String item) {
    final confirming = _confirming == item;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    item,
                    style: TextStyle(color: _p.text, fontSize: 13 * _fs, height: 1.4),
                  ),
                ),
              ),
              IconButton(
                tooltip: '忘れさせる',
                icon: const Icon(Icons.close, size: 16),
                color: _p.muted,
                splashRadius: 16,
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _confirming = confirming ? null : item;
                          _confirmAll = false;
                        }),
              ),
            ],
          ),
          if (confirming)
            _confirmRow(
              question: 'これを忘れさせますか？元に戻せません。',
              onYes: () => _forget(item: item),
            ),
        ],
      ),
    );
  }

  Widget _forgetAllRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _confirmAll = !_confirmAll;
                      _confirming = null;
                    }),
            icon: Icon(Icons.delete_outline, size: 16, color: _p.error),
            label: Text(
              '全部忘れさせる',
              style: TextStyle(color: _p.error, fontSize: 13 * _fs),
            ),
          ),
        ),
        if (_confirmAll)
          _confirmRow(
            question: '覚えていることを全部忘れさせますか？元に戻せません。',
            onYes: () => _forget(all: true),
          ),
      ],
    );
  }

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
            child: Text(
              question,
              style: TextStyle(color: _p.muted, fontSize: 11.5 * _fs),
            ),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _confirming = null;
                      _confirmAll = false;
                    }),
            child: Text('やめる', style: TextStyle(color: _p.muted, fontSize: 12 * _fs)),
          ),
          TextButton(
            onPressed: _busy ? null : onYes,
            child: Text('忘れさせる', style: TextStyle(color: _p.error, fontSize: 12 * _fs)),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Text(
          text,
          style: TextStyle(
            color: _p.muted,
            fontSize: 11.5 * _fs,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _note(String text, {Color? color}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            color: color ?? _p.muted,
            fontSize: 11 * _fs,
            height: 1.4,
          ),
        ),
      );
}
