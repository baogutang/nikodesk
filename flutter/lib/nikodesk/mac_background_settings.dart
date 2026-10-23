import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'mac_background_agent.dart';
import 'mac_service_settings.dart';
import 'nightline.dart';
import 'settings_kit.dart';
import 'unattended_policy.dart';
import 'ui.dart';

class NikoMacBackgroundSettings extends StatefulWidget {
  final NikoMacBackgroundAgent? agent;
  final NativeUnattendedPolicyGateway? policyGateway;
  final bool Function()? permissionsGranted;

  /// Whether the system background service runs the core instead.
  final Future<bool> Function()? systemServiceInstalled;
  const NikoMacBackgroundSettings(
      {super.key,
      this.agent,
      this.policyGateway,
      this.permissionsGranted,
      this.systemServiceInstalled});
  @override
  State<NikoMacBackgroundSettings> createState() => _SettingsState();
}

Future<bool> _systemServiceInstalled() async {
  try {
    return (await const NikoMacServiceGateway().state()).installed;
  } catch (_) {
    return false;
  }
}

class _SettingsState extends State<NikoMacBackgroundSettings> {
  late final _agent = widget.agent ?? NikoMacBackgroundAgent();
  late final _policyGateway =
      widget.policyGateway ?? NativeUnattendedPolicyGateway();
  final _password = TextEditingController();
  bool _configured = false, _owned = false, _system = false, _busy = true;
  String? _notice;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final enabled = await _agent.configured();
    final owned = await _agent.hasOwnedConfiguration();
    final system =
        await (widget.systemServiceInstalled ?? _systemServiceInstalled)();
    if (mounted) {
      setState(() {
        _configured = enabled;
        _owned = owned;
        _system = system;
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
      final permitted = widget.permissionsGranted?.call() ??
          (bind.mainIsCanScreenRecording(prompt: false) &&
              bind.mainIsProcessTrusted(prompt: false));
      if (!permitted) {
        throw StateError('local_system_permissions_required');
      }
      await _policyGateway.save(password);
      if (!mounted) return;
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
              _ => nikoText('后台设置未完成。已完成的保存步骤不会自动撤销，请核对认证设置后重试。',
                  'Background setup is incomplete. Completed saves are not automatically reverted. Check authentication settings and retry.')
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
  Widget build(BuildContext context) => NikoSettingsGroup(
          title: nikoText('后台恢复', 'Background recovery'),
          description: nikoText(
              '登录后保持真实远控核心运行，异常退出后恢复。需明确设置服务密码并授予系统权限；注销后、FileVault 解锁前不提供被控。',
              'Keep the real remote-control core running after login and recover after a crash. An explicit service password and system permissions are required. Control is unavailable after logout or before FileVault unlock.'),
          trailing: NlButton.quiet(
              small: true,
              icon: NlIcons.refreshCw,
              onPressed: _busy ? null : _refresh,
              label: nikoText('更新状态', 'Refresh status')),
          children: [
            if (_system)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: NlSpace.s3),
                  child: NikoSettingNote(
                      nikoText('后台恢复已由下方的系统后台服务接管。',
                          'Background recovery is provided by the system background service below.'),
                      tone: NlTone.ok,
                      textKey: const Key('niko-mac-background-by-service'))),
            if (!_system && !_configured)
              NikoSettingRow(
                  title: nikoText('本机无人值守密码', 'Unattended password for this computer'),
                  description: nikoText('远程连接本机时输入的密码',
                      'The password a remote session enters to connect to this computer'),
                  busy: _busy,
                  below: Wrap(
                      spacing: NlSpace.s2,
                      runSpacing: NlSpace.s2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                            width: 260,
                            child: NlTextField(
                                controller: _password,
                                enabled: !_busy,
                                obscure: true,
                                autofillHints: const [],
                                hint: nikoText('设置服务密码', 'Set the service password'),
                                inputFormatters: [
                                  LengthLimitingTextInputFormatter(128)
                                ])),
                        NlButton(
                            onPressed: _busy ? null : _enable,
                            label: nikoText('确认无人值守并注册后台恢复',
                                'Confirm unattended access and register recovery')),
                      ])),
            if (!_system && _owned)
              NikoSettingRow(
                  title: nikoText('停用后台恢复', 'Disable background recovery'),
                  description: _configured
                      ? null
                      : nikoText('已有后台配置与当前应用路径不一致。可以重新确认更新配置，或停用原任务。',
                          'An existing background configuration uses a different application path. Confirm again to update it, or disable the previous job.'),
                  trailing: NlButton.ghost(
                      small: true,
                      onPressed: _busy ? null : _disable,
                      label: nikoText('停用', 'Disable'))),
            if (_notice != null || (_busy && (_system || _configured)))
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: NlSpace.s3),
                  child: _notice == null
                      ? const Align(
                          alignment: Alignment.centerLeft,
                          child: NlSpinner(size: 14))
                      : NikoSettingNote(_notice!)),
          ]);
}
