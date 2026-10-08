import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'connect_dialog.dart';
import 'theme.dart';
import 'ui.dart';

String nikoCredentialSelector(String namespace, String id) =>
    jsonEncode({'schema': 1, 'namespace': namespace, 'id': id});
Future<String> nikoCredentialStatus(String namespace, String id) =>
    bind.mainGetPeerOption(
        id: nikoCredentialSelector(namespace, id),
        key: 'nikodesk-credential-status');

class NikoConnectAuth {
  final String password;
  final bool useSaved;
  final bool? remember;
  const NikoConnectAuth(this.password, {this.useSaved = false, this.remember});
  String? token(String namespace) => remember == null
      ? null
      : jsonEncode({
          'nikodesk_credentials': {
            'schema': 1,
            'namespace': namespace,
            'remember': remember
          }
        });
}

Future<NikoConnectAuth?> nikoAskCredentialConnect(
    BuildContext context, String id, String alias,
    {required String namespace,
    bool native = true,
    bool fileTransfer = false,
    bool autoUseSaved = true,
    Future<String> Function()? statusLoader}) async {
  if (!native) {
    final password = await nikoAskConnectPassword(context, id, alias,
        fileTransfer: fileTransfer);
    return password == null ? null : NikoConnectAuth(password);
  }
  final loadStatus = statusLoader ?? () => nikoCredentialStatus(namespace, id);
  String? initialStatus;
  if (autoUseSaved) {
    var status = 'unavailable';
    try {
      status = await loadStatus().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Manual entry remains available when secure storage cannot be read.
    }
    if (!context.mounted) return null;
    if (status == 'present') {
      return const NikoConnectAuth('', useSaved: true);
    }
    initialStatus = status;
  }
  return showDialog<NikoConnectAuth>(
      context: context,
      builder: (_) => NikoCredentialConnectDialog(
          id: id,
          alias: alias,
          statusLoader: loadStatus,
          initialStatus: initialStatus));
}

class NikoCredentialConnectDialog extends StatefulWidget {
  final String id, alias;
  final Future<String> Function() statusLoader;
  final String? initialStatus;
  const NikoCredentialConnectDialog(
      {super.key,
      required this.id,
      required this.alias,
      required this.statusLoader,
      this.initialStatus});
  @override
  State<NikoCredentialConnectDialog> createState() => _CredentialState();
}

class _CredentialState extends State<NikoCredentialConnectDialog> {
  final _password = TextEditingController();
  bool _remember = false, _loading = true;
  String _status = 'unavailable';
  @override
  void initState() {
    super.initState();
    if (widget.initialStatus != null) {
      _status = widget.initialStatus!;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final status = await widget.statusLoader();
      if (mounted) {
        setState(() {
          _status = status;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _submit() {
    if (_password.text.trim().isEmpty) return;
    Navigator.pop(
        context, NikoConnectAuth(_password.text, remember: _remember));
  }

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          scrollable: true,
          title: Text(nikoText('连接到', 'Connect to')),
          content: SizedBox(
              width: 420,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.alias.isEmpty ? widget.id : widget.alias,
                        style: Theme.of(context).textTheme.titleMedium),
                    if (widget.alias.isNotEmpty) Text(widget.id),
                    const SizedBox(height: 16),
                    if (_loading)
                      const LinearProgressIndicator()
                    else if (_status == 'present') ...[
                      Text(nikoText('此设备在本机有已保存的安全凭据。',
                          'A secure credential for this device is saved locally.')),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                          key: const Key('connect-saved-credential'),
                          onPressed: () => Navigator.pop(context,
                              const NikoConnectAuth('', useSaved: true)),
                          icon: const Icon(Icons.key_outlined),
                          label: Text(nikoText(
                              '使用已保存密码连接', 'Connect with saved password'))),
                      const SizedBox(height: 12),
                    ] else if (_status != 'missing') ...[
                      Text(nikoText('无法读取安全凭据，可输入密码连接；系统存储恢复后才能确认保存。',
                          'Secure credentials are unavailable. Enter a password; saving can only be confirmed after secure storage recovers.')),
                      TextButton(
                          onPressed: () {
                            setState(() => _loading = true);
                            _load();
                          },
                          child: Text(nikoText('重试读取', 'Retry'))),
                    ],
                    TextField(
                        controller: _password,
                        autofocus: true,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        key: const Key('nikodesk-connect-password'),
                        decoration:
                            nikoInput(nikoText('远端密码', 'Remote password')),
                        onSubmitted: (_) => _submit()),
                    CheckboxListTile(
                        key: const Key('remember-secure-password'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(nikoText('保存到本机系统安全存储',
                            'Save to this device’s secure storage')),
                        value: _remember,
                        onChanged: (value) =>
                            setState(() => _remember = value == true)),
                    Text(
                        nikoText(
                            '默认不保存。只有远端认证成功后才保存；输入新密码且不勾选，会在认证成功后移除原来的已保存密码。每次连接仍需远端认证及其要求的验证码。',
                            'Off by default. Save only after remote authentication succeeds. Entering a new password without this option removes the old saved password after authentication. Every connection still requires remote authentication and any required verification code.'),
                        style: Theme.of(context).textTheme.bodySmall),
                  ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(nikoText('取消', 'Cancel'))),
            NikoPrimaryButton(
                key: const Key('nikodesk-connect-submit'),
                compact: true,
                onPressed: _submit,
                child: Text(nikoText('连接', 'Connect'))),
          ]);
}
