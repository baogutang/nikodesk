import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device_store.dart';
import 'policy.dart';

/// A locally recorded session attempt. Records what the user asked this
/// client to start; remote-side acceptance is verified per session and is
/// not implied by an entry existing here.
class SessionLogEntry {
  final String id;
  final String alias;
  final bool fileTransfer;
  final bool forceRelay;
  final DateTime startedAt;

  const SessionLogEntry(
      {required this.id,
      this.alias = '',
      this.fileTransfer = false,
      this.forceRelay = false,
      required this.startedAt});

  String get title => alias.isEmpty ? id : alias;

  factory SessionLogEntry.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final alias = json['alias'];
    final fileTransfer = json['fileTransfer'];
    final forceRelay = json['forceRelay'];
    final startedAt = json['startedAt'];
    if (id is! String ||
        !validDeviceId(id) ||
        alias is! String ||
        alias.length > 100 ||
        fileTransfer is! bool ||
        forceRelay is! bool ||
        startedAt is! String ||
        DateTime.tryParse(startedAt) == null) {
      throw const FormatException('Invalid session record');
    }
    return SessionLogEntry(
        id: normalizeDeviceId(id),
        alias: alias,
        fileTransfer: fileTransfer,
        forceRelay: forceRelay,
        startedAt: DateTime.parse(startedAt).toUtc());
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'alias': alias,
        'fileTransfer': fileTransfer,
        'forceRelay': forceRelay,
        'startedAt': startedAt.toIso8601String(),
      };
}

class SessionLogResult {
  final List<SessionLogEntry> entries;
  final bool recovered;
  const SessionLogResult(this.entries, {this.recovered = false});
}

/// Append-only local history of sessions this client initiated, persisted
/// next to the device directory. Entries are capped; nothing leaves the Mac.
class SessionLogStore {
  static final SessionLogStore instance = SessionLogStore._default();
  static const keepMax = 200;

  final Directory directory;
  Future<void> _pending = Future.value();
  SessionLogStore(this.directory);
  SessionLogStore._default()
      : directory = DeviceStore.instance.directory;

  File get file => File('${directory.path}/sessions.json');
  File get _backup => File('${file.path}.bak');

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _pending = _pending.then((_) async {
      try {
        await directory.create(recursive: true);
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<SessionLogResult> load() => _locked(_read);

  /// Unlocked read used by mutating helpers that already hold the queue;
  /// calling load() there would wait for itself and deadlock.
  Future<SessionLogResult> _read() async {
    String? data;
    var recovered = false;
    try {
      data = await file.readAsString();
    } catch (_) {
      data = null;
    }
    var parsed = _decode(data);
    if (parsed == null) {
      recovered = data != null && data.trim().isNotEmpty;
      try {
        parsed = _decode(await _backup.readAsString());
      } catch (_) {
        parsed = null;
      }
    }
    if (parsed == null) {
      try {
        await file.writeAsString('[]', flush: true);
      } catch (_) {}
      return SessionLogResult(const [], recovered: recovered);
    }
    return SessionLogResult(parsed);
  }

  List<SessionLogEntry>? _decode(String? data) {
    if (data == null || data.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! List) return null;
      final entries = <SessionLogEntry>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          entries.add(SessionLogEntry.fromJson(item));
        }
      }
      return entries;
    } catch (_) {
      return null;
    }
  }

  Future<void> record(SessionLogEntry entry) => _locked(() async {
        final current = (await _read()).entries;
        final next = [entry, ...current];
        if (next.length > keepMax) {
          next.removeRange(keepMax, next.length);
        }
        await _write(next);
      });

  Future<void> removeAt(DateTime startedAt) => _locked(() async {
        final current = (await _read()).entries;
        await _write(
            current.where((e) => e.startedAt != startedAt).toList());
      });

  Future<void> clear() => _locked(() async => _write(const []));

  Future<void> _write(List<SessionLogEntry> entries) async {
    final payload = jsonEncode(entries.map((e) => e.toJson()).toList());
    if (await file.exists()) {
      try {
        await file.copy(_backup.path);
      } catch (_) {}
    }
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    await temporary.rename(file.path);
  }
}
