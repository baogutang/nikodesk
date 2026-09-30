import 'dart:convert';

/// Immutable native request identity. Never derive a grant from current settings.
class NikoCapabilityIdentity {
  final int connectionId;
  final String namespace;
  final String peerId;
  final String connectionNonce;
  final String requestNonce;
  final String epoch;

  const NikoCapabilityIdentity(this.connectionId, this.namespace, this.peerId,
      this.connectionNonce, this.requestNonce, this.epoch);

  static NikoCapabilityIdentity? parse(dynamic raw) {
    if (raw is! Map ||
        raw.keys.toSet().difference({
          'connection_id',
          'namespace',
          'peer_id',
          'connection_nonce',
          'request_nonce',
          'epoch'
        }).isNotEmpty) return null;
    final id = raw['connection_id'];
    final namespace = raw['namespace'];
    final peer = raw['peer_id'];
    final connection = raw['connection_nonce'];
    final request = raw['request_nonce'];
    final epoch = raw['epoch'];
    if (id is! int ||
        id <= 0 ||
        namespace is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(namespace) ||
        peer is! String ||
        !RegExp(r'^[0-9]{6,16}$').hasMatch(peer) ||
        connection is! String ||
        !validNonce(connection) ||
        request is! String ||
        !validNonce(request) ||
        epoch is! String ||
        !validEpoch(epoch)) return null;
    return NikoCapabilityIdentity(
        id, namespace, peer, connection, request, epoch);
  }

  static bool validNonce(String value) =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(value) &&
      value != '00000000000000000000000000000000';

  static bool validEpoch(String value) =>
      RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(value) &&
      BigInt.parse(value) <= BigInt.parse('18446744073709551615');

  Map<String, dynamic> toJson() => {
        'connection_id': connectionId,
        'namespace': namespace,
        'peer_id': peerId,
        'connection_nonce': connectionNonce,
        'request_nonce': requestNonce,
        'epoch': epoch,
      };

  bool sameRequest(NikoCapabilityIdentity other) =>
      connectionId == other.connectionId &&
      namespace == other.namespace &&
      peerId == other.peerId &&
      connectionNonce == other.connectionNonce &&
      requestNonce == other.requestNonce &&
      epoch == other.epoch;

  String decision(bool approve) =>
      jsonEncode({'identity': toJson(), 'approve': approve});
  String revoke() => jsonEncode(toJson());
}

class NikoCapabilityStatus {
  final NikoCapabilityIdentity identity;
  final String scope;
  final String phase;
  final String reason;
  final String resourceEpoch;
  const NikoCapabilityStatus(
      this.identity, this.scope, this.phase, this.reason, this.resourceEpoch);

  static NikoCapabilityStatus? parse(String json) {
    if (json.length > 4096) return null;
    try {
      final raw = jsonDecode(json);
      if (raw is! Map ||
          raw['kind'] != 'terminal' ||
          raw.keys.toSet().difference({
            'identity',
            'kind',
            'scope',
            'phase',
            'reason',
            'resource_epoch'
          }).isNotEmpty) return null;
      final identity = NikoCapabilityIdentity.parse(raw['identity']);
      final scope = raw['scope'];
      final phase = raw['phase'];
      final reason = raw['reason'];
      final epoch = raw['resource_epoch'];
      if (identity == null ||
          scope is! String ||
          scope.length > 256 ||
          phase is! String ||
          !{
            'Stopped',
            'Pending',
            'Starting',
            'Running',
            'Revoking',
            'RecoveryRequired'
          }.contains(phase) ||
          reason is! String ||
          reason.length > 512 ||
          epoch is! String ||
          !NikoCapabilityIdentity.validEpoch(epoch)) return null;
      return NikoCapabilityStatus(identity, scope, phase, reason, epoch);
    } catch (_) {
      return null;
    }
  }
}
