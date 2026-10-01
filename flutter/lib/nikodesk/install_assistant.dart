import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'policy.dart';
import 'server_gateway.dart';
import 'server_settings.dart';
import 'ui.dart';
import 'unattended_install.dart';
import 'unattended_install_native.dart';
import 'unattended_install_view.dart';

// This only selects a visible UI. Native release pins and consent remain mandatory.
bool nikoInstallAssistantRequested() =>
    const bool.fromEnvironment('NIKODESK') &&
    Platform.isWindows &&
    Platform.environment['NIKODESK_SETUP_ASSISTANT'] == '1';

Future<void> showNikoInstallAssistant(BuildContext context) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: const NikoInstallAssistant())));

class NikoInstallAssistant extends StatefulWidget {
  final ServerGateway? gateway;
  final NikoUnattendedInstall? model;
  final String? setup;
  const NikoInstallAssistant({super.key, this.gateway, this.model, this.setup});
  @override
  State<NikoInstallAssistant> createState() => _AssistantState();
}

class _AssistantState extends State<NikoInstallAssistant> {
  late final _gateway = widget.gateway ?? NativeServerGateway();
  late final _model = widget.model ?? nativeNikoUnattendedInstall();
  late final _setup = widget.setup ??
      path.join(
          path.dirname(Platform.resolvedExecutable), 'nikodesk-setup.exe');
  ServerSnapshot? _server;
  bool _loading = true, _editing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _model.addListener(_changed);
    _readServer();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _readServer() async {
    try {
      final snapshot = await _gateway.read();
      if (!mounted) return;
      setState(() {
        _server = snapshot;
        _error = null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _server = null;
          _loading = false;
          _error = nikoText('无法读取私服配置，请重试。',
              'Could not read private-server settings. Retry.');
        });
      }
    }
  }

  Future<void> _configure() async {
    if (_editing || _model.busy || _model.hasJob || _model.uncertain) return;
    setState(() => _editing = true);
    await showNikoServerSettings(context, _gateway,
        _server?.config ?? const PrivateServerConfig('', '', ''));
    if (!mounted) return;
    setState(() => _editing = false);
    await _readServer();
    if (mounted) await _model.refresh();
  }

  @override
  void dispose() {
    _model.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _server?.config.isValid == true && _server?.enabled == true;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
          child: Row(children: [
            Expanded(
                child: Text(nikoText('安装 NikoDesk', 'Install NikoDesk'),
                    style: Theme.of(context).textTheme.titleLarge)),
            IconButton(
                key: const Key('install-assistant-close'),
                tooltip: nikoText('关闭向导', 'Close setup'),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close))
          ])),
      Flexible(
          child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(nikoText('安装文件已随程序提供。先确认自己的私服，再选择是否安装无人值守服务。',
                        'Installation files are included. Confirm your private server, then choose whether to install unattended access.')),
                    const SizedBox(height: 20),
                    Text(nikoText('1. 确认私服', '1. Confirm private server'),
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_loading)
                      const LinearProgressIndicator()
                    else if (_error != null) ...[
                      Text(_error!),
                      TextButton(
                          onPressed: _readServer,
                          child: Text(nikoText('重试', 'Retry')))
                    ] else
                      Text(ready
                          ? nikoText('当前私服：${_server!.config.idServer}',
                              'Current private server: ${_server!.config.idServer}')
                          : nikoText('尚未配置并启用私服。',
                              'A private server is not configured and enabled.')),
                    const SizedBox(height: 8),
                    OutlinedButton(
                        key: const Key('install-assistant-server'),
                        onPressed: _loading ||
                                _editing ||
                                _model.busy ||
                                _model.hasJob ||
                                _model.uncertain
                            ? null
                            : _configure,
                        child:
                            Text(nikoText('配置私服', 'Configure private server'))),
                    const SizedBox(height: 24),
                    Text(
                        nikoText('2. 安装无人值守服务', '2. Install unattended access'),
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    NikoUnattendedInstallView(
                        model: _model, initialSetup: _setup),
                    const SizedBox(height: 20),
                    Text(nikoText('关闭向导后仍可使用当前客户端；安装任务可在设置 → 服务中继续查看。',
                        'You can use this client after closing setup. Continue checking an installation task in Settings > Service.'))
                  ])))
    ]);
  }
}
