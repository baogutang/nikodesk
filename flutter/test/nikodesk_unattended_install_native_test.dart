import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/nikodesk/unattended_install.dart';
import 'package:flutter_hbb/nikodesk/unattended_install_native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_unattended_install_test.dart'
    show installJob, installNamespace, installReply, installIdle;

// Substitute for the real generated Rustdesk interface, not an installer.
class _InstallBridge implements Rustdesk {
  final calls = <String>[];
  Map<String, dynamic>? request;
  @override
  Future<String> mainNikoUnattendedInstallBegin(
      {required String json, dynamic hint}) async {
    calls.add('begin');
    request = jsonDecode(json);
    return installReply();
  }

  @override
  Future<String> mainNikoUnattendedInstallStatus(
      {required String jobId, dynamic hint}) async {
    calls.add('status:$jobId');
    return installReply(reason: 'in_progress');
  }

  @override
  Future<String> mainNikoUnattendedInstallCancel(
      {required String jobId, dynamic hint}) async {
    calls.add('cancel:$jobId');
    return installReply(reason: 'cancel_requested');
  }

  @override
  Future<String> mainNikoUnattendedInstallCurrent({dynamic hint}) async {
    calls.add('current');
    return installIdle();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
      'production adapter calls only four generated APIs with original job and ephemeral begin JSON',
      () async {
    final bridge = _InstallBridge();
    final adapter = NativeNikoUnattendedInstallTransport(bridge: bridge);
    final model = NikoUnattendedInstall(
        transport: adapter,
        readNamespace: () async => installNamespace,
        currentNamespace: () => installNamespace);
    addTearDown(model.dispose);
    expect(bridge.calls, isEmpty);
    await model.refresh();
    await model.begin(
        selectedSetup: r'C:\fixture\setup.exe', password: 'synthetic');
    await model.refresh();
    await model.cancel();
    expect(bridge.calls,
        ['current', 'begin', 'status:$installJob', 'cancel:$installJob']);
    expect(bridge.request!.keys.toSet(), {
      'action',
      'expected_namespace',
      'selected_setup',
      'password',
      'start_after_commit',
      'allow_virtual_display',
      'lock_on_disconnect',
      'allow_privacy',
      'allow_remote_restart'
    });
    expect(bridge.request!['expected_namespace'], installNamespace);
    expect(bridge.request!['start_after_commit'], false);
    expect(model.installConfirmed, false);
    expect(model.reply!.jobId, installJob);
  });
  test(
      'production UI model cache preserves original ownership across page reconstruction',
      () async {
    final first = nativeNikoUnattendedInstall(),
        next = nativeNikoUnattendedInstall();
    expect(identical(first, next), true);
    if (!Platform.isWindows || !const bool.fromEnvironment('NIKODESK')) {
      expect(first.supported, false);
      await first.refresh();
      expect(first.hasJob, false);
    }
  });
}
