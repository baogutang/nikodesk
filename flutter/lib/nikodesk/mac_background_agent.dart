import 'dart:io';

String nikoMacBackgroundPlist(String executable) {
  if (!executable.startsWith('/') ||
      executable
          .split('/')
          .skip(1)
          .any((part) => part.isEmpty || part == '.' || part == '..') ||
      !executable.endsWith('/NikoDesk.app/Contents/MacOS/NikoDesk') ||
      executable.runes.any((value) => value < 32)) {
    throw const FormatException('Invalid NikoDesk application');
  }
  final escaped = executable
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>io.nikodesk.background</string>
<key>ProgramArguments</key><array><string>$escaped</string><string>--nikodesk-background-agent</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>5</integer>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
''';
}

/// Accept only the exact document written by this feature. This also lets a
/// user disable their own agent after moving or deleting the application.
String? nikoMacBackgroundExecutable(String content) {
  if (content.length > 8192) return null;
  final match = RegExp(
          r'<key>ProgramArguments</key><array><string>([^\r\n]*)</string><string>--nikodesk-background-agent</string></array>')
      .firstMatch(content);
  if (match == null) return null;
  final executable = match
      .group(1)!
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  try {
    return content == nikoMacBackgroundPlist(executable) ? executable : null;
  } catch (_) {
    return null;
  }
}

/// Operations are called only by this app's explicit local settings buttons.
/// There is no elevated daemon, root path, remote command or credential field.
class NikoMacBackgroundAgent {
  static const label = 'io.nikodesk.background';
  String get _home => Platform.environment['HOME'] ?? '';
  File get _file => File('$_home/Library/LaunchAgents/$label.plist');
  Future<String?> _ownedContent() async {
    if (!Platform.isMacOS ||
        _home.isEmpty ||
        await FileSystemEntity.type(_file.path, followLinks: false) !=
            FileSystemEntityType.file) return null;
    for (final path in [_home, '$_home/Library', _file.parent.path]) {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.directory) return null;
    }
    final content = await _file.readAsString();
    final executable = nikoMacBackgroundExecutable(content);
    if (executable == null ||
        !(executable.startsWith('/Applications/') ||
            executable.startsWith('$_home/Applications/'))) return null;
    return content;
  }

  Future<String> _executable() async {
    final executable =
        await File(Platform.resolvedExecutable).resolveSymbolicLinks();
    final userApps = '$_home/Applications/';
    if (!Platform.isMacOS ||
        _home.isEmpty ||
        !(executable.startsWith('/Applications/') ||
            executable.startsWith(userApps))) {
      throw StateError('stable_application_required');
    }
    nikoMacBackgroundPlist(executable);
    final bundle = executable.substring(
        0, executable.length - '/Contents/MacOS/NikoDesk'.length);
    final identity = await Process.run('/usr/bin/plutil', [
      '-extract',
      'CFBundleIdentifier',
      'raw',
      '-o',
      '-',
      '$bundle/Contents/Info.plist'
    ]);
    if (identity.exitCode != 0 ||
        identity.stdout.toString().trim() != 'io.nikodesk.macos') {
      throw StateError('invalid_application_identity');
    }
    final signature = await Process.run(
        '/usr/bin/codesign', ['--verify', '--deep', '--strict', bundle]);
    if (signature.exitCode != 0) {
      throw StateError('application_signature_invalid');
    }
    return executable;
  }

  Future<String> _domain() async {
    final result = await Process.run('/usr/bin/id', ['-u']);
    final uid = result.exitCode == 0
        ? int.tryParse(result.stdout.toString().trim())
        : null;
    if (uid == null || uid <= 0) throw StateError('ordinary_user_required');
    return 'gui/$uid';
  }

  Future<bool> configured() async {
    if (!Platform.isMacOS) return false;
    try {
      return await _ownedContent() ==
          nikoMacBackgroundPlist(await _executable());
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasOwnedConfiguration() async {
    try {
      return await _ownedContent() != null;
    } catch (_) {
      return false;
    }
  }

  Future<bool> enable() async {
    final content = nikoMacBackgroundPlist(await _executable());
    final domain = await _domain();
    for (final directory in [Directory(_home), Directory('$_home/Library')]) {
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw StateError('unsafe_agent_directory');
      }
    }
    final parentType =
        await FileSystemEntity.type(_file.parent.path, followLinks: false);
    if (parentType == FileSystemEntityType.notFound) {
      await _file.parent.create();
    } else if (parentType != FileSystemEntityType.directory)
      throw StateError('unsafe_agent_directory');
    final kind = await FileSystemEntity.type(_file.path, followLinks: false);
    final previous =
        kind == FileSystemEntityType.notFound ? null : await _ownedContent();
    if (kind != FileSystemEntityType.notFound && previous == null) {
      throw StateError('existing_agent_not_owned');
    }
    if (kind != FileSystemEntityType.notFound) {
      // Never silently restart an already configured job.
      final loaded =
          await Process.run('/bin/launchctl', ['print', '$domain/$label']);
      if (loaded.exitCode == 0) {
        if (previous == content) return true;
        final unloaded =
            await Process.run('/bin/launchctl', ['bootout', '$domain/$label']);
        if (unloaded.exitCode != 0) {
          throw StateError('agent_shutdown_unconfirmed');
        }
      } else if (!'${loaded.stdout}${loaded.stderr}'
          .contains('Could not find service "$label"')) {
        throw StateError('agent_state_unconfirmed');
      }
      if (await _ownedContent() != previous) {
        throw StateError('agent_configuration_changed');
      }
    }
    final temporary =
        File('${_file.path}.new.$pid.${DateTime.now().microsecondsSinceEpoch}');
    try {
      await temporary.writeAsString(content, flush: true);
      final mode = await Process.run('/bin/chmod', ['600', temporary.path]);
      if (mode.exitCode != 0) throw StateError('agent_file_permissions_failed');
      await temporary.rename(_file.path);
      final loaded = await Process.run(
          '/bin/launchctl', ['bootstrap', domain, _file.path]);
      if (loaded.exitCode != 0) throw StateError('agent_bootstrap_unconfirmed');
      return await configured();
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<bool> disable() async {
    final previous = await _ownedContent();
    if (previous == null) throw StateError('agent_configuration_unconfirmed');
    final domain = await _domain();
    final state =
        await Process.run('/bin/launchctl', ['print', '$domain/$label']);
    if (state.exitCode == 0) {
      final unloaded =
          await Process.run('/bin/launchctl', ['bootout', '$domain/$label']);
      if (unloaded.exitCode != 0) {
        throw StateError('agent_shutdown_unconfirmed');
      }
    } else if (!'${state.stdout}${state.stderr}'
        .contains('Could not find service "$label"')) {
      throw StateError('agent_shutdown_unconfirmed');
    }
    if (await _ownedContent() != previous) {
      throw StateError('agent_configuration_changed');
    }
    await _file.delete();
    return await FileSystemEntity.type(_file.path, followLinks: false) ==
        FileSystemEntityType.notFound;
  }
}
