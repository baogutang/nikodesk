import 'dart:convert';

import 'package:flutter_hbb/models/platform_model.dart';

import 'policy.dart';
import 'server_scope.dart';

abstract class SessionAuditApi {
  Future<String> read(String namespace);
  Future<String> clear(String namespace, String revision);
}

class NativeSessionAuditApi implements SessionAuditApi {
  @override
  Future<String> read(String namespace) =>
      bind.mainNikoSessionAudit(namespace: namespace);
  @override
  Future<String> clear(String namespace, String revision) =>
      bind.mainNikoSessionAuditClear(namespace: namespace, revision: revision);
}

class SessionAuditEntry {
  final String session;
  final String? peerId;
  final String role;
  final String kind;
  final String phase;
  final DateTime startedAt;
  final DateTime? authenticatedAt;
  final DateTime? endedAt;
  final int? durationMs;

  const SessionAuditEntry._(
      this.session,
      this.peerId,
      this.role,
      this.kind,
      this.phase,
      this.startedAt,
      this.authenticatedAt,
      this.endedAt,
      this.durationMs);

  factory SessionAuditEntry.parse(Object? raw) {
    if (raw is! Map<String, dynamic>) throw const FormatException();
    final session = raw['session'];
    final peer = raw['peerId'];
    final role = raw['role'];
    final kind = raw['kind'];
    final phase = raw['phase'];
    final duration = raw['durationMs'];
    DateTime? time(String name, {bool required = false}) {
      final value = raw[name];
      if (value == null && !required) return null;
      if (value is! int || value <= 0 || value > 8640000000000000) {
        throw const FormatException();
      }
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }

    if (session is! String ||
        !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(session) ||
        (peer != null && (peer is! String || !validDeviceId(peer))) ||
        !const ['controller', 'receiver'].contains(role) ||
        !const ['desktop', 'file_transfer', 'camera', 'terminal', 'tunnel']
            .contains(kind) ||
        !const [
          'connecting',
          'authenticated',
          'disconnected',
          'not_authenticated',
          'interrupted'
        ].contains(phase) ||
        (duration != null && (duration is! int || duration < 0))) {
      throw const FormatException();
    }
    final start = time('startedAt', required: true)!;
    final auth = time('authenticatedAt');
    final end = time('endedAt');
    if ((auth != null && auth.isBefore(start)) ||
        (end != null && end.isBefore(auth ?? start)) ||
        (end != null) != (duration != null) ||
        (phase == 'connecting' && (auth != null || end != null)) ||
        (phase == 'authenticated' && (auth == null || end != null)) ||
        (phase == 'disconnected' && (auth == null || end == null)) ||
        (phase == 'not_authenticated' && (auth != null || end == null)) ||
        (phase == 'interrupted' && end == null)) throw const FormatException();
    return SessionAuditEntry._(session, peer as String?, role as String,
        kind as String, phase as String, start, auth, end, duration as int?);
  }
}

class CapabilityAuditEvent {
  final String id;
  final String session;
  final String operation;
  final int sequence;
  final String? peerId;
  final String role;
  final String kind;
  final String stage;
  final DateTime at;

  const CapabilityAuditEvent._(this.id, this.session, this.operation,
      this.sequence, this.peerId, this.role, this.kind, this.stage, this.at);

  factory CapabilityAuditEvent.parse(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.keys.any((key) => !const [
              'id',
              'session',
              'operation',
              'sequence',
              'peerId',
              'role',
              'kind',
              'stage',
              'at'
            ].contains(key))) throw const FormatException();
    bool uuid(Object? value) =>
        value is String &&
        value != '00000000-0000-0000-0000-000000000000' &&
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(value);
    final sequence = raw['sequence'];
    final peer = raw['peerId'];
    final at = raw['at'];
    if (!uuid(raw['id']) ||
        !uuid(raw['session']) ||
        !uuid(raw['operation']) ||
        sequence is! int ||
        sequence <= 0 ||
        (peer != null && (peer is! String || !validDeviceId(peer))) ||
        !const ['controller', 'receiver'].contains(raw['role']) ||
        !const ['terminal', 'camera', 'tunnel', 'voice']
            .contains(raw['kind']) ||
        !const [
          'requested',
          'approved',
          'local_started',
          'started',
          'revoking',
          'cleanup_pending',
          'stopped',
          'rejected',
          'request_ended',
          'start_unconfirmed'
        ].contains(raw['stage']) ||
        (raw['stage'] == 'started' && raw['kind'] != 'voice') ||
        at is! int ||
        at <= 0 ||
        at > 8640000000000000) {
      throw const FormatException();
    }
    return CapabilityAuditEvent._(
        raw['id'],
        raw['session'],
        raw['operation'],
        sequence,
        peer as String?,
        raw['role'],
        raw['kind'],
        raw['stage'],
        DateTime.fromMillisecondsSinceEpoch(at, isUtc: true));
  }
}

class SessionAuditSnapshot {
  final String namespace;
  final String revision;
  final String status;
  final bool incomplete;
  final List<SessionAuditEntry> entries;
  final List<CapabilityAuditEvent> activities;
  const SessionAuditSnapshot._(this.namespace, this.revision, this.status,
      this.incomplete, this.entries, this.activities);

  factory SessionAuditSnapshot.parse(String raw, String namespace) {
    if (raw.length > 512 * 1024 ||
        NikoServerScope.validate(namespace) == null) {
      throw const FormatException();
    }
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data['namespace'] != namespace ||
        !const ['ready', 'cleared', 'conflict'].contains(data['status']) ||
        data['ok'] != (data['status'] != 'conflict') ||
        data['incomplete'] is! bool ||
        data['revision'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(data['revision']) ||
        data['entries'] is! List ||
        (data['entries'] as List).length > 200) {
      throw const FormatException();
    }
    final entries =
        (data['entries'] as List).map(SessionAuditEntry.parse).toList();
    if (entries.map((row) => row.session).toSet().length != entries.length) {
      throw const FormatException();
    }
    final rawActivities =
        data.containsKey('activities') ? data['activities'] : [];
    if (rawActivities is! List || rawActivities.length > 200) {
      throw const FormatException();
    }
    final activities = rawActivities.map(CapabilityAuditEvent.parse).toList();
    if (activities.map((row) => row.id).toSet().length != activities.length ||
        activities
                .map((row) => '${row.session}/${row.sequence}')
                .toSet()
                .length !=
            activities.length) throw const FormatException();
    return SessionAuditSnapshot._(
        namespace,
        data['revision'],
        data['status'],
        data['incomplete'],
        List.unmodifiable(entries),
        List.unmodifiable(activities));
  }
}
