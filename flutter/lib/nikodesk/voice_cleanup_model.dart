import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'cm_capabilities.dart';
import 'voice_session_model.dart';

class NikoVoiceCleanupEntry {
  final String sessionId;
  final NikoVoiceStatus status;
  final String joinState;
  const NikoVoiceCleanupEntry._(this.sessionId, this.status, this.joinState);

  // A SessionID may own more than one retired call. Keep the full call anchor.
  String get key => jsonEncode([
        sessionId,
        status.identity.toJson(),
        status.callNonce,
        status.callEpoch
      ]);
  bool sameSnapshot(NikoVoiceCleanupEntry other) =>
      sessionId == other.sessionId &&
      joinState == other.joinState &&
      status.sameSnapshot(other.status);

  static NikoVoiceCleanupEntry? parse(dynamic raw) {
    if (raw is! Map ||
        raw.keys
            .toSet()
            .difference({'session_id', 'status', 'join_state'}).isNotEmpty ||
        raw['session_id'] is! String ||
        !RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')
            .hasMatch(raw['session_id']) ||
        raw['session_id'] == '00000000-0000-0000-0000-000000000000' ||
        !{'pending', 'failed'}.contains(raw['join_state']) ||
        raw['status'] is! Map) return null;
    final status = NikoVoiceStatus.parse(jsonEncode(raw['status']));
    return status == null
        ? null
        : NikoVoiceCleanupEntry._(raw['session_id'], status, raw['join_state']);
  }
}

class NikoVoiceCleanupSnapshot {
  final List<NikoVoiceCleanupEntry> pending;
  const NikoVoiceCleanupSnapshot._(this.pending);
  static NikoVoiceCleanupSnapshot? parse(String json) {
    if (json.length > 1048576 || utf8.encode(json).length > 1048576) {
      return null;
    }
    try {
      final raw = jsonDecode(json);
      if (raw is! Map ||
          raw.keys.toSet().difference({'ok', 'pending'}).isNotEmpty ||
          raw['ok'] != true ||
          raw['pending'] is! List ||
          raw['pending'].length > 128) return null;
      final pending = <NikoVoiceCleanupEntry>[];
      final keys = <String>{};
      for (final value in raw['pending']) {
        final entry = NikoVoiceCleanupEntry.parse(value);
        if (entry == null || !keys.add(entry.key)) return null;
        pending.add(entry);
      }
      return NikoVoiceCleanupSnapshot._(List.unmodifiable(pending));
    } catch (_) {
      return null;
    }
  }
}

typedef NikoVoiceCleanupTransport = Future<String> Function(
    String sessionId, String json);

class _Operation {
  final int serial;
  final bool busy;
  final String? message;
  const _Operation(this.serial, this.busy, this.message);
}

/// The native retired-owner list is the sole cleanup authority. In particular,
/// a raw Stopped status does not prove its worker has joined successfully.
class NikoVoiceCleanupModel extends ChangeNotifier {
  final Future<String> Function() readPending;
  final NikoVoiceCleanupTransport command;
  final Duration timeout;
  List<NikoVoiceCleanupEntry> _pending = const [];
  final Map<String, _Operation> _operations = {};
  bool _disposed = false, _reading = false, _readAgain = false;
  bool _readUnconfirmed = false;
  int _mutationSerial = 0, _commandSerial = 0;

  NikoVoiceCleanupModel(
      {required this.readPending,
      required this.command,
      this.timeout = const Duration(seconds: 5)});
  List<NikoVoiceCleanupEntry> get pending => _pending;
  bool get reading => _reading;
  bool get readUnconfirmed => _readUnconfirmed;
  bool get visible => _pending.isNotEmpty || _readUnconfirmed;
  bool busy(NikoVoiceCleanupEntry entry) =>
      _operations[entry.key]?.busy == true;
  String? message(NikoVoiceCleanupEntry entry) =>
      _operations[entry.key]?.message;

  bool _current(NikoVoiceCleanupEntry entry) =>
      !_disposed && _pending.any((value) => value.sameSnapshot(entry));

  Future<bool> refresh() async {
    if (_disposed) return false;
    if (_reading) {
      _readAgain = true;
      return false;
    }
    _reading = true;
    final mutation = _mutationSerial;
    notifyListeners();
    try {
      final raw = await readPending().timeout(timeout);
      if (_disposed || mutation != _mutationSerial) return false;
      final snapshot = NikoVoiceCleanupSnapshot.parse(raw);
      if (snapshot == null || !_acceptSnapshot(snapshot)) {
        _readUnconfirmed = true;
        return false;
      }
      _readUnconfirmed = false;
      return true;
    } catch (_) {
      if (!_disposed && mutation == _mutationSerial) _readUnconfirmed = true;
      return false;
    } finally {
      if (!_disposed) {
        _reading = false;
        notifyListeners();
        if (_readAgain) {
          _readAgain = false;
          unawaited(refresh());
        }
      }
    }
  }

  bool _acceptSnapshot(NikoVoiceCleanupSnapshot snapshot) {
    final previous = {for (final item in _pending) item.key: item};
    for (final next in snapshot.pending) {
      final old = previous[next.key];
      if (old == null) continue;
      if (BigInt.parse(next.status.revision) <
              BigInt.parse(old.status.revision) ||
          BigInt.parse(next.status.resourceEpoch) <
              BigInt.parse(old.status.resourceEpoch) ||
          (next.status.revision == old.status.revision &&
              !next.status.sameSnapshot(old.status)) ||
          ({'Revoking', 'RecoveryRequired', 'Stopped'}
                  .contains(old.status.phase) &&
              {'Pending', 'Starting', 'Running'}.contains(next.status.phase)) ||
          (old.status.phase == 'Stopped' && next.status.phase != 'Stopped') ||
          (old.status.selection != null &&
              next.status.selection != null &&
              !old.status.selection!.same(next.status.selection))) {
        return false;
      }
    }
    for (final next in snapshot.pending) {
      final old = previous[next.key];
      if (old != null && !old.sameSnapshot(next)) _operations.remove(next.key);
    }
    _operations.removeWhere(
        (key, _) => !snapshot.pending.any((item) => item.key == key));
    _pending = snapshot.pending;
    return true;
  }

  Future<bool> send(NikoVoiceCleanupEntry captured, String op) async {
    if (!{'query', 'retry_cleanup'}.contains(op) ||
        !_current(captured) ||
        busy(captured)) return false;
    final payload = jsonEncode({
      'identity': captured.status.identity.toJson(),
      'revision': captured.status.revision,
      'op': op
    });
    final serial = ++_commandSerial;
    ++_mutationSerial; // A read started before this command cannot clear it.
    _operations[captured.key] = _Operation(serial, true, null);
    notifyListeners();
    var queued = false;
    try {
      final raw = await command(captured.sessionId, payload).timeout(timeout);
      if (!_current(captured) || _operations[captured.key]?.serial != serial) {
        return false;
      }
      queued = _queuedReply(raw, captured);
      _operations[captured.key] = _Operation(
          serial, false, queued ? 'queued' : 'operation_unconfirmed');
      return queued;
    } catch (_) {
      if (_current(captured) && _operations[captured.key]?.serial == serial) {
        _operations[captured.key] =
            _Operation(serial, false, 'operation_unconfirmed');
      }
      return false;
    } finally {
      if (!_disposed) {
        notifyListeners();
        // Replies only acknowledge a queue. Only the current retired list can
        // remove the row after a successful join, including after a timeout.
        unawaited(refresh());
      }
    }
  }

  bool _queuedReply(String json, NikoVoiceCleanupEntry captured) {
    if (json.length > 8192 || utf8.encode(json).length > 8192) return false;
    try {
      final raw = jsonDecode(json);
      if (raw is! Map ||
          raw.keys.toSet().difference(
              {'ok', 'status', 'identity', 'revision', 'reason'}).isNotEmpty ||
          (raw.containsKey('reason') &&
              (raw['reason'] is! String ||
                  !RegExp(r'^[a-z0-9_]{0,96}$').hasMatch(raw['reason'])))) {
        return false;
      }
      final identity = NikoCapabilityIdentity.parse(raw['identity']);
      return identity != null &&
          identity.sameRequest(captured.status.identity) &&
          raw['revision'] == captured.status.revision &&
          raw['ok'] == true &&
          raw['status'] == 'queued';
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pending = const [];
    _operations.clear();
    super.dispose();
  }
}
