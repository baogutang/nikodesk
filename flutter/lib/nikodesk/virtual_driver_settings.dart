import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'server_scope.dart';
import 'virtual_driver.dart';
import 'ui.dart';

String _driverReason(String reason) => switch (reason) {
      'administrator_required' => nikoText(
          '请在本机明确以管理员身份重新打开 NikoDesk，再安装或检查驱动。',
          'Explicitly reopen NikoDesk as Administrator locally to install or check the driver.'),
      'os_unsupported' => nikoText(
          '虚拟屏驱动需要 Windows 10 2004 或更新版本；普通远控不受这个门槛影响。',
          'The virtual display driver requires Windows 10 2004 or newer. Ordinary remote control is unaffected.'),
      'signed_package_missing' => nikoText(
          '这个 NikoDesk 目录里没有随附的驱动文件（usbmmidd_v2）。请使用完整安装包或完整 ZIP。',
          'This NikoDesk folder does not contain the bundled driver files (usbmmidd_v2). Use the full installer or the complete ZIP.'),
      'active_displays' => nikoText('请先关闭本客户端创建的虚拟屏，再安装或检查驱动。',
          'Close virtual displays created by this client before installing or checking the driver.'),
      'local_ui_required' => nikoText('请在本机前台打开 NikoDesk，再执行此操作。',
          'Open NikoDesk in the local foreground to continue.'),
      'declined' => nikoText('已取消本次操作。', 'This operation was cancelled.'),
      'scope_changed' || 'another_scope_busy' => nikoText(
          '私服范围已变化，或之前的任务尚未结束。重新读取任务状态后再操作。',
          'The private server changed or a previous task is still running. Reload its status before continuing.'),
      'virtual_display_driver_unavailable' => nikoText(
          '驱动未能安装或接入虚拟屏。请确认使用的是完整包，并以管理员身份重试。',
          'The driver could not be installed or could not attach a display. Use the complete package and retry as Administrator.'),
      'display_creation_unconfirmed' => nikoText(
          '驱动已响应，但系统没有出现虚拟屏。稍后重新检查；持续失败时重启 Windows 再试。',
          'The driver responded but Windows did not show a virtual display. Check again later; restart Windows if this persists.'),
      'cleanup_pending' => nikoText('检查用的虚拟屏尚未确认移除，请重新读取状态。',
          'The display used for the check is not confirmed removed. Reload status.'),
      _ => nikoText('操作结果尚未确认。请重新读取状态，不要重复安装。',
          'The result is unconfirmed. Reload status before attempting another installation.')
    };

class NikoVirtualDriverSettings extends StatefulWidget {
  final NikoVirtualDriver? model;
  const NikoVirtualDriverSettings({super.key, this.model});
  @override
  State<NikoVirtualDriverSettings> createState() => _DriverSettingsState();
}

class _DriverSettingsState extends State<NikoVirtualDriverSettings> {
  late final NikoVirtualDriver _model;
  Timer? _poll;
  @override
  void initState() {
    super.initState();
    _model = widget.model ??
        NikoVirtualDriver(
            command: (json) => bind.mainNikoVirtualDriver(json: json),
            currentNamespace: () => NikoServerScope.current);
    _model.addListener(_changed);
    if (widget.model == null) {
      NikoServerScope.changes.addListener(_scopeChanged);
    }
    _model.refresh();
  }

  void _scopeChanged() {
    _model.scopeChanged();
    _model.refresh();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _poll?.cancel();
    if (_model.needsRefresh && !_model.busy) {
      _poll = Timer(const Duration(seconds: 2), () {
        if (mounted) _model.refresh();
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _model.removeListener(_changed);
    if (widget.model == null) {
      NikoServerScope.changes.removeListener(_scopeChanged);
      _model.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reply = _model.reply;
    final label = reply?.confirmed == true
        ? nikoText('最近一次驱动检查通过', 'The latest driver check passed')
        : switch (reply?.phase) {
            'checking' => nikoText('正在准备', 'Preparing'),
            'awaiting_confirmation' =>
              nikoText('等待本机确认', 'Waiting for local confirmation'),
            'installing' => nikoText('正在安装驱动并检查', 'Installing and checking the driver'),
            'probing' => nikoText('正在接入虚拟屏检查', 'Checking with a temporary display'),
            _ => nikoText('虚拟屏驱动尚未确认就绪',
                'Virtual display driver readiness is unconfirmed')
          };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 16),
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Text(nikoText(
          '使用随 NikoDesk 提供的 Amyuni 已签名驱动，和 RustDesk 是同一个，全机共享。安装和检查都需要本机确认；检查时会短暂接入一块虚拟屏，屏幕可能闪烁。',
          'Uses the signed Amyuni driver bundled with NikoDesk, the same machine-wide driver RustDesk uses. Installing and checking need local confirmation; the check briefly attaches a virtual display and the screen may flicker.')),
      if (reply != null && !reply.elevated)
        Text(_driverReason('administrator_required')),
      if (reply != null && !reply.osSupported)
        Text(_driverReason('os_unsupported')),
      if (_model.notice != null) Text(_driverReason(_model.notice!)),
      if (_model.busy || reply?.running == true)
        const LinearProgressIndicator(),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
            onPressed: _model.canBegin ? _model.install : null,
            icon: const Icon(Icons.extension_outlined),
            label: Text(nikoText('安装驱动', 'Install driver'))),
        OutlinedButton.icon(
            onPressed: _model.canBegin ? _model.probe : null,
            icon: const Icon(Icons.monitor_outlined),
            label: Text(nikoText('检查驱动', 'Check driver'))),
        TextButton(
            onPressed: _model.busy ? null : _model.refresh,
            child: Text(nikoText('重新读取状态', 'Reload status')))
      ])
    ]);
  }
}
