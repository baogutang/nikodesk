import 'package:flutter/foundation.dart';

import 'voice_session_model.dart';
import 'voice_session_owner.dart';

class NikoCmVoiceLedger extends ChangeNotifier {
  final NikoVoiceTransport command;
  final Future<String> Function(NikoVoiceStatus) readAvailability;
  final Duration availabilityTimeout;
  final Map<int, NikoVoiceSessionModel> _models = {};
  final Map<int, NikoVoiceCatalog> _catalogs = {};
  final Map<int, int> _serials = {};
  bool _disposed = false;
  NikoCmVoiceLedger(
      {required this.command,
      required this.readAvailability,
      this.availabilityTimeout = const Duration(seconds: 5)});
  NikoVoiceSessionModel? model(int id) => _models[id];
  bool get isNotEmpty => _models.isNotEmpty;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Only Client.fromJson's authenticated native snapshot calls this method.
  bool anchor(NikoVoiceStatus status,
      {required bool cleanupOnly, NikoVoiceCatalog? catalog}) {
    if (_disposed ||
        (cleanupOnly &&
            !{'Revoking', 'RecoveryRequired', 'Stopped'}
                .contains(status.phase))) return false;
    final id = status.identity.connectionId;
    final previous = _models[id];
    if (previous != null) {
      if (previous.status.sameCall(status)) {
        if (previous.cleanupOnly == cleanupOnly) {
          if (!previous.applyStatus(status)) return false;
          if (catalog != null) acceptCatalog(catalog);
          if (!cleanupOnly) refreshAvailability(id);
          return true;
        }
        // Only this trusted Client snapshot can retire the row. A normal status
        // event cannot upgrade its cleanup authority or revive an old call.
        final before = previous.status;
        if (previous.cleanupOnly ||
            !cleanupOnly ||
            BigInt.parse(status.revision) < BigInt.parse(before.revision) ||
            (status.revision == before.revision &&
                !before.sameSnapshot(status)) ||
            BigInt.parse(status.resourceEpoch) <
                BigInt.parse(before.resourceEpoch) ||
            (before.phase == 'Stopped' && status.phase != 'Stopped') ||
            (before.selection != null &&
                status.selection != null &&
                !before.selection!.same(status.selection))) return false;
      } else if (previous.status.phase != 'Stopped' ||
          previous.cleanupUnconfirmed ||
          BigInt.parse(status.callEpoch) <=
              BigInt.parse(previous.status.callEpoch)) {
        return false;
      }
    } else if (_models.length >= 256) {
      return false;
    }
    previous?.removeListener(_changed);
    previous?.dispose();
    _catalogs.remove(id);
    late final NikoVoiceSessionModel created;
    created = NikoVoiceSessionModel(
        anchor: status,
        cleanupOnly: cleanupOnly,
        transport: (request) async {
          if (_disposed ||
              !identical(_models[id], created) ||
              !created.isCurrent(request.captured)) return '{}';
          if (request.op == 'query' && !cleanupOnly) {
            await refreshAvailability(id);
          }
          if (_disposed ||
              !identical(_models[id], created) ||
              !created.isCurrent(request.captured)) return '{}';
          return command(request);
        });
    _models[id] = created;
    created.addListener(_changed);
    if (catalog != null) acceptCatalog(catalog);
    if (!cleanupOnly) refreshAvailability(id);
    notifyListeners();
    return true;
  }

  Future<void> refreshAvailability(int id) async {
    final captured = _models[id];
    if (_disposed || captured == null || captured.cleanupOnly) return;
    final status = captured.status;
    final serial = (_serials[id] ?? 0) + 1;
    _serials[id] = serial;
    NikoVoiceAvailability value = NikoVoiceAvailability.unknown;
    try {
      final raw = await readAvailability(status).timeout(availabilityTimeout);
      value = NikoVoiceAvailabilitySnapshot.parse(raw)?.receiverAvailability ??
          NikoVoiceAvailability.unknown;
    } catch (_) {}
    if (_disposed ||
        serial != _serials[id] ||
        !identical(_models[id], captured) ||
        !captured.status.sameCall(status)) return;
    captured.setAvailability(value);
    final catalog = _catalogs[id];
    if (catalog != null) captured.applyCatalog(catalog);
  }

  bool status(NikoVoiceStatus incoming) {
    final current = _models[incoming.identity.connectionId];
    if (_disposed || current == null || !current.applyStatus(incoming)) {
      return false;
    }
    final catalog = _catalogs[incoming.identity.connectionId];
    if (catalog != null && catalog.revision != incoming.revision) {
      _catalogs.remove(incoming.identity.connectionId);
    }
    return true;
  }

  bool acceptCatalog(NikoVoiceCatalog incoming) {
    final current = _models[incoming.identity.connectionId];
    if (_disposed ||
        current == null ||
        current.cleanupOnly ||
        !current.status.identity.sameRequest(incoming.identity) ||
        current.status.revision != incoming.revision ||
        current.status.phase != 'Pending' ||
        current.status.microphonePermission != incoming.microphonePermission) {
      return false;
    }
    final cached = _catalogs[incoming.identity.connectionId];
    if (cached != null &&
        BigInt.parse(incoming.rosterRevision) <=
            BigInt.parse(cached.rosterRevision)) return false;
    _catalogs[incoming.identity.connectionId] = incoming;
    final accepted = current.applyCatalog(incoming);
    return accepted || current.availability == NikoVoiceAvailability.unknown;
  }

  void remove(int id) {
    _serials.remove(id);
    _catalogs.remove(id);
    final previous = _models.remove(id);
    previous?.removeListener(_changed);
    previous?.dispose();
  }

  void retain(Set<int> ids) {
    for (final id in _models.keys.toList()) {
      if (!ids.contains(id)) remove(id);
    }
  }

  void clear() {
    for (final id in _models.keys.toList()) {
      remove(id);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    clear();
    super.dispose();
  }
}
