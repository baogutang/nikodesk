import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';

import 'policy.dart';
import 'server_gateway.dart';
import 'server_scope.dart';
import 'theme.dart';
import 'ui.dart';

/// NikoDesk controller-side security policy: a session is never started with
/// only a device id. The remote password must be entered in this client
/// before any connect dispatch — no passwordless "ask the remote side"
/// handshake is initiated from here.
Future<String?> nikoAskConnectPassword(
    BuildContext context, String id, String alias,
    {bool fileTransfer = false}) async {
  return showDialog<String>(
      context: context,
      builder: (_) => _ConnectPasswordDialog(
          id: id, alias: alias, fileTransfer: fileTransfer));
}

class _ConnectPasswordDialog extends StatefulWidget {
  final String id;
  final String alias;
  final bool fileTransfer;
  const _ConnectPasswordDialog(
      {required this.id, required this.alias, required this.fileTransfer});
  @override
  State<_ConnectPasswordDialog> createState() => _ConnectPasswordDialogState();
}

class _ConnectPasswordDialogState extends State<_ConnectPasswordDialog> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.clear();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
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
                        colors: NikoPalette.deviceAvatarGradient(widget.id)),
                    borderRadius: BorderRadius.circular(NikoShapes.avatar)),
                child: Icon(
                    widget.fileTransfer
                        ? Icons.folder_rounded
                        : Icons.desktop_windows_rounded,
                    color: Colors.white,
                    size: 17)),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(widget.alias.isEmpty ? widget.id : widget.alias,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(
                      '${widget.id} · ${widget.fileTransfer ? nikoText('文件传输', 'Files') : nikoText('远程控制', 'Control')}',
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                ])),
          ]),
          const SizedBox(height: 14),
          TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              key: const Key('nikodesk-connect-password'),
              decoration: nikoInput(nikoText('远端密码', 'Remote password')),
              onSubmitted: (value) => Navigator.pop(context, value)),
          const SizedBox(height: 8),
          Text(
              nikoText('本客户端不发起无密码连接；密码不保存。远端仍逐次完成加密握手。',
                  'This client never connects without a password. Nothing is stored; the remote still verifies every session.'),
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(nikoText('取消', 'Cancel'))),
          NikoPrimaryButton(
              key: const Key('nikodesk-connect-submit'),
              compact: true,
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(nikoText('连接', 'Connect'))),
        ],
      );
}

/// Enforce the policy and dispatch through the real connect path.
Future<bool> nikoConnectWithPassword(
  BuildContext context, {
  required String id,
  String alias = '',
  bool fileTransfer = false,
  bool forceRelay = false,
  ServerGateway? gateway,
  String? expectedServerNamespace,
  Future<void> Function(BuildContext, String, bool,
          {bool isFileTransfer, String? password})?
      onConnect,
  void Function()? onDispatched,
}) async {
  if (!validDeviceId(id)) {
    nikoNotice(
        context,
        nikoText('请输入 6–16 位数字设备 ID。',
            'Enter a numeric device ID with 6–16 digits.'));
    return false;
  }
  final namespace = expectedServerNamespace ?? NikoServerScope.current;
  final password = await nikoAskConnectPassword(context, id, alias,
      fileTransfer: fileTransfer);
  if (password == null || !context.mounted) return false;
  return nikoDispatchConnection(context,
      id: id,
      password: password,
      fileTransfer: fileTransfer,
      forceRelay: forceRelay,
      gateway: gateway,
      expectedServerNamespace: namespace,
      onConnect: onConnect,
      onDispatched: onDispatched);
}

Future<bool> nikoDispatchConnection(
  BuildContext context, {
  required String id,
  required String password,
  bool fileTransfer = false,
  bool forceRelay = false,
  ServerGateway? gateway,
  String? expectedServerNamespace,
  Future<void> Function(BuildContext, String, bool,
          {bool isFileTransfer, String? password})?
      onConnect,
  void Function()? onDispatched,
}) async {
  if (!validDeviceId(id) || password.trim().isEmpty) {
    nikoNotice(
        context,
        nikoText('安全策略：必须输入远端密码才能发起连接。',
            'Policy: the remote password is required before connecting.'));
    return false;
  }
  try {
    final current = await (gateway ?? NativeServerGateway()).read();
    if (!context.mounted) return false;
    if (expectedServerNamespace != null &&
        current.namespace != expectedServerNamespace) {
      nikoNotice(
          context,
          nikoText('私服身份已变化，请在当前私服下重新选择设备。',
              'The private server identity changed. Select the device again on the current server.'));
      return false;
    }
    if (!current.config.isValid || !current.enabled) {
      nikoNotice(
          context,
          nikoText('私服未就绪或已暂停，无法发起连接。',
              'The private server is not ready or connections are paused.'));
      return false;
    }
    if (onConnect != null) {
      await onConnect(context, id, forceRelay,
          isFileTransfer: fileTransfer, password: password);
    } else {
      await connect(context, id,
          forceRelay: forceRelay,
          isFileTransfer: fileTransfer,
          password: password, serverNamespace: current.namespace);
    }
    onDispatched?.call();
    return true;
  } catch (_) {
    if (context.mounted) {
      nikoNotice(
          context,
          nikoText('无法发起连接。检查私服配置及远端 ID 后重试。',
              'Could not start the session. Check server settings and the device ID, then retry.'));
    }
    return false;
  }
}
