import 'dart:convert';

import 'package:flutter_hbb/models/platform_model.dart';

import 'tunnel_controller.dart';
import 'wake_on_lan.dart';

const nikoWakeProxyOption = 'nikodesk-wake-proxy-v1';
bool _namespace(Object? value) =>
    value is String &&
    RegExp(r'^[a-f0-9]{64}$').hasMatch(value) &&
    value != '0' * 64;
bool _keys(Map value, Set<String> keys) =>
    value.length == keys.length && value.keys.every(keys.contains);

class NikoWakeProxyPolicy {
  final String namespace;
  final bool enabled;
  final List<WakeProfile> targets;
  NikoWakeProxyPolicy(this.namespace, this.enabled, List<WakeProfile> targets)
      : targets = List.unmodifiable(targets);

  Map<String, Object> toJson() => {
        'version': 1,
        'namespace': namespace,
        'enabled': enabled,
        'targets': targets.map((target) => target.toJson()).toList()
      };

  static NikoWakeProxyPolicy? parse(Object? value) {
    if (value is! Map ||
        !_keys(value, {'version', 'namespace', 'enabled', 'targets'}) ||
        value['version'] != 1 ||
        !_namespace(value['namespace']) ||
        value['enabled'] is! bool ||
        value['targets'] is! List) return null;
    final targets = <WakeProfile>[];
    final seen = <String>{};
    for (final item in value['targets'] as List) {
      if (item is! Map ||
          !_keys(item, {'mac', 'broadcast', 'port'}) ||
          item['mac'] is! String ||
          item['broadcast'] is! String ||
          item['port'] is! int) return null;
      final target =
          WakeProfile.parse(item['mac'], item['broadcast'], port: item['port']);
      if (target == null ||
          !seen.add('${target.mac}/${target.broadcast}/${target.port}')) {
        return null;
      }
      targets.add(target);
      if (targets.length > 64) return null;
    }
    if (value['enabled'] && targets.isEmpty) return null;
    int address(String value) => value
        .split('.')
        .map(int.parse)
        .fold(0, (total, byte) => (total << 8) | byte);
    targets.sort((a, b) {
      final mac = a.mac.compareTo(b.mac);
      if (mac != 0) return mac;
      final ip = address(a.broadcast).compareTo(address(b.broadcast));
      return ip == 0 ? a.port.compareTo(b.port) : ip;
    });
    return NikoWakeProxyPolicy(value['namespace'], value['enabled'], targets);
  }
}

class NikoWakeProxySnapshot {
  final NikoWakeProxyPolicy policy;
  final String revision, state;
  const NikoWakeProxySnapshot(this.policy, this.revision, this.state);
  static NikoWakeProxySnapshot? parse(String raw, String namespace) {
    if (raw.length > 65536) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          !_keys(
              value, {'schema', 'namespace', 'policy', 'revision', 'state'}) ||
          value['schema'] != 1 ||
          value['namespace'] != namespace ||
          !_namespace(namespace) ||
          value['revision'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['revision']) ||
          !{'disabled', 'paused', 'listening', 'unavailable', 'unsupported'}
              .contains(value['state'])) return null;
      final policy = NikoWakeProxyPolicy.parse(value['policy']);
      if (policy == null ||
          policy.namespace != namespace ||
          value['state'] == 'listening' && !policy.enabled ||
          value['state'] == 'disabled' && policy.enabled) return null;
      return NikoWakeProxySnapshot(policy, value['revision'], value['state']);
    } catch (_) {
      return null;
    }
  }
}

abstract class NikoWakeProxyGateway {
  Future<String> namespace();
  Future<NikoWakeProxySnapshot> read(String namespace);
  Future<void> save(NikoWakeProxyPolicy policy);
}

class NativeNikoWakeProxyGateway implements NikoWakeProxyGateway {
  @override
  Future<String> namespace() async {
    final options = jsonDecode(await bind.mainGetOptions());
    if (options is! Map || !_namespace(options['nikodesk-server-namespace'])) {
      throw StateError('Private server is unavailable');
    }
    return options['nikodesk-server-namespace'];
  }

  @override
  Future<NikoWakeProxySnapshot> read(String namespace) async {
    final raw = await bind.mainGetPeerOption(
        id: jsonEncode({'namespace': namespace}),
        key: 'nikodesk-wake-proxy-status');
    final snapshot = NikoWakeProxySnapshot.parse(raw, namespace);
    if (snapshot == null) {
      throw StateError('Wake receiver status is unconfirmed');
    }
    return snapshot;
  }

  @override
  Future<void> save(NikoWakeProxyPolicy policy) async {
    if (await namespace() != policy.namespace ||
        NikoWakeProxyPolicy.parse(policy.toJson()) == null) {
      throw StateError('Wake receiver policy is invalid');
    }
    await bind.mainSetOption(
        key: nikoWakeProxyOption, value: jsonEncode(policy.toJson()));
  }
}

/// Cross-window discovery reads the real native publisher each time.
class NikoWakeTunnelDirectory {
  final String namespace;
  final Future<String> Function()? readStatus;
  const NikoWakeTunnelDirectory(this.namespace, {this.readStatus});

  Future<List<NikoTunnelStatus>> read() async {
    if (!_namespace(namespace)) {
      throw const FormatException('Invalid wake scope');
    }
    final raw = await (readStatus?.call() ??
        bind.mainGetPeerOption(
            id: jsonEncode({'namespace': namespace}),
            key: 'nikodesk-wake-tunnels'));
    if (raw.length > 128 * 1024) {
      throw const FormatException('Wake tunnels exceed limit');
    }
    final value = jsonDecode(raw);
    if (value is! Map ||
        !_keys(value, {'schema', 'namespace', 'endpoints'}) ||
        value['schema'] != 1 ||
        value['namespace'] != namespace ||
        value['endpoints'] is! List ||
        (value['endpoints'] as List).length > 64) {
      throw const FormatException('Wake tunnels unconfirmed');
    }
    final endpoints = <NikoTunnelStatus>[];
    final ports = <int>{};
    final generations = <String>{};
    for (final item in value['endpoints'] as List) {
      final status = NikoTunnelStatus.parse(jsonEncode(item));
      if (status == null ||
          status.namespace != namespace ||
          status.phase != NikoTunnelPhase.listening ||
          status.remotePhase != 'Running' ||
          status.localResourcesClosed ||
          status.target.host != '127.0.0.1' ||
          status.target.port != 21128 ||
          !ports.add(status.localPort) ||
          !generations.add(status.generation)) {
        throw const FormatException('Wake tunnel unconfirmed');
      }
      endpoints.add(status);
    }
    return List.unmodifiable(endpoints);
  }

  static bool same(NikoTunnelStatus a, NikoTunnelStatus b) =>
      a.namespace == b.namespace &&
      a.peerId == b.peerId &&
      a.generation == b.generation &&
      a.localPort == b.localPort &&
      a.target.same(b.target);

  Future<int> send(WakeProfile profile, NikoTunnelStatus original) =>
      WakeSender.throughVerifiedPort(profile, namespace, original.localPort,
          () async => (await read()).any((current) => same(original, current)));
}
