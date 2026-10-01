import 'package:flutter/material.dart';

import 'ui.dart';

class NikoUnattendedPasswordChoice {
  final String password;
  final bool resume;
  const NikoUnattendedPasswordChoice(this.password, this.resume);
}

Future<NikoUnattendedPasswordChoice?> askNikoUnattendedPassword(
        BuildContext context) =>
    showDialog<NikoUnattendedPasswordChoice>(
        context: context,
        builder: (_) => const _NikoUnattendedPasswordDialog());

class _NikoUnattendedPasswordDialog extends StatefulWidget {
  const _NikoUnattendedPasswordDialog();
  @override
  State<_NikoUnattendedPasswordDialog> createState() =>
      _NikoUnattendedPasswordDialogState();
}

class _NikoUnattendedPasswordDialogState
    extends State<_NikoUnattendedPasswordDialog> {
  final password = TextEditingController();
  final confirmation = TextEditingController();
  var resume = false;
  String? error;
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(nikoText('修改机器服务密码', 'Change machine service password')),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(nikoText(
                  '先停止服务和现有连接，再保存新的密码验证凭据。保留原机器 ID、私服和权限设置。之后请使用新密码连接。',
                  'Stop the service and existing connections, then save the new verifier. Keep the machine ID, private server and permissions. Connect using the new password afterwards.')),
              const SizedBox(height: 16),
              TextField(
                key: const Key('unattended-new-password'),
                controller: password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                    labelText: nikoText('新服务密码', 'New service password')),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('unattended-confirm-password'),
                controller: confirmation,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                    labelText: nikoText('再次输入新密码', 'Confirm new password')),
              ),
              CheckboxListTile(
                key: const Key('unattended-password-resume'),
                contentPadding: EdgeInsets.zero,
                value: resume,
                onChanged: (value) => setState(() => resume = value == true),
                title: Text(nikoText('保存后恢复开机运行并立即启动',
                    'Enable startup and resume after saving')),
              ),
              if (error != null)
                Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              Text(nikoText('随后还需本机安装程序和 Windows 系统确认。密码修改未确认时，保持服务停用并重新检查。',
                  'The local installer and Windows will also request confirmation. If the password change is unconfirmed, keep the service disabled and check again.')),
            ],
          )),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(nikoText('取消', 'Cancel'))),
          FilledButton(
            key: const Key('unattended-confirm-password-change'),
            onPressed: () {
              if (password.text.trim().isEmpty ||
                  password.text.runes.length > 128) {
                setState(() => error = nikoText('请输入1至128个字符的服务密码。',
                    'Enter a service password with 1 to 128 characters.'));
              } else if (password.text != confirmation.text) {
                setState(() => error =
                    nikoText('两次输入的密码不同。', 'The two passwords do not match.'));
              } else {
                Navigator.pop(context,
                    NikoUnattendedPasswordChoice(password.text, resume));
              }
            },
            child: Text(nikoText('继续本机确认', 'Continue to local confirmation')),
          ),
        ],
      );
  @override
  void dispose() {
    password.clear();
    confirmation.clear();
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }
}
