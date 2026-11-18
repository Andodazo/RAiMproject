import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:raim_prototype/config/raim_config.dart';
import 'package:raim_prototype/providers/auth_provider.dart';
import 'package:raim_prototype/widgets/voice_settings_panel.dart';

/// 認証済みユーザーのアカウント設定を開きます。
Future<void> showAccountSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xF2111418),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: AccountSettingsPanel(),
      ),
    ),
  );
}

class AccountSettingsPanel extends StatefulWidget {
  const AccountSettingsPanel({
    super.key,
    this.palette = VoiceSettingsPalette.dark,
  });

  final VoiceSettingsPalette palette;

  @override
  State<AccountSettingsPanel> createState() => _AccountSettingsPanelState();
}

class _AccountSettingsPanelState extends State<AccountSettingsPanel> {
  bool _busy = false;

  Future<void> _changePassword() async {
    final values = await _showPasswordDialog();
    if (values == null || !mounted) return;

    await _runPasswordOperation(
      () => context.read<AuthProvider>().changePassword(
            currentPassword: values.currentPassword!,
            newPassword: values.newPassword,
          ),
      successMessage: 'パスワードを変更しました。',
    );
  }

  Future<void> _runPasswordOperation(
    Future<void> Function() operation, {
    required String successMessage,
  }) async {
    setState(() => _busy = true);
    String message = successMessage;
    try {
      await operation();
    } catch (error) {
      message = error.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        backgroundColor: widget.palette.surface,
        content: Text(message, style: TextStyle(color: widget.palette.text)),
      ));
  }

  Future<_PasswordValues?> _showPasswordDialog() {
    return showDialog<_PasswordValues>(
      context: context,
      builder: (dialogContext) => _PasswordDialog(palette: widget.palette),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'アカウント設定',
            style: TextStyle(
              color: widget.palette.text,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '現在のパスワードを確認して、新しいパスワードへ変更します。',
            style: TextStyle(color: widget.palette.muted, height: 1.4),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _changePassword,
            style: FilledButton.styleFrom(
              backgroundColor: widget.palette.accent,
              foregroundColor: Colors.black,
            ),
            icon: const Icon(Icons.password),
            label: const Text('パスワードを変更'),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            Center(
              child: CircularProgressIndicator(color: widget.palette.accent),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'パスワードや認証コードを管理者・サポートへ伝えないでください。',
            style: TextStyle(color: widget.palette.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _PasswordValues {
  const _PasswordValues({
    required this.newPassword,
    this.currentPassword,
  });

  final String newPassword;
  final String? currentPassword;
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({
    required this.palette,
  });

  final VoiceSettingsPalette palette;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _showCurrentPassword = false;
  bool _showNewPassword = false;
  bool _showConfirmPassword = false;
  String? _error;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _submit() {
    final current = _currentController.text;
    final next = _newController.text;
    final confirm = _confirmController.text;

    if (current.isEmpty) {
      setState(() => _error = '現在のパスワードを入力してください。');
      return;
    }
    if (next.isEmpty) {
      setState(() => _error = '新しいパスワードを入力してください。');
      return;
    }
    if (next != confirm) {
      setState(() => _error = '新しいパスワードが一致しません。');
      return;
    }

    Navigator.of(context).pop(_PasswordValues(
      currentPassword: current,
      newPassword: next,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[
      _passwordField(_currentController, '現在のパスワード'),
      _passwordField(_newController, '新しいパスワード'),
      _passwordField(_confirmController, '新しいパスワード（確認）'),
    ];

    return AlertDialog(
      backgroundColor: widget.palette.surface,
      title: Text(
        'パスワードを変更',
        style: TextStyle(color: widget.palette.text),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _passwordPolicy(),
            ...fields.expand((field) => [field, const SizedBox(height: 12)]),
            if (_error != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: widget.palette.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'キャンセル',
            style: TextStyle(color: widget.palette.accent),
          ),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: widget.palette.accent,
            foregroundColor: Colors.black,
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _passwordPolicy() {
    final requirements = <String>[
      '${RaimConfig.passwordMinimumLength}文字以上',
      if (RaimConfig.passwordRequireUppercase) '英大文字を1文字以上',
      if (RaimConfig.passwordRequireLowercase) '英小文字を1文字以上',
      if (RaimConfig.passwordRequireNumbers) '数字を1文字以上',
      if (RaimConfig.passwordRequireSymbols) '記号を1文字以上',
    ];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(widget.palette.line, widget.palette.surface),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: widget.palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'パスワードの条件',
            style: TextStyle(
              color: widget.palette.text,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            requirements.map((requirement) => '・$requirement').join('　'),
            style: TextStyle(
              color: widget.palette.muted,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _passwordField(TextEditingController controller, String label) {
    final isCurrent = controller == _currentController;
    final isConfirmation = controller == _confirmController;
    final isVisible = isCurrent
        ? _showCurrentPassword
        : isConfirmation
            ? _showConfirmPassword
            : _showNewPassword;

    void toggleVisibility() {
      setState(() {
        if (isCurrent) {
          _showCurrentPassword = !isVisible;
        } else if (isConfirmation) {
          _showConfirmPassword = !isVisible;
        } else {
          _showNewPassword = !isVisible;
        }
      });
    }

    return TextField(
      controller: controller,
      obscureText: !isVisible,
      autofocus: controller == _currentController,
      style: TextStyle(color: widget.palette.text),
      cursorColor: widget.palette.accent,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: widget.palette.muted),
        floatingLabelStyle: TextStyle(color: widget.palette.accent),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: widget.palette.line),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: widget.palette.accent, width: 2),
        ),
        suffixIcon: IconButton(
          onPressed: toggleVisibility,
          tooltip: isVisible ? 'パスワードを隠す' : 'パスワードを表示',
          color: widget.palette.muted,
          icon: Icon(
            isVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          ),
        ),
      ),
      textInputAction: TextInputAction.next,
    );
  }
}
