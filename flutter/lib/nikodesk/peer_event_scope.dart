import 'dart:convert';

import 'server_scope.dart';

class NikoScopedPeerEvent {
  final String namespace;
  final List<Map<String, dynamic>> peers;
  NikoScopedPeerEvent(this.namespace, this.peers);
}

class NikoScopedOnlineEvent {
  final String namespace;
  final Set<String> onlines;
  final Set<String> offlines;
  NikoScopedOnlineEvent(
      this.namespace, Set<String> onlines, Set<String> offlines)
      : onlines = Set.unmodifiable(onlines),
        offlines = Set.unmodifiable(offlines);
}

/// Native events already carry their originating server. Recheck after the
/// event crosses the asynchronous Flutter dispatch queue as well.
NikoScopedOnlineEvent? nikoScopedOnlineEvent(
    Map<String, dynamic> event, String? currentNamespace) {
  final namespace =
      NikoServerScope.validate(event['nikodesk-server-namespace']);
  if (namespace == null || namespace != currentNamespace) return null;
  Set<String>? ids(Object? value) {
    if (value is! String || value.length > 128 * 1024) return null;
    if (value.isEmpty) return <String>{};
    final parts = value.split(',');
    if (parts.length > 4096 ||
        parts.any((id) => !RegExp(r'^\d{6,16}$').hasMatch(id))) return null;
    final result = parts.toSet();
    return result.length == parts.length ? result : null;
  }

  final onlines = ids(event['onlines']);
  final offlines = ids(event['offlines']);
  if (onlines == null ||
      offlines == null ||
      onlines.length + offlines.length > 4096 ||
      onlines.any(offlines.contains)) return null;
  return NikoScopedOnlineEvent(namespace, onlines, offlines);
}

enum NikoPeerLoadFailure { readFailed, invalidData }

class NikoPeerEventResult {
  final String namespace;
  final NikoScopedPeerEvent? ready;
  final NikoPeerLoadFailure? failure;
  const NikoPeerEventResult._(this.namespace, this.ready, this.failure);
}

/// A delayed event from server A must not be attributed to current server B.
/// Null means foreign/unattributed; a current failed event remains an error.
NikoPeerEventResult? nikoClassifyPeerEvent(
    Map<String, dynamic> event, String? currentNamespace) {
  final namespace =
      NikoServerScope.validate(event['nikodesk-server-namespace']);
  if (namespace == null || namespace != currentNamespace) return null;
  failure(NikoPeerLoadFailure reason) =>
      NikoPeerEventResult._(namespace, null, reason);
  if (event['nikodesk-load-status'] == 'error') {
    return failure(NikoPeerLoadFailure.readFailed);
  }
  if (event['nikodesk-load-status'] != null &&
      event['nikodesk-load-status'] != 'ready') {
    return failure(NikoPeerLoadFailure.invalidData);
  }
  final raw = event['peers'];
  if (raw is! String || raw.length > 4 * 1024 * 1024) {
    return failure(NikoPeerLoadFailure.invalidData);
  }
  try {
    final data = raw.isEmpty ? <dynamic>[] : jsonDecode(raw);
    if (data is! List || data.length > 4096) {
      return failure(NikoPeerLoadFailure.invalidData);
    }
    final seen = <String>{};
    final peers = <Map<String, dynamic>>[];
    for (final item in data) {
      if (item is! Map<String, dynamic> ||
          item['id'] is! String ||
          !RegExp(r'^\d{6,16}$').hasMatch(item['id']) ||
          !seen.add(item['id'])) {
        return failure(NikoPeerLoadFailure.invalidData);
      }
      // Validate fields consumed by Peer.fromJson before any list is replaced.
      for (final key in const [
        'hash',
        'password',
        'username',
        'hostname',
        'platform',
        'alias',
        'forceAlwaysRelay',
        'rdpPort',
        'rdpUsername',
        'loginName',
        'device_group_name',
        'note',
      ]) {
        if (item[key] != null && item[key] is! String) {
          return failure(NikoPeerLoadFailure.invalidData);
        }
      }
      if ((item['tags'] != null && item['tags'] is! List) ||
          (item['same_server'] != null && item['same_server'] is! bool)) {
        return failure(NikoPeerLoadFailure.invalidData);
      }
      peers.add(item);
    }
    return NikoPeerEventResult._(
        namespace, NikoScopedPeerEvent(namespace, peers), null);
  } catch (_) {
    return failure(NikoPeerLoadFailure.invalidData);
  }
}

/// Compatibility adapter for callers that only accept successful events.
NikoScopedPeerEvent? nikoScopedPeerEvent(
        Map<String, dynamic> event, String? currentNamespace) =>
    nikoClassifyPeerEvent(event, currentNamespace)?.ready;
