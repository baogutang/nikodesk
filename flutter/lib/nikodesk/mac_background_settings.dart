import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'mac_background_agent.dart';
import 'policy.dart';
import 'ui.dart';

class NikoMacBackgroundSettings extends StatefulWidget {
  const NikoMacBackgroundSettings({super.key});
  @override
  State<NikoMacBackgroundSettings> createState() => _SettingsState();
}

class _SettingsState extends State<NikoMacBackgroundSettings> {
  final _agent = NikoMacBackgroundAgent();
  final _password = TextEditingController();
  bool _configured = false, _owned = false, _busy = true;
  String? _notice;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final enabled = await _agent.configured();
    final owned = await _agent.hasOwnedConfiguration();
    if (mounted) {
      setState(() {
        _configured = enabled;
        _owned = owned;
        _busy = false;
      });
    }
  }

  Future<void> _enable() async {
    final password = _password.text;
    _password.clear();
    if (password.trim().isEmpty || password.runes.length > 128) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final raw =
          jsonDecode(await bind.mainGetOptions()) as Map<String, dynamic>;
      final server = PrivateServerConfig.fromOptions(raw);
      if (!server.isValid) throw StateError('private_server_unavailable');
      if (!bind.mainIsCanScreenRecording(prompt: false) ||
          !bind.mainIsProcessTrusted(prompt: false)) {
        throw StateError('local_system_permissions_required');
      }
      if (!await bind.mainSetPermanentPasswordWithResult(password: password)) {
        throw StateError('password_not_saved');
      }
      // Refresh the source before writing; never apply a stale options map.
      final current =
          jsonDecode(await bind.mainGetOptions()) as Map<String, dynamic>;
      final actual = PrivateServerConfig.fromOptions(current);
      if (!actual.isValid ||
          actual.idServer != server.idServer ||
          actual.relayServer != server.relayServer ||
          actual.publicKey != server.publicKey) {
        throw StateError('private_server_changed');
      }
      current['approve-mode'] = 'password';
      current['verification-method'] = 'use-permanent-password';
      await bind.mainSetOptions(json: jsonEncode(current));
      final confirmed =
          jsonDecode(await bind.mainGetOptions()) as Map<String, dynamic>;
      if (confirmed['approve-mode'] != 'password' ||
          confirmed['verification-method'] != 'use-permanent-password') {
        throw StateError('policy_not_confirmed');
      }
      if (!await _agent.enable()) {
        throw StateError('agent_bootstrap_unconfirmed');
      }
      if (mounted) {
        setState(() => _notice = nikoText('后台配置已确认。暂停接收时后台不会连接；实际远控请另行验收。',
            'Background configuration is confirmed. Receiving remains paused when paused in NikoDesk. Verify a real remote session separately.'));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _notice = switch (error.toString()) {
              'Bad state: local_system_permissions_required' => nikoText(
                  '请先在系统设置中授予 NikoDesk 屏幕录制和辅助功能权限。',
                  'Grant NikoDesk Screen Recording and Accessibility in System Settings first.'),
              'Bad state: stable_application_required' => nikoText(
                  '请先把 NikoDesk.app 放入“应用程序”或个人 Applications 文件夹。',
                  'Move NikoDesk.app into Applications or your own Applications folder first.'),
              'Bad state: private_server_unavailable' ||
              'Bad state: private_server_changed' =>
                nikoText('私服配置不可用或已变化，请重新确认。',
                    'Private server settings are unavailable or changed. Confirm them again.'),
              _ => nikoText('后台设置未完成，请更新状态后重试。已经保存的服务密码和设置仍有效。',
                  'Background setup is incomplete. Refresh and retry. Saved password and policies remain in effect.')
            });
      }
    } finally {
      if (mounted) _refresh();
    }
  }

  Future<void> _disable() async {
    setState(() => _busy = true);
    try {
      if (!await _agent.disable()) throw StateError('unconfirmed');
      if (mounted) {
        setState(() => _notice = nikoText('后台任务已停用。普通 NikoDesk 窗口仍可使用。',
            'The background agent is disabled. The ordinary NikoDesk window remains available.'));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _notice = nikoText(
            '停用结果未确认，请更新状态。', 'Disabling is unconfirmed. Refresh status.'));
      }
    } finally {
      if (mounted) _refresh();
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
            nikoText('macOS 无人值守与后台恢复',
                'macOS unattended access and background recovery'),
            style: Theme.of(context).textTheme.titleMedium),
        Text(nikoText(
            '登录后保持真实远控核心运行，异常退出后恢复。需明确设置服务密码并授予系统权限；注销后、FileVault 解锁前不提供被控。',
            'Keep the real remote-control core running after login and recover after a crash. An explicit service password and system permissions are required. Control is unavailable after logout or before FileVault unlock.')),
        if (!_configured) ...[
          TextField(
              controller: _password,
              enabled: !_busy,
              maxLength: 128,
              autofillHints: const [],
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: nikoInput(nikoText(
                  '本机无人值守密码', 'Unattended password for this computer'))),
          FilledButton(
              onPressed: _busy ? null : _enable,
              child: Text(nikoText('确认无人值守并注册后台恢复',
                  'Confirm unattended access and register recovery')))
        ],
        if (_owned)
          OutlinedButton(
              onPressed: _busy ? null : _disable,
              child: Text(nikoText('停用后台恢复', 'Disable background recovery'))),
        if (_owned && !_configured)
          Text(nikoText('已有后台配置与当前应用路径不一致。可以重新确认更新配置，或停用原任务。',
              'An existing background configuration uses a different application path. Confirm again to update it, or disable the previous job.')),
        TextButton(
            onPressed: _busy ? null : _refresh,
            child: Text(nikoText('更新状态', 'Refresh status'))),
        if (_busy) const LinearProgressIndicator(),
        if (_notice != null)
          Text(_notice!, style: Theme.of(context).textTheme.bodySmall)
      ]);
}
