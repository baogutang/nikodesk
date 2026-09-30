import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device_store.dart';
import 'server_scope.dart';
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
  static SessionLogStore get instance => SessionLogStore._default();
  static const keepMax = 200;

  final Directory directory;
  final String? serverNamespace;
  Future<void> _pending = Future.value();
  SessionLogStore(this.directory, {this.serverNamespace});
  SessionLogStore._default()
      : directory = DeviceStore.instance.directory,
        serverNamespace = DeviceStore.instance.serverNamespace;

  File get file => File('${directory.path}/sessions.json');
  File get _backup => File('${file.path}.bak');

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _pending = _pending.then((_) async {
      try {
        await directory.create(recursive: true);
        result.complete(await withNikoStoreLock('${file.path}.lock', action));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<SessionLogResult> load() => _locked(_read);

  Future<int> importUnscoped(Directory source) => _locked(() async {
        if (NikoServerScope.validate(serverNamespace) == null ||
            source.absolute.path == directory.absolute.path) {
          throw StateError('A confirmed private server is required for import');
        }
        final legacy = SessionLogStore(source);
        if (await FileSystemEntity.type(legacy.file.path, followLinks: false) ==
            FileSystemEntityType.notFound) return 0;
        if (await source.resolveSymbolicLinks() ==
            await directory.resolveSymbolicLinks()) {
          throw StateError('Import source and destination are the same');
        }
        final imported =
            await withNikoStoreLock('${legacy.file.path}.lock', () async {
          if (await FileSystemEntity.type(legacy.file.path,
                  followLinks: false) !=
              FileSystemEntityType.file) {
            throw const FormatException('Invalid legacy history');
          }
          final entries = legacy._decode(await legacy.file.readAsString());
          if (entries == null) {
            throw const FormatException('Invalid legacy history');
          }
          return entries;
        });
        final entries = (await _read()).entries.toList();
        String key(SessionLogEntry entry) =>
            '${entry.id}/${entry.startedAt.toUtc().toIso8601String()}/${entry.fileTransfer}/${entry.forceRelay}';
        final keys = entries.map(key).toSet();
        final added = imported.where((entry) => keys.add(key(entry))).toList();
        entries.addAll(added);
        entries.sort((a, b) => b.startedAt.compareTo(a.startedAt));
        if (added.isNotEmpty) await _write(entries.take(keepMax).toList());
        return added.length;
      });

  /// Unlocked read used by mutating helpers that already hold the queue;
  /// calling load() there would wait for itself and deadlock.
  Future<SessionLogResult> _read() async {
    final data = await file.exists() ? await file.readAsString() : null;
    var parsed = _decode(data);
    if (parsed != null) return SessionLogResult(parsed);
    if (data != null) {
      await file.copy(
          '${file.path}.corrupt.$pid.${DateTime.now().microsecondsSinceEpoch}');
    }
    final backupExists = await _backup.exists();
    if (backupExists) {
      parsed = _decode(await _backup.readAsString());
      if (parsed == null) throw const FormatException('Invalid session backup');
    }
    if (data == null && !backupExists) return const SessionLogResult([]);
    await _write(parsed ?? const [], keepBackup: false);
    return SessionLogResult(parsed ?? const [], recovered: true);
  }

  List<SessionLogEntry>? _decode(String? data) {
    if (data == null || data.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! List || decoded.length > keepMax) return null;
      final entries = <SessionLogEntry>[];
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) return null;
        entries.add(SessionLogEntry.fromJson(item));
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
        await _write(current.where((e) => e.startedAt != startedAt).toList());
      });

  Future<void> clear() => _locked(() async => _write(const []));

  Future<void> _replace(File target, String payload) async {
    final temporary = File(
        '${target.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}');
    try {
      await temporary.writeAsString(payload, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _write(List<SessionLogEntry> entries,
      {bool keepBackup = true}) async {
    final payload = jsonEncode(entries.map((e) => e.toJson()).toList());
    if (keepBackup && await file.exists()) {
      final previous = await file.readAsString();
      if (_decode(previous) == null) {
        throw const FormatException('Invalid session history');
      }
      await _replace(_backup, previous);
    }
    await _replace(file, payload);
  }
}
