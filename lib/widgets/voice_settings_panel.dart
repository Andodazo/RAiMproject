// lib/widgets/voice_settings_panel.dart
//
// 音声まわりの設定。Windows の入力小窓とスマホの両方で同じものを使う。
//
//   「ねえライム」で呼ぶ … 常時待機の ON/OFF（既定 OFF）
//   呼び方              … 「ねえライム」だけ / 「ライム」でも
//   呼んだあと話しかける … Transcribe で聞き取って送るか（既定 ON）
//   マイク              … 使うマイク（既定は OS の既定）
//
// 【プライバシーの説明を画面に書く理由】
// 常時マイクを聞く機能なので、何がどこへ送られるかを ON にする場所で
// 伝える。ウェイクワードの判定は端末の中だけで行い、外には送らない。
// 外（AWS）に送るのは、呼ばれたあとに話した部分だけ。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:raim_prototype/providers/voice_controller.dart';
import 'package:raim_prototype/providers/voice_settings_provider.dart';
import 'package:raim_prototype/services/mic_stream_service.dart';
import 'package:raim_prototype/services/raim_log.dart';

/// 置く場所ごとの色。
class VoiceSettingsPalette {
  const VoiceSettingsPalette({
    required this.text,
    required this.muted,
    required this.accent,
    required this.error,
    required this.line,
    required this.surface,
  });

  final Color text;
  final Color muted;
  final Color accent;
  final Color error;
  final Color line;

  /// ドロップダウンを開いたときの背景
  final Color surface;

  /// スマホのメニューと同じ、黒地に白の配色。
  static const dark = VoiceSettingsPalette(
    text: Colors.white,
    muted: Color(0xB3FFFFFF),
    accent: Color(0xFFB7F35A),
    error: Color(0xFFFF8A80),
    line: Color(0x33FFFFFF),
    surface: Color(0xFF1B1F26),
  );
}

/// スマホではボトムシートで開く。
Future<void> showVoiceSettingsSheet(BuildContext context) {
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
      child: const SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: VoiceSettingsPanel(showTitle: true),
        ),
      ),
    ),
  );
}

class VoiceSettingsPanel extends StatefulWidget {
  const VoiceSettingsPanel({
    super.key,
    this.palette = VoiceSettingsPalette.dark,
    this.showTitle = false,
    this.fontScale = 1.0,
  });

  final VoiceSettingsPalette palette;
  final bool showTitle;

  /// Windows の小窓では文字を少し小さくする。
  final double fontScale;

  @override
  State<VoiceSettingsPanel> createState() => _VoiceSettingsPanelState();
}

class _VoiceSettingsPanelState extends State<VoiceSettingsPanel> {
  List<MicDevice>? _devices;
  bool _loadingDevices = false;
  String? _deviceError;

  VoiceSettingsPalette get _p => widget.palette;
  double get _fs => widget.fontScale;

  @override
  void initState() {
    super.initState();
    if (VoiceController.isSupported) _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() {
      _loadingDevices = true;
      _deviceError = null;
    });
    try {
      final devices = await MicStreamService.instance.listDevices();
      if (!mounted) return;
      setState(() => _devices = devices);
    } catch (e) {
      RaimLog.w('[VoiceSettings] マイク一覧を取得できませんでした: ${e.runtimeType}');
      if (!mounted) return;
      setState(() => _deviceError = 'マイクの一覧を取得できませんでした');
    } finally {
      if (mounted) setState(() => _loadingDevices = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<VoiceSettingsProvider>();
    final voice = context.watch<VoiceController>();
    final supported = VoiceController.isSupported;
    final wakeOn = settings.wakeWordEnabled;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showTitle) ...[
            Text(
              '音声の設定',
              style: TextStyle(
                color: _p.text,
                fontSize: 16 * _fs,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
          ],

          if (!supported)
            _note(
              'この端末ではまだ「ねえライム」を使えません（iOS は音声認識のライブラリを入れてビルドする必要があります）。',
              color: _p.error,
            ),

          // ─── ねえライム ───
          _switchRow(
            title: '「ねえライム」で呼ぶ',
            subtitle: _statusText(voice, wakeOn),
            subtitleColor: voice.state == VoiceState.error ||
                    voice.micWarning != null
                ? _p.error
                : null,
            value: wakeOn,
            onChanged: supported ? settings.setWakeWordEnabled : null,
          ),
          _note(
            'ON の間はマイクで常に聞いています。「ねえライム」かどうかの判定は'
            'この端末の中だけで行い、音声を外に送ることはありません。',
          ),

          // ─── 呼び方 ───
          _divider(),
          _label('呼び方'),
          _choiceRow(
            title: '「ねえライム」だけ（おすすめ）',
            selected: settings.wakePhraseMode == WakePhraseMode.polite,
            enabled: supported,
            onTap: () => settings.setWakePhraseMode(WakePhraseMode.polite),
          ),
          _choiceRow(
            title: '「ライム」だけでも呼ぶ',
            subtitle: '呼びやすくなりますが、会話の中の「ライム」にも反応しやすくなります',
            selected: settings.wakePhraseMode == WakePhraseMode.both,
            enabled: supported,
            onTap: () => settings.setWakePhraseMode(WakePhraseMode.both),
          ),

          // ─── 聞き取り ───
          _divider(),
          _switchRow(
            title: '呼んだあと、声で話しかける',
            subtitle: settings.sttEnabled
                ? '話した内容を文字にしてライムに送ります'
                : '呼ぶと入力欄が開くだけになります',
            value: settings.sttEnabled,
            onChanged:
                supported && voice.hasStt ? settings.setSttEnabled : null,
          ),
          _note(
            '呼んだあとに話した部分だけ、文字にするために AWS'
            '（Amazon Transcribe）へ送ります。',
          ),

          // ─── マイクボタン ───
          _divider(),
          _switchRow(
            title: 'マイクボタンで話しかける',
            subtitle: settings.manualMicEnabled
                ? '入力欄のマイクを押して話し、もう一度押すか黙ると送ります'
                : 'マイクボタンを出しません',
            value: settings.manualMicEnabled,
            onChanged: voice.hasStt ? settings.setManualMicEnabled : null,
          ),

          // ─── マイク ───
          if (supported) ...[
            _divider(),
            _label('マイク'),
            _micSelector(settings),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  String _statusText(VoiceController voice, bool wakeOn) {
    final warning = voice.micWarning;
    return switch (voice.state) {
      VoiceState.off => wakeOn ? '準備中…' : 'オフ',
      VoiceState.starting => '準備中…（初回は数秒かかります）',
      VoiceState.listening when warning != null => '待機中（$warning）',
      VoiceState.listening => '待機中',
      VoiceState.awake => '聞いています',
      VoiceState.error => voice.errorMessage ?? '起動できませんでした',
    };
  }

  /// マイクの選択。
  ///
  /// ドロップダウンは使わない。ドロップダウンは別のルート（ポップアップ）を
  /// 開くが、Windows の入力小窓は枠なしの小さな窓で、ポップアップが
  /// 窓の外にはみ出したり裏に回ったりする（PopupMenuButton で同じ問題が
  /// 出ていた）。一覧をそのまま並べて選ばせる。
  Widget _micSelector(VoiceSettingsProvider settings) {
    final devices = _devices;
    final selected = settings.micDeviceId;
    final missing = selected != null &&
        devices != null &&
        !devices.any((d) => d.id == selected);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _choiceRow(
          title: 'OS の既定のマイク',
          selected: selected == null,
          enabled: true,
          onTap: () => settings.setMicDeviceId(null),
        ),
        if (devices != null)
          for (final d in devices)
            _choiceRow(
              title: d.label.isEmpty ? '（名前なし）' : d.label,
              selected: selected == d.id,
              enabled: true,
              onTap: () => settings.setMicDeviceId(d.id),
            ),
        if (missing)
          _choiceRow(
            title: '前に選んだマイク（見つかりません）',
            selected: true,
            enabled: true,
            onTap: () {},
          ),
        Row(
          children: [
            if (_loadingDevices)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _p.muted,
                ),
              ),
            const Spacer(),
            TextButton.icon(
              onPressed: _loadingDevices ? null : _loadDevices,
              icon: Icon(Icons.refresh, size: 15, color: _p.muted),
              label: Text(
                '一覧を読み直す',
                style: TextStyle(color: _p.muted, fontSize: 11.5 * _fs),
              ),
            ),
          ],
        ),
        if (_deviceError != null) _note(_deviceError!, color: _p.error),
      ],
    );
  }

  // ─── 部品 ───

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 2),
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

  Widget _divider() => Divider(color: _p.line, height: 17);

  Widget _switchRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
    Color? subtitleColor,
  }) {
    final enabled = onChanged != null;
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: enabled ? _p.text : _p.muted,
                      fontSize: 13.5 * _fs,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: subtitleColor ?? (value ? _p.accent : _p.muted),
                      fontSize: 11.5 * _fs,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: _p.accent,
            ),
          ],
        ),
      ),
    );
  }

  /// ラジオボタンの代わり。
  ///
  /// Flutter 3.32 以降 Radio の groupValue / onChanged は非推奨になり、
  /// RadioGroup で囲む形に変わった。2択しかないので自前で描く。
  Widget _choiceRow({
    required String title,
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
    String? subtitle,
  }) {
    final color = !enabled
        ? _p.muted
        : selected
            ? _p.accent
            : _p.text;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: selected && enabled ? _p.accent : _p.muted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(color: color, fontSize: 13 * _fs)),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: TextStyle(color: _p.muted, fontSize: 11 * _fs),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
