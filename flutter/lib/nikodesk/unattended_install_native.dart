import 'dart:io';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'server_gateway.dart';
import 'server_scope.dart';
import 'unattended_install.dart';

class NativeNikoUnattendedInstallTransport
    implements NikoUnattendedInstallTransport {
  final Rustdesk? bridge;
  const NativeNikoUnattendedInstallTransport({this.bridge});
  Rustdesk get _api => bridge ?? bind;
  @override
  Future<String> begin(String json) =>
      _api.mainNikoUnattendedInstallBegin(json: json);
  @override
  Future<String> status(String jobId) =>
      _api.mainNikoUnattendedInstallStatus(jobId: jobId);
  @override
  Future<String> cancel(String jobId) =>
      _api.mainNikoUnattendedInstallCancel(jobId: jobId);
  @override
  Future<String> current() => _api.mainNikoUnattendedInstallCurrent();
}

// Retain the exact task and an uncertain Begin across settings-page rebuilds.
// The installer remains native-owned; there is no background UI polling here.
NikoUnattendedInstall? _nativeInstall;
NikoUnattendedInstall nativeNikoUnattendedInstall() =>
    _nativeInstall ??= NikoUnattendedInstall(
        supported: const bool.fromEnvironment('NIKODESK') && Platform.isWindows,
        transport: const NativeNikoUnattendedInstallTransport(),
        currentNamespace: () => NikoServerScope.current,
        readNamespace: () async {
          final snapshot = await NativeServerGateway().read();
          return snapshot.config.isValid ? snapshot.namespace : null;
        });
