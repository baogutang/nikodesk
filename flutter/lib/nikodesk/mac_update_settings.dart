import 'dart:io';

import 'package:flutter/material.dart';

import 'mac_service_settings.dart';
import 'mac_update_install.dart';
import 'ui.dart';

/// "Install now" for a verified, staged update; shown only when the
/// privileged service can install it.
class NikoMacUpdateInstallButton extends StatefulWidget {
  final Directory staging;
  final void Function(String message) onStatus;
  final NikoMacServiceGateway gateway;
  final NikoMacUpdateInstaller? installer;
  final Future<void> Function() relaunch;
  const NikoMacUpdateInstallButton(
      {super.key,
      required this.staging,
      required this.onStatus,
      this.gateway = const NikoMacServiceGateway(),
      this.installer,
      this.relaunch = nikoRelaunch});

  @override
  State<NikoMacUpdateInstallButton> createState() => _InstallButtonState();
}

class _InstallButtonState extends State<NikoMacUpdateInstallButton> {
  bool _ready = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.gateway.state().then((state) {
      if (mounted) setState(() => _ready = state.canInstallUpdates);
    });
  }

  Future<void> _install() async {
    setState(() => _busy = true);
    widget.onStatus(nikoText('正在安装，系统后台服务会再校验一次安装包…',
        'Installing; the system background service checks the package once more…'));
    final installer =
        widget.installer ?? NikoMacUpdateInstaller(service: widget.gateway);
    final result = await installer.install(widget.staging);
    widget.onStatus(nikoInstallMessage(result));
    if (result.state == NikoInstallState.installed) {
      await widget.relaunch();
      return;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();
    return Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
            key: const Key('nikodesk-update-install-now'),
            onPressed: _busy ? null : _install,
            child: Text(nikoText('立即安装并重新打开', 'Install now and reopen'))));
  }
}

/// Remind or install by itself, and what the last automatic check found.
class NikoUpdateModeSettings extends StatefulWidget {
  final NikoMacServiceGateway gateway;
  final NikoUpdateSchedule? schedule;
  final NikoUpdateMode Function() readMode;
  final Future<void> Function(NikoUpdateMode mode) writeMode;
  const NikoUpdateModeSettings(
      {super.key,
      this.gateway = const NikoMacServiceGateway(),
      this.schedule,
      this.readMode = nikoUpdateMode,
      this.writeMode = setNikoUpdateMode});

  @override
  State<NikoUpdateModeSettings> createState() => _ModeState();
}

class _ModeState extends State<NikoUpdateModeSettings> {
  late NikoUpdateMode _mode = widget.readMode();
  bool _serviceReady = false;

  NikoUpdateSchedule get _schedule =>
      widget.schedule ?? NikoUpdateSchedule.instance;

  @override
  void initState() {
    super.initState();
    widget.gateway.state().then((state) {
      if (mounted) setState(() => _serviceReady = state.canInstallUpdates);
    });
  }

  Future<void> _change(NikoUpdateMode? mode) async {
    if (mode == null) return;
    setState(() => _mode = mode);
    await widget.writeMode(mode);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(nikoText('有新版本时', 'When a new version is out'))),
        DropdownButton<NikoUpdateMode>(
            key: const Key('nikodesk-update-mode'),
            value: _mode,
            items: [
              DropdownMenuItem(
                  value: NikoUpdateMode.remind,
                  child: Text(nikoText('提醒我', 'Remind me'))),
              DropdownMenuItem(
                  value: NikoUpdateMode.auto,
                  enabled: _serviceReady,
                  child: Text(nikoText('空闲时自动安装', 'Install when idle'))),
            ],
            onChanged: _change),
      ]),
      Text(
          _mode == NikoUpdateMode.auto && _serviceReady
              ? nikoText('每 6 小时检查一次正式版。下载并校验通过后，在没有远控会话时安装并重新打开 NikoDesk。',
                  'Checks for stable releases every 6 hours. A verified release is installed and NikoDesk reopened when no remote session is active.')
              : _serviceReady
                  ? nikoText('每 6 小时检查一次正式版，有新版本时提醒你。',
                      'Checks for stable releases every 6 hours and reminds you of a new one.')
                  : nikoText('每 6 小时检查一次正式版，有新版本时提醒你。自动安装需要先在“无人值守”中安装系统后台服务。',
                      'Checks for stable releases every 6 hours and reminds you of a new one. Installing by itself needs the system background service under Unattended access.'),
          style: TextStyle(fontSize: 11.5, color: muted)),
      ValueListenableBuilder(
          valueListenable: _schedule.available,
          builder: (context, release, _) => release == null
              ? const SizedBox.shrink()
              : Text(
                  nikoText('自动检查发现 ${release.displayName}，点“检查更新”即可下载。',
                      'The automatic check found ${release.displayName}; use “Check for updates” to download it.'),
                  key: const Key('nikodesk-update-available'))),
    ]);
  }
}
