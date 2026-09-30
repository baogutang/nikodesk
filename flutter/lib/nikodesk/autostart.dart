import 'dart:io';

import 'package:flutter/foundation.dart';

/// User-level login autostart for macOS via ~/Library/LaunchAgents.
/// No privilege elevation, no system service: the app starts after this
/// user logs in, which is the only unattended-reachability this build
/// claims. Any failure leaves the previous state untouched.
class NikoAutostart {
  final String label;
  final String bundleId;
  final String? homeOverride;
  const NikoAutostart(
      {this.label = 'io.nikodesk.NikoDesk',
      this.bundleId = 'io.nikodesk.macos',
      this.homeOverride});

  bool get supported => Platform.isMacOS;

  bool get _validIdentifiers => [label, bundleId].every((value) =>
      value.length <= 200 &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value));

  String get _home => homeOverride ?? Platform.environment['HOME'] ?? '';
  File get plist => File('$_home/Library/LaunchAgents/$label.plist');

  bool get enabled {
    if (!supported || !_validIdentifiers) return false;
    try {
      return FileSystemEntity.typeSync(plist.path, followLinks: false) ==
              FileSystemEntityType.file &&
          plist.readAsStringSync().trim() == _content.trim();
    } catch (_) {
      return false;
    }
  }

  String get _content => '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-b</string>
    <string>$bundleId</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
''';

  /// Confirms the managed configuration, not that a login has executed it.
  Future<bool> enable() async {
    if (!supported || !_validIdentifiers) return false;
    File? temporary;
    try {
      final parent = plist.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      if (FileSystemEntity.typeSync(parent.path, followLinks: false) !=
          FileSystemEntityType.directory) return false;
      final existing =
          FileSystemEntity.typeSync(plist.path, followLinks: false);
      if (existing != FileSystemEntityType.notFound &&
          existing != FileSystemEntityType.file) return false;
      temporary = File(
          '${plist.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}');
      await temporary.writeAsString(_content, flush: true);
      await temporary.rename(plist.path);
      return enabled;
    } catch (error) {
      debugPrint('nikodesk autostart enable failed: $error');
      return false;
    } finally {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  /// Remove the LaunchAgent. We never `launchctl load` it ourselves, so
  /// deleting the plist is both necessary and sufficient: nothing starts
  /// at the next login, and a missing file counts as success.
  Future<bool> disable() async {
    if (!supported || !_validIdentifiers) return false;
    try {
      if (plist.existsSync()) {
        await plist.delete();
      }
      return !plist.existsSync();
    } catch (error) {
      debugPrint('nikodesk autostart disable failed: $error');
      return false;
    }
  }
}
