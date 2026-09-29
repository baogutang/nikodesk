import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'policy.dart';

class DeviceEntry {
  final String id;
  final String alias;
  final String group;
  final bool favorite;
  final bool forceRelay;
  final DateTime? lastConnectedAt;

  const DeviceEntry(
      {required this.id,
      this.alias = '',
      this.group = '',
      this.favorite = false,
      this.forceRelay = false,
      this.lastConnectedAt});

  String get title => alias.isEmpty ? id : alias;

  factory DeviceEntry.fromJson(Map<String, dynamic> json, int version) {
    final id = json['id'];
    final alias = json[version == 0 ? 'name' : 'alias'] ?? '';
    final group = json['group'] ?? '';
    if (id is! String ||
        !validDeviceId(id) ||
        alias is! String ||
        group is! String ||
        alias.length > 100 ||
        group.length > 60 ||
        (json['favorite'] != null && json['favorite'] is! bool) ||
        (json['forceRelay'] != null && json['forceRelay'] is! bool)) {
      throw const FormatException('Invalid device record');
    }
    final timestamp = json['lastConnectedAt'];
    if (timestamp != null &&
        (timestamp is! String || DateTime.tryParse(timestamp) == null)) {
      throw const FormatException('Invalid connection timestamp');
    }
    return DeviceEntry(
        id: normalizeDeviceId(id),
        alias: alias,
        group: group,
        favorite: json['favorite'] == true,
        forceRelay: json['forceRelay'] == true,
        lastConnectedAt:
            timestamp == null ? null : DateTime.parse(timestamp).toUtc());
  }

  DeviceEntry copyWith(
          {String? alias,
          String? group,
          bool? favorite,
          bool? forceRelay,
          DateTime? lastConnectedAt}) =>
      DeviceEntry(
          id: id,
          alias: alias ?? this.alias,
          group: group ?? this.group,
          favorite: favorite ?? this.favorite,
          forceRelay: forceRelay ?? this.forceRelay,
          lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt);

  Map<String, Object?> toJson() => {
        'id': id,
        'alias': alias,
        'group': group,
        'favorite': favorite,
        'forceRelay': forceRelay,
        if (lastConnectedAt != null)
          'lastConnectedAt': lastConnectedAt!.toUtc().toIso8601String(),
      };
}

class FutureDeviceSchema implements Exception {}

class DeviceDirectory {
  final List<DeviceEntry> devices;
  final bool recovered;
  const DeviceDirectory(this.devices, {this.recovered = false});
}

/// All processes use the same lock; UI and session windows update the latest file.
class DeviceStore {
  static final DeviceStore instance = DeviceStore(_privateDirectory());
  final Directory directory;
  Future<void> _pending = Future.value();
  DeviceStore(this.directory);

  static Directory _privateDirectory() {
    final env = Platform.environment;
    if (Platform.isMacOS) {
      return Directory(
          '${env['HOME']!}/Library/Preferences/io.nikodesk.NikoDesk');
    }
    if (Platform.isWindows) {
      return Directory('${env['APPDATA']!}/NikoDesk/config');
    }
    return Directory(
        '${env['XDG_CONFIG_HOME'] ?? '${env['HOME']!}/.config'}/NikoDesk');
  }

  File get file => File('${directory.path}/devices.json');
  File get _backup => File('${file.path}.bak');

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _pending = _pending.then((_) async {
      _DirectoryLock? lock;
      try {
        await directory.create(recursive: true);
        lock = await _DirectoryLock.acquire('${file.path}.lock');
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        if (lock != null) {
          await lock.close();
        }
      }
    });
    return result.future;
  }

  DeviceDirectory _decode(String data) {
    final json = jsonDecode(data);
    if (json is! Map<String, dynamic> || json['version'] is! int) {
      throw const FormatException('Invalid directory header');
    }
    final version = json['version'] as int;
    if (version > 1) throw FutureDeviceSchema();
    if (version < 0 ||
        json['devices'] is! List ||
        (json['devices'] as List).length > 10000) {
      throw const FormatException('Invalid directory schema');
    }
    final devices = (json['devices'] as List)
        .map((value) =>
            DeviceEntry.fromJson(value as Map<String, dynamic>, version))
        .toList();
    if (devices.map((device) => device.id).toSet().length != devices.length) {
      throw const FormatException('Duplicate device IDs');
    }
    return DeviceDirectory(devices);
  }

  Future<DeviceDirectory> _read() async {
    if (!await file.exists()) return const DeviceDirectory([]);
    try {
      return _decode(await file.readAsString());
    } on FutureDeviceSchema {
      rethrow;
    } on FileSystemException {
      rethrow;
    } catch (_) {
      // Preserve the corrupt evidence, then use only a validated known schema.
      await file.copy(
          '${file.path}.corrupt.${DateTime.now().microsecondsSinceEpoch}');
      if (await _backup.exists()) {
        final restored = _decode(await _backup.readAsString());
        await _write(restored.devices, keepBackup: false);
        return DeviceDirectory(restored.devices, recovered: true);
      }
      await _write([], keepBackup: false);
      return const DeviceDirectory([], recovered: true);
    }
  }

  Future<DeviceDirectory> load() => _locked(_read);

  Future<void> _replace(File target, String contents) async {
    final temporary = File(
        '${target.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}');
    try {
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _write(List<DeviceEntry> devices,
      {bool keepBackup = true}) async {
    if (keepBackup && await file.exists()) {
      final previous = await file.readAsString();
      _decode(previous);
      await _replace(_backup, previous);
    }
    await _replace(
        file,
        jsonEncode({
          'version': 1,
          'devices': devices.map((device) => device.toJson()).toList()
        }));
  }

  Future<void> save(DeviceEntry device) => _locked(() async {
        DeviceEntry.fromJson(device.toJson(), 1);
        final devices = (await _read()).devices.toList();
        final index = devices.indexWhere((entry) => entry.id == device.id);
        if (index == -1) {
          devices.add(device);
        } else {
          // A session window may have recorded success while the edit dialog was open.
          final recent = devices[index].lastConnectedAt;
          devices[index] = recent != null &&
                  (device.lastConnectedAt == null ||
                      recent.isAfter(device.lastConnectedAt!))
              ? device.copyWith(lastConnectedAt: recent)
              : device;
        }
        await _write(devices);
      });

  Future<void> remove(String id) => _locked(() async {
        final devices =
            (await _read()).devices.where((entry) => entry.id != id).toList();
        await _write(devices);
      });

  Future<void> recordSuccess(String id, DateTime at) => _locked(() async {
        if (!validDeviceId(id)) return;
        final normalized = normalizeDeviceId(id);
        final devices = (await _read()).devices.toList();
        final index = devices.indexWhere((entry) => entry.id == normalized);
        if (index < 0) {
          devices.add(DeviceEntry(id: normalized, lastConnectedAt: at.toUtc()));
        } else {
          devices[index] = devices[index].copyWith(lastConnectedAt: at.toUtc());
        }
        await _write(devices);
      });
}

/// POSIX record locks in dart:io are process-wide and do not exclude another
/// Flutter engine in the same process. flock owns the open descriptor instead.
class _DirectoryLock {
  final int? descriptor;
  final RandomAccessFile? windowsFile;
  _DirectoryLock(this.descriptor, this.windowsFile);
  static final _libc = DynamicLibrary.process();
  static final _open = _libc.lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, int)>('open');
  static final _flock = _libc.lookupFunction<Int32 Function(Int32, Int32),
      int Function(int, int)>('flock');
  static final _close =
      _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');

  static Future<_DirectoryLock> acquire(String path) async {
    if (Platform.isWindows) {
      final file = await File(path).open(mode: FileMode.append);
      try {
        await file.lock(FileLock.blockingExclusive);
        return _DirectoryLock(null, file);
      } catch (_) {
        await file.close();
        rethrow;
      }
    }
    await File(path).create();
    final pointer = path.toNativeUtf8();
    final int descriptor;
    try {
      descriptor = _open(pointer, 2);
    } finally {
      malloc.free(pointer);
    }
    if (descriptor < 0) {
      throw const FileSystemException('Cannot open device directory lock');
    }
    final watch = Stopwatch()..start();
    while (_flock(descriptor, 2 | 4) != 0) {
      if (watch.elapsed > const Duration(seconds: 3)) {
        _close(descriptor);
        throw const FileSystemException('Device directory is busy');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return _DirectoryLock(descriptor, null);
  }

  Future<void> close() async {
    if (descriptor != null) {
      _flock(descriptor!, 8);
      _close(descriptor!);
    } else {
      await windowsFile!.unlock();
      await windowsFile!.close();
    }
  }
}
