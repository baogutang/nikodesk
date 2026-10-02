import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'ui.dart';
import 'virtual_driver_settings.dart';

class NikoVirtualDisplaySettings extends StatefulWidget {
  const NikoVirtualDisplaySettings({super.key});
  @override
  State<NikoVirtualDisplaySettings> createState() => _SettingsState();
}

class _SettingsState extends State<NikoVirtualDisplaySettings> {
  bool _enabled = false, _busy = true;
  String? _error;
  static const _key = 'nikodesk-allow-virtual-display';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<bool> _read() async {
    final raw = jsonDecode(await bind.mainGetOptions());
    if (raw is! Map || !{null, '', 'N', 'Y'}.contains(raw[_key])) {
      throw const FormatException();
    }
    return raw[_key] == 'Y';
  }

  Future<void> _load() async {
    try {
      final enabled = await _read();
      if (mounted) {
        setState(() {
          _enabled = enabled;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            nikoText('无法读取虚拟屏设置。', 'Could not read virtual display settings.'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(bool enabled) async {
    setState(() => _busy = true);
    try {
      await bind.mainSetOption(key: _key, value: enabled ? 'Y' : 'N');
      if (await _read() != enabled) throw StateError('unconfirmed');
      if (mounted) {
        setState(() {
          _enabled = enabled;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = nikoText(
            '保存未确认，请重新读取。', 'Saving is unconfirmed. Reload settings.'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(nikoText(
                '允许连接创建虚拟屏', 'Allow connections to create virtual displays')),
            subtitle: Text(nikoText('默认关闭。需要已认证的远控和键鼠授权；每个屏幕属于创建它的连接，断开或撤权后移除。',
                'Off by default. Remote authentication and keyboard control are required. Each display belongs to its connection and is removed on disconnect or permission revocation.')),
            value: _enabled,
            onChanged: _busy || _error != null ? null : _save),
        Text(
            Platform.isWindows
                ? nikoText(
                    'Windows 使用随附的已签名驱动，首次创建虚拟屏时自动安装。需要通过无人值守服务的机器 ID 连接，或在本机以管理员身份运行客户端。',
                    'Windows uses the bundled signed driver, installed automatically the first time a virtual display is created. Connect through the unattended service’s machine ID, or run the client as Administrator locally.')
                : nikoText(
                    'macOS 会检查系统是否支持虚拟屏。可用时支持 1080p、1440p 和 4K；创建失败会显示原因。',
                    'macOS checks virtual display support. Available displays offer 1080p, 1440p and 4K; creation failures are shown.'),
            style: Theme.of(context).textTheme.bodySmall),
        if (Platform.isWindows) const NikoVirtualDriverSettings(),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) ...[
          Text(_error!),
          TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _busy = true);
                      _load();
                    },
              child: Text(nikoText('重新读取', 'Reload')))
        ]
      ]);
}
