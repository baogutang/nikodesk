import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'ui.dart';

const nikoPrivacyOption = 'enable-privacy-mode';

class NikoPrivacySettings extends StatefulWidget {
  final Future<String> Function()? readOptions;
  final Future<void> Function(bool)? writeEnabled;
  const NikoPrivacySettings({super.key, this.readOptions, this.writeEnabled});

  @override
  State<NikoPrivacySettings> createState() => _NikoPrivacySettingsState();
}

class _NikoPrivacySettingsState extends State<NikoPrivacySettings> {
  bool _enabled = false, _loading = true, _saving = false;
  String? _error;

  Future<bool> _read() async {
    final options =
        jsonDecode(await (widget.readOptions?.call() ?? bind.mainGetOptions()));
    if (options is! Map<String, dynamic>) {
      throw const FormatException('Invalid options');
    }
    final value = options[nikoPrivacyOption];
    if (value != null && value != '' && value != 'Y' && value != 'N') {
      throw const FormatException('Invalid privacy policy');
    }
    return value == 'Y';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await _read();
      if (mounted) {
        setState(() {
          _enabled = enabled;
          _error = null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = nikoText('无法读取隐私屏设置，请重试。',
              'Could not read privacy screen settings. Retry.');
        });
      }
    }
  }

  Future<void> _save(bool enabled) async {
    if (_loading || _saving || _error != null) return;
    setState(() => _saving = true);
    try {
      if (widget.writeEnabled != null) {
        await widget.writeEnabled!(enabled);
      } else {
        await bind.mainSetOption(
            key: nikoPrivacyOption, value: enabled ? 'Y' : 'N');
      }
      final confirmed = await _read();
      if (confirmed != enabled) {
        throw StateError('Privacy setting was not confirmed');
      }
      if (mounted) {
        setState(() {
          _enabled = confirmed;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = nikoText(
            '保存未确认，请重新读取设置。', 'Saving was not confirmed. Reload settings.'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SwitchListTile.adaptive(
            key: const Key('allow-privacy-default'),
            contentPadding: EdgeInsets.zero,
            title: Text(nikoText(
                '允许新连接使用隐私屏', 'Allow privacy screen for new connections')),
            subtitle: Text(nikoText(
                '默认关闭。连接仍需通过远控认证；开启后，主控端可主动打开隐私屏。正在进行的连接在本机连接窗口单独授权或撤回。',
                'Off by default. Remote authentication is still required. Once allowed, the controller can enable the privacy screen. Grant or revoke existing connections in this computer’s connection window.')),
            value: _enabled,
            onChanged: _loading || _saving || _error != null ? null : _save),
        Text(
            nikoText(
                'Windows 本机按 Esc 恢复；macOS 按 Control + Option + Shift + Esc 恢复。连接结束自动恢复。Windows 屏幕遮罩需要 Windows 10 2004 或更新版本；其他远控功能不受影响。',
                'Press local Esc on Windows or Control + Option + Shift + Esc on macOS to restore. Disconnecting restores the screen. Windows screen covering requires Windows 10 2004 or later; other remote control features remain available.'),
            style: Theme.of(context).textTheme.bodySmall),
        if (_loading || _saving) const LinearProgressIndicator(),
        if (_error != null) ...[
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          TextButton(
              onPressed: _saving
                  ? null
                  : () {
                      setState(() => _loading = true);
                      _load();
                    },
              child: Text(nikoText('重新读取', 'Reload')))
        ]
      ]);
}
