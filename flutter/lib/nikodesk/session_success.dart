import 'dart:io';

import 'device_store.dart';
import 'metrics.dart';
import 'server_scope.dart';

/// Session engines do not inherit the main window's active server scope.
Future<void> nikoRecordAuthenticatedDevice({
  required String? namespace,
  required String peerId,
  required SessionMetrics metrics,
  required bool secure,
  required bool fromCache,
  required bool remoteControl,
  Directory? root,
}) async {
  final verified = NikoServerScope.validate(namespace);
  if (verified == null ||
      fromCache ||
      !secure ||
      !remoteControl ||
      !metrics.markAuthenticated()) return;
  await DeviceStore.forServerNamespace(verified, root: root)
      .recordSuccess(peerId, metrics.authenticatedAt!);
}
