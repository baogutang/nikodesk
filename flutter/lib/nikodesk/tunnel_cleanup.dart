import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

bool _exact(Map map, Set<String> keys) =>
    map.length == keys.length && map.keys.every(keys.contains);
bool _code(dynamic value) =>
    value is String && RegExp(r'^[a-z0-9_]{1,96}$').hasMatch(value);

class NikoTunnelOwnerIdentity {
  final String sessionId, namespace, peerId;
  const NikoTunnelOwnerIdentity(this.sessionId, this.namespace, this.peerId);
  String get key => '$sessionId/$namespace/$peerId';
  String get requestJson =>
      jsonEncode({'namespace': namespace, 'peer_id': peerId});
  bool same(NikoTunnelOwnerIdentity other) => key == other.key;
  static NikoTunnelOwnerIdentity? parse(Map map) {
    final uuid = map['session_id'],
        namespace = map['namespace'],
        peer = map['peer_id'];
    if (uuid is! String ||
        !RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')
            .hasMatch(uuid) ||
        uuid == '00000000-0000-0000-0000-000000000000' ||
        namespace is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(namespace) ||
        peer is! String ||
        !RegExp(r'^[0-9]{6,16}$').hasMatch(peer)) return null;
    return NikoTunnelOwnerIdentity(uuid, namespace, peer);
  }
}

class NikoTunnelCleanupReply {
  final NikoTunnelOwnerIdentity owner;
  final bool ok, localResourcesClosed;
  final String reason;
  const NikoTunnelCleanupReply._(
      this.owner, this.ok, this.reason, this.localResourcesClosed);
  bool get confirmed => ok && reason == 'closed' && localResourcesClosed;
  static NikoTunnelCleanupReply? parse(
      String raw, NikoTunnelOwnerIdentity expected) {
    if (raw.length > 2048 || utf8.encode(raw).length > 2048) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map ||
          !_exact(map, {
            'session_id',
            'namespace',
            'peer_id',
            'ok',
            'reason',
            'local_resources_closed'
          }) ||
          map['ok'] is! bool ||
          map['local_resources_closed'] is! bool ||
          !_code(map['reason'])) return null;
      final owner = NikoTunnelOwnerIdentity.parse(map);
      if (owner == null || !owner.same(expected)) return null;
      final reply = NikoTunnelCleanupReply._(
          owner, map['ok'], map['reason'], map['local_resources_closed']);
      if (reply.localResourcesClosed && !reply.confirmed) return null;
      return reply;
    } catch (_) {
      return null;
    }
  }
}

/// One bounded notification; an exact original owner may release its CAS guard.
/// It is never inferred from list absence, queued replies, or a Stopped phase.
class NikoTunnelCleanupProofs {
  static final confirmed = ValueNotifier<NikoTunnelCleanupReply?>(null);
  static void record(NikoTunnelCleanupReply reply) {
    if (reply.confirmed) confirmed.value = reply;
  }
}

class NikoTunnelCleanupEntry {
  final NikoTunnelOwnerIdentity owner;
  final String reason;
  const NikoTunnelCleanupEntry(this.owner, this.reason);
}

class NikoTunnelCleanupModel extends ChangeNotifier {
  final Future<String> Function() readRetired;
  final Future<String> Function(NikoTunnelOwnerIdentity) query;
  final Duration timeout;
  List<NikoTunnelCleanupEntry> _entries = const [];
  final Set<String> _busy = {};
  bool _reading = false, _readUnconfirmed = false, _disposed = false;
  final Set<String> _failedQueries = {};
  int _mutation = 0;
  NikoTunnelCleanupModel(
      {required this.readRetired,
      required this.query,
      this.timeout = const Duration(seconds: 5)});
  List<NikoTunnelCleanupEntry> get entries => _entries;
  bool get reading => _reading;
  bool get unconfirmed => _readUnconfirmed || _failedQueries.isNotEmpty;
  bool get visible => _entries.isNotEmpty || unconfirmed;
  bool busy(NikoTunnelCleanupEntry entry) => _busy.contains(entry.owner.key);

  Future<void> refresh() async {
    if (_disposed || _reading) return;
    _reading = true;
    final serial = _mutation;
    notifyListeners();
    List<NikoTunnelCleanupEntry>? entries;
    try {
      final raw = await readRetired().timeout(timeout);
      if (raw.length <= 32768 && utf8.encode(raw).length <= 32768) {
        final map = jsonDecode(raw);
        if (map is Map &&
            _exact(map, {'ok', 'reason', 'owners'}) &&
            map['ok'] == true &&
            _code(map['reason']) &&
            map['owners'] is List &&
            map['owners'].length <= 64) {
          final parsed = <NikoTunnelCleanupEntry>[], keys = <String>{};
          var valid = true;
          for (final item in map['owners']) {
            if (item is! Map ||
                !_exact(
                    item, {'session_id', 'namespace', 'peer_id', 'reason'}) ||
                !_code(item['reason'])) {
              valid = false;
              break;
            }
            final owner = NikoTunnelOwnerIdentity.parse(item);
            if (owner == null || !keys.add(owner.key)) {
              valid = false;
              break;
            }
            parsed.add(NikoTunnelCleanupEntry(owner, item['reason']));
          }
          if (valid) entries = List.unmodifiable(parsed);
        }
      }
    } catch (_) {/* Preserve the last known owners on timeout/error/busy. */}
    if (_disposed) return;
    _reading = false;
    if (serial == _mutation) {
      _readUnconfirmed = entries == null;
      if (entries != null) {
        _entries = entries;
        _failedQueries.removeWhere(
            (key) => !entries!.any((entry) => entry.owner.key == key));
      }
    }
    notifyListeners();
  }

  Future<void> retry(NikoTunnelCleanupEntry entry) async {
    if (_disposed ||
        _busy.contains(entry.owner.key) ||
        !_entries.any((e) => e.owner.same(entry.owner))) return;
    _busy.add(entry.owner.key);
    _mutation++;
    notifyListeners();
    NikoTunnelCleanupReply? reply;
    try {
      reply = NikoTunnelCleanupReply.parse(
          await query(entry.owner).timeout(timeout), entry.owner);
    } catch (_) {
      /* Native owns resources; a timeout is never a release fact. */
    }
    if (_disposed) return;
    _busy.remove(entry.owner.key);
    _mutation++;
    if (reply?.confirmed == true) {
      _entries =
          List.unmodifiable(_entries.where((e) => !e.owner.same(entry.owner)));
      _failedQueries.remove(entry.owner.key);
      NikoTunnelCleanupProofs.record(reply!);
    } else {
      _failedQueries.add(entry.owner.key);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _mutation++;
    super.dispose();
  }
}
