// lib/widgets/station_recording_toggle.dart
//
// 【確認用・後で消す】駅アラームの画面右上の ● と、その下に出す保存先の説明。
// ● を押すと、次の乗車から車内の音を録音する／しないを切り替える（StationRecorder）。

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:raim_prototype/services/station/station_recorder.dart';

class StationRecordingToggle extends StatefulWidget {
  const StationRecordingToggle({super.key});

  @override
  State<StationRecordingToggle> createState() => _StationRecordingToggleState();
}

class _StationRecordingToggleState extends State<StationRecordingToggle> {
  static const Color _on = Color(0xFFFF5252);
  static const Color _off = Color(0xFF8B97A4);

  @override
  void initState() {
    super.initState();
    unawaited(StationRecorder.load());
  }

  Future<void> _toggle(bool on) => StationRecorder.setEnabled(!on);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: StationRecorder.enabled,
      builder: (context, on, _) => IconButton(
        tooltip: on ? '車内の音を録音する（ON）' : '車内の音を録音する（OFF）',
        icon: Icon(
          on ? Icons.fiber_manual_record : Icons.fiber_manual_record_outlined,
          color: on ? _on : _off,
        ),
        onPressed: () => _toggle(on),
      ),
    );
  }
}

/// 録音が ON のとき、画面の上に保存先を出す。
class StationRecordingNote extends StatelessWidget {
  const StationRecordingNote({super.key});

  static const Color _bg = Color(0xFF2A1A1C);
  static const Color _red = Color(0xFFFF5252);
  static const Color _text = Color(0xFFE8ECF0);
  static const Color _mut = Color(0xFF8B97A4);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: StationRecorder.enabled,
      builder: (context, on, _) {
        if (!on) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          color: _bg,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: ValueListenableBuilder<String?>(
            valueListenable: StationRecorder.lastSaved,
            builder: (context, last, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '● 車内の音を録音します（確認用）',
                  style: TextStyle(
                      color: _red, fontSize: 12.5, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  '保存先: ${StationRecorder.whereLabel}',
                  style: const TextStyle(color: _text, fontSize: 12),
                ),
                if (last != null)
                  Text(
                    '前回: $last',
                    style: const TextStyle(color: _mut, fontSize: 11.5),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
