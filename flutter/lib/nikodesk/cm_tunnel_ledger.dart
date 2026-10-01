import 'package:flutter/foundation.dart';

import 'cm_tunnel.dart';

/// Anchors come only from the authenticated native CM Client snapshot producer.
class NikoCmTunnelLedger extends ChangeNotifier {
  final NikoTunnelTransport command;
  final Duration commandTimeout;
  final Map<int, NikoCmTunnelModel> _models = {};
  bool _disposed = false;

  NikoCmTunnelLedger(
      {required this.command,
      this.commandTimeout = const Duration(seconds: 5)});

  NikoCmTunnelModel? model(int id) => _models[id];
  bool get isNotEmpty => _models.isNotEmpty;
  bool requiresRetention(int id) {
    final current = _models[id];
    return current != null &&
        (current.status.phase != 'Stopped' || current.cleanupUnconfirmed);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  bool anchor(NikoTunnelStatus status, NikoTunnelCmContext context) {
    if (_disposed ||
        !context.identity.sameRequest(status.identity) ||
        (status.cleanupOnly && !context.cleanupOnly) ||
        (context.cleanupOnly &&
            (context.active ||
                !{'Revoking', 'RecoveryRequired', 'Stopped'}
                    .contains(status.phase)))) return false;
    final id = status.identity.connectionId;
    final previous = _models[id];
    if (previous != null &&
        previous.status.identity.sameRequest(status.identity)) {
      if (!previous.status.target.same(status.target) ||
          BigInt.parse(status.revision) <
              BigInt.parse(previous.status.revision) ||
          BigInt.parse(status.resourceEpoch) <
              BigInt.parse(previous.status.resourceEpoch)) return false;
      if (!previous.updateContext(context)) return false;
      return previous.applyStatus(status);
    }
    if (previous != null && requiresRetention(id)) {
      retire(id);
      return false;
    }
    if (!context.cleanupOnly &&
        (!context.active ||
            status.phase != 'Pending' ||
            status.revision != '1' ||
            status.resourceEpoch != '1' ||
            status.addresses.isNotEmpty ||
            status.selectedAddress != null)) return false;
    if (previous == null && _models.length >= 256) return false;
    previous?.removeListener(_changed);
    previous?.dispose();
    late final NikoCmTunnelModel created;
    created = NikoCmTunnelModel.fromVerifiedContext(
        context: context,
        initialStatus: status,
        commandTimeout: commandTimeout,
        transport: (request) {
          if (_disposed ||
              !identical(_models[id], created) ||
              !created.isCurrent(request.captured)) {
            return Future<String>.value('{}');
          }
          return command(request);
        });
    _models[id] = created;
    created.addListener(_changed);
    notifyListeners();
    return true;
  }

  /// A trusted CM lifecycle loss disables grants; it does not prove cleanup.
  void retire(int id) {
    final current = _models[id];
    current?.updateContext(NikoTunnelCmContext.verifiedNative(
        identity: current.status.identity, active: false));
  }

  bool remove(int id) {
    if (_disposed) return false;
    if (requiresRetention(id)) {
      retire(id);
      return false;
    }
    final previous = _models.remove(id);
    previous?.removeListener(_changed);
    previous?.dispose();
    return true;
  }

  void retain(Set<int> ids) {
    for (final id in _models.keys.toList()) {
      if (!ids.contains(id)) remove(id);
    }
  }

  void clear() => retain({});

  @override
  void dispose() {
    _disposed = true;
    for (final current in _models.values) {
      current.removeListener(_changed);
      current.dispose();
    }
    _models.clear();
    super.dispose();
  }
}
