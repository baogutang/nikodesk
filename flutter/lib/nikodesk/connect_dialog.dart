import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';

import 'policy.dart';
import 'theme.dart';
import 'ui.dart';

/// NikoDesk controller-side security policy: a session is never started with
/// only a device id. The remote password must be entered in this client
/// before any connect dispatch — no passwordless "ask the remote side"
/// handshake is initiated from here.
Future<String?> nikoAskConnectPassword(
    BuildContext context, String id, String alias,
    {bool fileTransfer = false}) {
  final controller = TextEditingController();
  return showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
            title: Text(nikoText('连接到', 'Connect to')),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                        gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: NikoPalette.deviceAvatarGradient(id)),
                        borderRadius:
                            BorderRadius.circular(NikoShapes.avatar)),
                    child: Icon(
                        fileTransfer
                            ? Icons.folder_rounded
                            : Icons.desktop_windows_rounded,
                        color: Colors.white,
                        size: 17)),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(alias.isEmpty ? id : alias,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('$id · ${fileTransfer ? nikoText('文件传输', 'Files') : nikoText('远程控制', 'Control')}',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(dialog)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ])),
              ]),
              const SizedBox(height: 14),
              TextField(
                  controller: controller,
                  autofocus: true,
                  obscureText: true,
                  key: const Key('nikodesk-connect-password'),
                  decoration:
                      nikoInput(nikoText('远端密码', 'Remote password')),
                  onSubmitted: (value) => Navigator.pop(dialog, value)),
              const SizedBox(height: 8),
              Text(
                  nikoText('本客户端不发起无密码连接；密码不保存。远端仍逐次完成加密握手。',
                      'This client never connects without a password. Nothing is stored; the remote still verifies every session.'),
                  style: TextStyle(
                      fontSize: 11,
                      color:
                          Theme.of(dialog).colorScheme.onSurfaceVariant)),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: Text(nikoText('取消', 'Cancel'))),
              NikoPrimaryButton(
                  key: const Key('nikodesk-connect-submit'),
                  compact: true,
                  onPressed: () => Navigator.pop(dialog, controller.text),
                  child: Text(nikoText('连接', 'Connect'))),
            ],
          ));
}

/// Enforce the policy and dispatch through the real connect path.
Future<void> nikoConnectWithPassword(
  BuildContext context, {
  required String id,
  String alias = '',
  bool fileTransfer = false,
  bool forceRelay = false,
  Future<void> Function(BuildContext, String, bool,
      {bool isFileTransfer, String? password})? onConnect,
  void Function()? onDispatched,
}) async {
  if (!validDeviceId(id)) {
    nikoNotice(
        context,
        nikoText('请输入 6–16 位数字设备 ID。',
            'Enter a numeric device ID with 6–16 digits.'));
    return;
  }
  final password =
      await nikoAskConnectPassword(context, id, alias, fileTransfer: fileTransfer);
  if (password == null) return;
  if (password.isEmpty) {
    nikoNotice(
        context,
        nikoText('安全策略：必须输入远端密码才能发起连接。',
            'Policy: the remote password is required before connecting.'));
    return;
  }
  try {
    if (onConnect != null) {
      await onConnect(context, id, forceRelay,
          isFileTransfer: fileTransfer, password: password);
    } else {
      await connect(context, id,
          forceRelay: forceRelay,
          isFileTransfer: fileTransfer,
          password: password);
    }
    onDispatched?.call();
  } catch (_) {
    if (context.mounted) {
      nikoNotice(
          context,
          nikoText('无法发起连接。检查私服配置及远端 ID 后重试。',
              'Could not start the session. Check server settings and the device ID, then retry.'));
    }
  }
}
