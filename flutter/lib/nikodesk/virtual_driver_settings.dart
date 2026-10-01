import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'server_scope.dart';
import 'virtual_driver.dart';
import 'ui.dart';

String _driverReason(String reason) => switch (reason) {
      'invalid_request' => nikoText('请选择完整签名包中的 NikoDeskIddDriver.inf 文件。',
          'Choose NikoDeskIddDriver.inf from the complete signed package.'),
      'administrator_required' => nikoText(
          '请在本机明确以管理员身份重新打开 NikoDesk，再安装或检查驱动。',
          'Explicitly reopen NikoDesk as Administrator locally to install or check the driver.'),
      'os_unsupported' => nikoText(
          '此虚拟屏驱动需要 Windows 10 2004 或更新版本；普通远控不受这个门槛影响。',
          'This virtual display driver requires Windows 10 2004 or newer. Ordinary remote control is unaffected.'),
      'signed_package_missing' => nikoText(
          '所选文件夹缺少完整签名驱动包。需要同目录的 INF、DLL 和 CAT。',
          'The selected folder is missing a complete signed driver package: INF, DLL and CAT are required together.'),
      'catalog_trust_unconfirmed' => nikoText(
          'Windows 未确认签名、撤销状态或文件所属签名目录，已停止安装。请使用正式签名包；不要导入测试证书或关闭签名验证。',
          'Windows could not confirm the signature, revocation status or catalog membership. Installation stopped. Use a production signed package; do not import test certificates or disable signature checks.'),
      'foreign_or_changed_inf' ||
      'package_invalid' ||
      'package_architecture' ||
      'package_alias_rejected' =>
        nikoText('驱动包的身份、架构或文件内容不匹配，已停止安装。',
            'The package identity, architecture or contents do not match. Installation stopped.'),
      'active_displays' => nikoText('请先关闭本客户端创建的虚拟屏，再安装或检查驱动。',
          'Close virtual displays created by this client before installing or checking the driver.'),
      'local_ui_required' => nikoText('请在本机前台打开 NikoDesk，再执行此操作。',
          'Open NikoDesk in the local foreground to continue.'),
      'declined' => nikoText('已取消本次操作。', 'This operation was cancelled.'),
      'restart_required' => nikoText('Windows 要求重启。请自行重启后重新检查；当前尚未确认就绪。',
          'Windows requires a restart. Restart when convenient and check again; readiness is unconfirmed.'),
      'scope_changed' || 'another_scope_busy' => nikoText(
          '私服范围已变化，或之前的任务尚未结束。重新读取任务状态后再操作。',
          'The private server changed or a previous task is still running. Reload its status before continuing.'),
      'virtual_display_driver_unavailable' ||
      'virtual_display_driver_incompatible' ||
      'virtual_display_driver_not_ready' =>
        nikoText('尚未检测到兼容且就绪的 NikoDesk 独立驱动。请安装正式签名包后重新检查。',
            'A compatible ready NikoDesk driver was not found. Install the production signed package and check again.'),
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

  Future<void> _install() async {
    final namespace = _model.currentNamespace();
    try {
      final selected = await FilePicker.platform.pickFiles(
          dialogTitle: nikoText(
              '选择 NikoDeskIddDriver.inf', 'Choose NikoDeskIddDriver.inf'),
          type: FileType.custom,
          allowedExtensions: ['inf']);
      if (!mounted ||
          namespace != _model.currentNamespace() ||
          !_model.canBegin) return;
      final path = selected?.files.single.path;
      if (path == null) return;
      await _model.install(path);
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText('无法选择驱动文件，请重试。',
                'Could not select the driver file. Try again.'));
      }
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
            'checking' => nikoText('正在核验驱动包', 'Checking the driver package'),
            'awaiting_confirmation' =>
              nikoText('等待本机确认', 'Waiting for local confirmation'),
            'installing' =>
              nikoText('正在安装／修复驱动', 'Installing or repairing the driver'),
            'probing' => nikoText('正在核验真实适配器', 'Checking the actual adapter'),
            _ => nikoText('虚拟屏驱动尚未确认就绪',
                'Virtual display driver readiness is unconfirmed')
          };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 16),
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Text(nikoText(
          '仅安装 NikoDesk 独立驱动。签名校验通过后仍需本机确认；检查会临时创建自己的适配器，不创建屏幕。当前没有随应用提供正式签名驱动包。',
          'Only the independent NikoDesk driver is installed. Signature verification is followed by local confirmation. Checking temporarily creates an owned adapter without adding a screen. A production signed driver package is not currently bundled.')),
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
            onPressed: _model.canBegin ? _install : null,
            icon: const Icon(Icons.extension_outlined),
            label: Text(nikoText('安装／修复驱动', 'Install / repair driver'))),
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
