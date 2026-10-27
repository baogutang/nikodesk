import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'device_store.dart';
import 'nightline.dart';
import 'server_scope.dart';
import 'settings_kit.dart';
import 'ui.dart';

/// Each device's last screen, which the core keeps while a session shows
/// pictures (src/nikodesk/peer_thumbnail.rs). Only this computer has them;
/// "N" turns them off.
const nikoDeviceScreensOption = 'nikodesk-peer-thumbnails';

/// The core's directory: Android's is the parent of the app's private
/// directory, elsewhere they are the same.
Directory get _coreDirectory => Platform.isAndroid
    ? DeviceStore.privateDirectory.parent
    : DeviceStore.privateDirectory;

/// The folder of one server scope's device screens.
Directory? nikoDeviceScreensDirectory(String? namespace) {
  final verified = NikoServerScope.validate(namespace);
  if (verified == null) return null;
  return Directory('${_coreDirectory.path}/scopes/$verified/thumbnails');
}

/// Forgets one device's screen, e.g. when it leaves the list.
Future<void> nikoForgetDeviceScreen(String? namespace, String id) async {
  final directory = nikoDeviceScreensDirectory(namespace);
  if (directory == null) return;
  try {
    await File('${directory.path}/$id.png').delete();
  } catch (_) {
    // Already gone, or never kept.
  }
}

/// Forgets the screens of every server scope.
Future<void> nikoForgetDeviceScreens() async {
  final scopes = Directory('${_coreDirectory.path}/scopes');
  if (!await scopes.exists()) return;
  await for (final scope in scopes.list()) {
    if (scope is! Directory) continue;
    final folder = Directory('${scope.path}/thumbnails');
    if (await folder.exists()) await folder.delete(recursive: true);
  }
}

/// Settings row: whether device tiles show each device's last screen.
class NikoDeviceScreensSetting extends StatefulWidget {
  const NikoDeviceScreensSetting({super.key});

  @override
  State<NikoDeviceScreensSetting> createState() =>
      _NikoDeviceScreensSettingState();
}

class _NikoDeviceScreensSettingState extends State<NikoDeviceScreensSetting> {
  bool _on = bind.mainGetLocalOption(key: nikoDeviceScreensOption) != 'N';

  Future<void> _change(bool on) async {
    setState(() => _on = on);
    await bind.mainSetLocalOption(
        key: nikoDeviceScreensOption, value: on ? 'Y' : 'N');
    if (on) return;
    try {
      await nikoForgetDeviceScreens();
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText('已关闭，但有画面没能删除，请稍后再试。',
                'Turned off, but some pictures could not be deleted. Try again later.'));
      }
    }
  }

  @override
  Widget build(BuildContext context) => NikoSettingRow(
      title: nikoText('设备卡片显示上次画面', 'Show each device’s last screen'),
      description: nikoText(
          '连接时每 30 秒存一张缩小的画面，只留在这台设备上。关掉会删除已存的画面。',
          'While connected, a small picture is kept every 30 seconds, on this device only. Turning this off deletes them.'),
      trailing: NlSwitch(
          value: _on,
          onChanged: _change,
          semanticLabel:
              nikoText('设备卡片显示上次画面', 'Show each device’s last screen')));
}
