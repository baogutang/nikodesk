import 'dart:io';

import 'package:flutter_hbb/models/file_model.dart';

import 'file_transfer.dart';

class NikoDroppedFile {
  final String path;
  final String name;
  const NikoDroppedFile(this.path, this.name);
}

/// OS drops are always local sources. Freeze the remote destination before
/// filesystem reads so browsing and reconnection cannot change the request.
Future<void> nikoSendLocalDrop({
  required bool droppedOnLocal,
  required Iterable<NikoDroppedFile> files,
  required DirectoryData destination,
  required NikoTransferContext? capturedContext,
  required NikoTransferContext? Function() currentContext,
  required Future<void> Function(SelectedItems, DirectoryData) send,
}) async {
  if (droppedOnLocal) return;
  void check() {
    final current = currentContext();
    if (capturedContext == null ||
        current == null ||
        !capturedContext.matches(current) ||
        !current.ready ||
        !current.fileAllowed) {
      throw StateError('drop session unavailable');
    }
  }

  check();
  final directory = FileDirectory()
    ..id = destination.directory.id
    ..path = destination.directory.path
    ..entries = destination.directory.entries
        .map((entry) => Entry()
          ..path = entry.path
          ..name = entry.name
          ..entryType = entry.entryType
          ..size = entry.size
          ..modifiedTime = entry.modifiedTime)
        .toList();
  final options = DirectoryOptions()
    ..home = destination.options.home
    ..showHidden = destination.options.showHidden
    ..isWindows = destination.options.isWindows;
  final target = DirectoryData(directory, options);
  final sources = files.toList(growable: false);
  final items = SelectedItems(isLocal: true);
  for (final file in sources) {
    check();
    final stat = await FileStat.stat(file.path);
    check();
    if (stat.type != FileSystemEntityType.file &&
        stat.type != FileSystemEntityType.directory) {
      throw StateError('drop source unavailable');
    }
    items.add(Entry()
      ..entryType = stat.type == FileSystemEntityType.directory ? 0 : 4
      ..path = file.path
      ..name = file.name
      ..size = stat.type == FileSystemEntityType.directory ? 0 : stat.size);
  }
  if (items.items.isEmpty) return;
  check();
  await send(items, target);
}
