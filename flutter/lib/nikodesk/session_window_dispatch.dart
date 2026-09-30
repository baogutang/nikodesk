import 'dart:convert';

import 'server_scope.dart';
import 'window_scope.dart';

String nikoSessionWindowMessage(
    Map<String, dynamic> params, String? namespace) {
  final validated = NikoServerScope.validate(namespace);
  if (validated == null) {
    throw StateError('Private server identity is required');
  }
  return jsonEncode({...params, 'serverNamespace': validated});
}

Future<int?> nikoActivatePeerWindow(
    Iterable<int> windows,
    String? namespace,
    Future<Object?> Function(int) readNamespace,
    Future<Object?> Function(int) activatePeer) async {
  if (NikoServerScope.validate(namespace) == null) {
    throw StateError('Private server identity is required');
  }
  final matching = await nikoMatchingWindows(
      windows.toList(), namespace, readNamespace);
  for (final window in matching) {
    try {
      if (await activatePeer(window).timeout(const Duration(seconds: 2)) ==
          true) {
        return window;
      }
    } catch (_) {
      // Windows may close between the identity query and activation.
    }
  }
  return null;
}
