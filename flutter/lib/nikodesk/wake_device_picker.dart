import 'dart:io';

import 'package:flutter/material.dart';

import 'device_store.dart';
import 'tunnel_controller.dart';
import 'ui.dart';
import 'wake_on_lan.dart';
import 'wake_on_lan_view.dart';
import 'wake_online.dart';

Future<void> showNikoWakeDevicePicker(
    BuildContext context, NikoTunnelController controller, int port) async {
  if (!WakeSender.proxyReady(controller, port)) return;
  final namespace = controller.namespace;
  // Use the original session namespace, rather than a later global window selection.
  final store = DeviceStore(
      Directory('${DeviceStore.privateDirectory.path}/scopes/$namespace'),
      serverNamespace: namespace);
  try {
    final devices = (await store.load()).devices;
    if (!context.mounted || !WakeSender.proxyReady(controller, port)) return;
    final index = await showDialog<int>(
        context: context,
        builder: (dialog) => AlertDialog(
                title: Text(nikoText('选择待唤醒设备', 'Choose a device to wake')),
                content: SizedBox(
                    width: 440,
                    child: ListView(shrinkWrap: true, children: [
                      for (var index = 0; index < devices.length; index++)
                        ListTile(
                            title: Text(devices[index].title),
                            subtitle: Text(devices[index].id),
                            onTap: () => Navigator.pop(dialog, index)),
                      ListTile(
                          leading: const Icon(Icons.edit_outlined),
                          title: Text(nikoText('手动填写网卡', 'Enter NIC manually')),
                          onTap: () => Navigator.pop(dialog, -1)),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: Text(nikoText('取消', 'Cancel')))
                ]));
    if (index == null ||
        !context.mounted ||
        !WakeSender.proxyReady(controller, port)) return;
    final device = index < 0 ? null : devices[index];
    final profiles = WakeProfileStore(store.directory, namespace);
    final saved = device == null ? null : await profiles.load(device.id);
    final initial = saved == null
        ? null
        : WakeProfile(saved.mac, saved.broadcast,
            port: saved.port, proxyId: controller.peerId);
    if (!context.mounted || !WakeSender.proxyReady(controller, port)) return;
    await showWakeOnLan(context,
        title: nikoText('通过在线代理远程开机', 'Wake through the online proxy'),
        initial: initial,
        fixedProxyId: controller.peerId,
        online:
            device == null ? null : NikoWakeOnlineMonitor(namespace, device.id),
        save: device == null
            ? null
            : (profile) => profiles.save(
                device.id,
                WakeProfile(profile.mac, profile.broadcast,
                    port: profile.port, proxyId: controller.peerId)),
        isCurrent: () async => WakeSender.proxyReady(controller, port),
        send: (profile) => WakeSender.throughProxy(profile, controller, port));
  } catch (_) {
    if (context.mounted) {
      nikoNotice(
          context,
          nikoText('无法读取待唤醒设备或代理会话已结束，请重试。',
              'Could not read wake targets, or the proxy session ended. Retry.'));
    }
  }
}
