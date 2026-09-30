import 'dart:async';
import 'dart:convert';

import 'server_scope.dart';

enum NikoCapability { terminal, tunnel, camera, voice }

abstract class NikoCapabilityPolicyTransport {
  Future<String> get(String namespace);
  Future<String> set(String namespace, String revision,
      NikoCapability capability, bool allowRequests);
}

class NikoCapabilityPolicyFailure implements Exception {
  final String status;
  const NikoCapabilityPolicyFailure(this.status);
  @override
  String toString() => 'NikoCapabilityPolicyFailure($status)';
}

class NikoCapabilityPolicySnapshot {
  final String namespace;
  final String revision;
  final String generation;
  final Map<NikoCapability, bool> allowRequests;
  final bool conflict;
  NikoCapabilityPolicySnapshot(this.namespace, this.revision, this.generation,
      Map<NikoCapability, bool> allowRequests,
      {this.conflict = false})
      : allowRequests = Map.unmodifiable(allowRequests);
}

/// Settings only permit authenticated requests. Session grants and running
/// resources remain owned and acknowledged by the native connection manager.
class NikoCapabilityPolicy {
  final NikoCapabilityPolicyTransport transport;
  final String? Function() currentNamespace;
  final Duration timeout;
  NikoCapabilityPolicy(this.transport,
      {String? Function()? currentNamespace,
      this.timeout = const Duration(seconds: 5)})
      : currentNamespace = currentNamespace ?? (() => NikoServerScope.current);

  void _check(String namespace) {
    if (NikoServerScope.validate(namespace) == null) {
      throw const NikoCapabilityPolicyFailure('invalid_namespace');
    }
    if (currentNamespace() != namespace) {
      throw const NikoCapabilityPolicyFailure('namespace_changed');
    }
  }

  Future<NikoCapabilityPolicySnapshot> _call(
      String namespace, Future<String> Function() operation,
      {required bool mutation}) async {
    _check(namespace);
    String raw;
    try {
      raw = await operation().timeout(timeout);
    } catch (_) {
      throw NikoCapabilityPolicyFailure(
          mutation ? 'write_unconfirmed' : 'unavailable');
    }
    _check(namespace);
    Never invalid() => throw const NikoCapabilityPolicyFailure('invalid_data');
    if (raw.length > 16 * 1024) invalid();
    dynamic data;
    try {
      data = jsonDecode(raw);
    } catch (_) {
      invalid();
    }
    if (data is! Map<String, dynamic> ||
        data['ok'] is! bool ||
        data['status'] is! String) invalid();
    final status = data['status'] as String;
    final conflict = data['ok'] == false && status == 'conflict';
    if (conflict && !mutation) invalid();
    if (!conflict && data['ok'] != true) {
      const known = {
        'invalid_namespace',
        'namespace_changed',
        'invalid_revision',
        'invalid_kind',
        'invalid_data',
        'exhausted',
        'limit_exceeded',
        'unsupported'
      };
      throw NikoCapabilityPolicyFailure(
          known.contains(status) ? status : 'unavailable');
    }
    if ((!conflict &&
            !(mutation ? {'saved', 'unchanged'} : {'ready'})
                .contains(status)) ||
        data['namespace'] != namespace ||
        NikoServerScope.validate(data['revision']) == null) {
      invalid();
    }
    final generation = data['generation'];
    if (generation is! String ||
        !RegExp(r'^(0|[1-9]\d{0,19})$').hasMatch(generation) ||
        (generation.length == 20 &&
            generation.compareTo('18446744073709551615') > 0)) invalid();
    final policy = data['allow_requests'];
    if (policy is! Map<String, dynamic> ||
        policy.length != 4 ||
        NikoCapability.values.any((kind) => policy[kind.name] is! bool)) {
      invalid();
    }
    return NikoCapabilityPolicySnapshot(
        namespace,
        data['revision'],
        generation,
        {
          for (final kind in NikoCapability.values)
            kind: policy[kind.name] as bool
        },
        conflict: conflict);
  }

  Future<NikoCapabilityPolicySnapshot> get(String namespace) =>
      _call(namespace, () => transport.get(namespace), mutation: false);

  Future<NikoCapabilityPolicySnapshot> set(String namespace, String revision,
      NikoCapability capability, bool enabled) {
    if (NikoServerScope.validate(revision) == null) {
      throw const NikoCapabilityPolicyFailure('invalid_revision');
    }
    return _call(namespace,
        () => transport.set(namespace, revision, capability, enabled),
        mutation: true);
  }
}
