import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'nightline.dart';
import 'settings_kit.dart';
import 'ui.dart';

const nikoAutoLockOption = 'nikodesk-lock-on-last-control';

class NikoAutoLockSettings extends StatefulWidget {
  final Future<String> Function()? readOptions;
  final Future<void> Function(bool)? writeEnabled;
  const NikoAutoLockSettings({super.key, this.readOptions, this.writeEnabled});

  @override
  State<NikoAutoLockSettings> createState() => _NikoAutoLockSettingsState();
}

class _NikoAutoLockSettingsState extends State<NikoAutoLockSettings> {
  bool _enabled = false, _loading = true, _saving = false;
  String? _error;

  Future<bool> _read() async {
    final options =
        jsonDecode(await (widget.readOptions?.call() ?? bind.mainGetOptions()));
    if (options is! Map<String, dynamic>) {
      throw const FormatException('Invalid options');
    }
    final value = options[nikoAutoLockOption];
    if (value != null && value != '' && value != 'Y' && value != 'N') {
      throw const FormatException('Invalid lock policy');
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
          _error =
              nikoText('无法读取锁屏设置，请重试。', 'Could not read lock settings. Retry.');
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
            key: nikoAutoLockOption, value: enabled ? 'Y' : 'N');
      }
      final confirmed = await _read();
      if (confirmed != enabled) {
        throw StateError('Lock setting was not confirmed');
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
  Widget build(BuildContext context) {
    final title = nikoText('控制结束后自动锁屏', 'Lock after remote control');
    return NikoSettingRow(
        title: title,
        description: nikoText(
            '默认关闭。最后一个控制会话结束后，等待 5 秒锁定本机；本机操作或重连会取消。文件传输不会触发。',
            'Off by default. Lock this computer 5 seconds after the last control session ends. Local input or reconnection cancels it. File transfers do not trigger it.'),
        busy: _loading || _saving,
        trailing: NlSwitch(
            switchKey: const Key('auto-lock-last-control'),
            semanticLabel: title,
            value: _enabled,
            onChanged: _loading || _saving || _error != null ? null : _save),
        below: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          NikoSettingNote(nikoText('主控端主动选择的“断开后锁屏”也遵循同样的会话与取消规则。',
              'The controller’s “Lock after disconnect” also follows these session and cancellation rules.')),
          // The portable client runs in the user session and cannot reach the
          // secure desktop that shows the Windows sign-in screen.
          if (Platform.isWindows) ...[
            const SizedBox(height: NlSpace.s2),
            NikoSettingNote(
                nikoText('便携版 NikoDesk 在 Windows 锁屏后看不到、也操作不了登录界面，远程只会看到黑屏，要回到电脑前解锁。',
                    'After Windows locks, portable NikoDesk cannot see or use the sign-in screen. A remote session only shows black until someone unlocks the computer in person.'),
                tone: NlTone.warn),
          ],
          if (_error != null) ...[
            const SizedBox(height: NlSpace.s2),
            NikoSettingNote(_error!,
                tone: NlTone.danger,
                actionLabel: nikoText('重新读取', 'Reload'),
                onAction: _saving
                    ? null
                    : () {
                        setState(() => _loading = true);
                        _load();
                      }),
          ],
        ]));
  }
}
