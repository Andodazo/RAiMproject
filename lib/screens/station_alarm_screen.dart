// lib/screens/station_alarm_screen.dart
//
// 駅アラームの画面。降りる駅を探して選び、乗車モードを始める。
// 乗車中は、目的の駅と今の状態、最後に聞こえた言葉を出す。
//
// 乗車中は Android のフォアグラウンドサービスで、画面を消しても聞き続ける。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:raim_prototype/providers/station_alarm_controller.dart';
import 'package:raim_prototype/services/station/station_alarm.dart';
import 'package:raim_prototype/services/station/station_database.dart';

const _bg = Color(0xFF111418);
const _card = Color(0xFF1B1F26);
const _line = Color(0xFF333A44);
const _text = Color(0xFFE8ECF0);
const _mut = Color(0xFF8B97A4);
const _lime = Color(0xFFB7F35A);
const _warn = Color(0xFFFFB74D);
const _err = Color(0xFFFF8A80);

class StationAlarmScreen extends StatefulWidget {
  const StationAlarmScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const StationAlarmScreen()),
      );

  @override
  State<StationAlarmScreen> createState() => _StationAlarmScreenState();
}

class _StationAlarmScreenState extends State<StationAlarmScreen> {
  final _query = TextEditingController();
  StationDatabase? _db;
  List<Station> _results = const [];
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final db = await StationDatabase.load();
      if (!mounted) return;
      setState(() => _db = db);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = '駅データを読み込めませんでした');
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search(String q) {
    final db = _db;
    if (db == null) return;
    setState(() => _results = db.search(q));
  }

  /// 駅を選んだら、乗る路線を選ばせてから始める。
  Future<void> _choose(Station station) async {
    final db = _db;
    if (db == null) return;
    final lines = db.linesOf(station);

    RailLine? chosen;
    if (lines.length > 1) {
      final picked = await showModalBottomSheet<_LineChoice>(
        context: context,
        backgroundColor: _card,
        builder: (_) => _LinePicker(station: station, lines: lines),
      );
      if (picked == null || !mounted) return;
      chosen = picked.line;
    } else if (lines.length == 1) {
      chosen = lines.single;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    await context.read<StationAlarmController>().start(station, line: chosen);
  }

  @override
  Widget build(BuildContext context) {
    final alarm = context.watch<StationAlarmController>();

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _text,
        title: const Text('駅アラーム'),
      ),
      body: SafeArea(
        child: !StationAlarmController.isSupported
            ? _message('この端末ではまだ駅アラームを使えません（Android のみ対応）')
            : alarm.isActive
                ? _Riding(alarm: alarm)
                : _buildPicker(alarm),
      ),
    );
  }

  Widget _buildPicker(StationAlarmController alarm) {
    if (_loadError != null) return _message(_loadError!, color: _err);
    if (_db == null) {
      return const Center(child: CircularProgressIndicator(color: _lime));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            '降りる駅を選ぶと、車内アナウンスを聞いて近づいたら知らせます。',
            style: TextStyle(color: _mut.withValues(alpha: 0.9), fontSize: 12.5),
          ),
        ),
        if (alarm.state == StationAlarmState.error && alarm.errorMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(alarm.errorMessage!,
                style: const TextStyle(color: _err, fontSize: 12.5)),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _query,
            autofocus: true,
            onChanged: _search,
            style: const TextStyle(color: _text),
            cursorColor: _lime,
            decoration: InputDecoration(
              hintText: '駅名かよみがなで検索（例: しんじゅく）',
              hintStyle: const TextStyle(color: _mut),
              prefixIcon: const Icon(Icons.search, color: _mut),
              filled: true,
              fillColor: _card,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _lime),
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _results.length,
            separatorBuilder: (_, _) => const Divider(height: 1, color: _line),
            itemBuilder: (_, i) {
              final s = _results[i];
              final lines = _db!.linesOf(s).map((l) => l.name).join('・');
              return ListTile(
                title: Text(s.name, style: const TextStyle(color: _text)),
                subtitle: Text(
                  '${s.kana}　$lines',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _mut, fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right, color: _mut),
                onTap: () => _choose(s),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _message(String text, {Color color = _mut}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text,
              textAlign: TextAlign.center, style: TextStyle(color: color)),
        ),
      );
}

/// 路線の選択肢。line が null なら「わからない（すべて）」。
class _LineChoice {
  const _LineChoice(this.line);
  final RailLine? line;
}

class _LinePicker extends StatelessWidget {
  const _LinePicker({required this.station, required this.lines});

  final Station station;
  final List<RailLine> lines;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('${station.name} に向かう路線は？',
                style: const TextStyle(
                    color: _text, fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          ListTile(
            leading: const Icon(Icons.help_outline, color: _mut),
            title: const Text('わからない・いくつかに乗る',
                style: TextStyle(color: _text)),
            subtitle: const Text('すべての路線のアナウンスを待ちます',
                style: TextStyle(color: _mut, fontSize: 12)),
            onTap: () => Navigator.pop(context, const _LineChoice(null)),
          ),
          for (final l in lines)
            ListTile(
              leading: const Icon(Icons.train, color: _lime),
              title: Text(l.name, style: const TextStyle(color: _text)),
              onTap: () => Navigator.pop(context, _LineChoice(l)),
            ),
        ],
      ),
    );
  }
}

/// 乗車中の表示。
class _Riding extends StatelessWidget {
  const _Riding({required this.alarm});

  final StationAlarmController alarm;

  @override
  Widget build(BuildContext context) {
    final dest = alarm.destination;
    final event = alarm.lastEvent;
    final arrived = alarm.state == StationAlarmState.arrived;
    final approaching = !arrived &&
        event != null &&
        event.stage == StationAlarmStage.approaching;

    final (color, status) = switch (alarm.state) {
      StationAlarmState.starting => (_mut, '準備中…（初回は数秒かかります）'),
      StationAlarmState.arrived => (_lime, 'まもなく到着！降りる準備をしてね'),
      _ when approaching => (_warn, '次は「${event.station.name}」。もうすぐだよ'),
      _ => (_text, '車内アナウンスを聞いています'),
    };

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('降りる駅', style: TextStyle(color: _mut)),
          const SizedBox(height: 4),
          Text(
            dest?.name ?? '',
            style: const TextStyle(
                color: _text, fontSize: 32, fontWeight: FontWeight.bold),
          ),
          Text(
            alarm.line?.name ?? 'すべての路線',
            style: const TextStyle(color: _mut),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withValues(alpha: 0.6)),
            ),
            child: Row(
              children: [
                Icon(
                  arrived
                      ? Icons.notifications_active
                      : approaching
                          ? Icons.directions_railway
                          : Icons.hearing,
                  color: color,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(status,
                      style: TextStyle(color: color, fontSize: 16)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text('最後に聞こえた言葉（確認用）',
              style: TextStyle(color: _mut, fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            alarm.lastHeard ?? '—',
            style: const TextStyle(color: _text, fontSize: 13),
          ),
          const Spacer(),
          Text(
            alarm.canRunInBackground
                ? '画面を消しても聞き続けます。通知から戻れます。'
                : '通知を出せないため、画面を点けたままにしてください。',
            style: TextStyle(
              color: alarm.canRunInBackground ? _mut : _warn,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: arrived ? _lime : _card,
                foregroundColor: arrived ? _bg : _text,
                side: const BorderSide(color: _line),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text(arrived ? '降りた・終わる' : '乗車モードを終える'),
              onPressed: () => unawaited(alarm.stop()),
            ),
          ),
        ],
      ),
    );
  }
}
