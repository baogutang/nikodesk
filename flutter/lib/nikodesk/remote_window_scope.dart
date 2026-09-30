import 'dart:convert';

import 'policy.dart';
import 'server_scope.dart';

const nikoRemoteWindowIdentityMethod = 'nikodesk-remote-window-identity';

class NikoRemoteWindowIdentity {
  final int windowId;
  final String peerId;
  final String namespace;

  const NikoRemoteWindowIdentity(this.windowId, this.peerId, this.namespace);

  static NikoRemoteWindowIdentity? parse(Object? value) {
    final data = _object(value);
    if (data == null ||
        data['windowId'] is! int ||
        data['peerId'] is! String ||
        !validDeviceId(data['peerId']) ||
        data['peerId'] != normalizeDeviceId(data['peerId'])) return null;
    final namespace = NikoServerScope.validate(data['serverNamespace']);
    if (namespace == null || (data['windowId'] as int) <= 0) return null;
    return NikoRemoteWindowIdentity(
        data['windowId'], data['peerId'], namespace);
  }

  Map<String, Object> toJson() => {
        'windowId': windowId,
        'peerId': peerId,
        'serverNamespace': namespace,
      };

  bool samePeer(NikoRemoteWindowIdentity other) =>
      peerId == other.peerId && namespace == other.namespace;

  bool sameWindow(NikoRemoteWindowIdentity other) =>
      windowId == other.windowId && samePeer(other);
}

Map<String, dynamic>? _object(Object? value) {
  try {
    final decoded = value is String ? jsonDecode(value) : value;
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

Future<NikoRemoteWindowIdentity?> _readIdentity(
    int windowId, Future<Object?> Function(int) read, Duration timeout) async {
  try {
    final identity =
        NikoRemoteWindowIdentity.parse(await read(windowId).timeout(timeout));
    return identity?.windowId == windowId ? identity : null;
  } catch (_) {
    return null;
  }
}

Future<List<String>> nikoCollectRemoteWindowCoordinates({
  required Object? request,
  required int fromWindowId,
  required Iterable<int> windows,
  required Future<Object?> Function(int) readIdentity,
  required Future<Object?> Function(int, String) readCoordinates,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final origin = NikoRemoteWindowIdentity.parse(request);
  if (origin == null || origin.windowId != fromWindowId) return [];
  final candidates = windows.toList();
  final before = await _readIdentity(origin.windowId, readIdentity, timeout);
  if (before == null || !origin.sameWindow(before)) return [];
  final coordinates = <String>[];
  for (final windowId in candidates) {
    if (windowId == origin.windowId) continue;
    final target = await _readIdentity(windowId, readIdentity, timeout);
    if (target == null || !origin.samePeer(target)) continue;
    try {
      final reply = await readCoordinates(windowId, jsonEncode(target.toJson()))
          .timeout(timeout);
      final identity = NikoRemoteWindowIdentity.parse(reply);
      if (identity != null &&
          target.sameWindow(identity) &&
          _object(reply) != null) {
        coordinates.add(reply is String ? reply : jsonEncode(reply));
      }
    } catch (_) {
      // A matching window can close or change its selected tab during the RPC.
    }
  }
  final after = await _readIdentity(origin.windowId, readIdentity, timeout);
  return after != null && origin.sameWindow(after) ? coordinates : [];
}

Future<String?> nikoRemoteWindowCoordinateReply({
  required Object? request,
  required Object? Function() readIdentity,
  required Future<Map<String, dynamic>?> Function() readCoordinates,
}) async {
  final expected = NikoRemoteWindowIdentity.parse(request);
  final before = NikoRemoteWindowIdentity.parse(readIdentity());
  if (expected == null || before == null || !expected.sameWindow(before)) {
    return null;
  }
  final coordinates = await readCoordinates();
  final after = NikoRemoteWindowIdentity.parse(readIdentity());
  if (coordinates == null || after == null || !before.sameWindow(after)) {
    return null;
  }
  return jsonEncode({...coordinates, ...before.toJson()});
}

List<Map<String, dynamic>> nikoMatchingRemoteCoordinateReplies(
    Object? value, String? peerId, String? namespace, int originWindowId) {
  final origin = NikoRemoteWindowIdentity.parse({
    'windowId': originWindowId,
    'peerId': peerId,
    'serverNamespace': namespace,
  });
  if (origin == null) return [];
  try {
    final list = value is String ? jsonDecode(value) : value;
    if (list is! List) return [];
    return [
      for (final reply in list)
        if (NikoRemoteWindowIdentity.parse(reply) case final identity?)
          if (identity.windowId != originWindowId && origin.samePeer(identity))
            if (_object(reply) case final data?) data,
    ];
  } catch (_) {
    return [];
  }
}
