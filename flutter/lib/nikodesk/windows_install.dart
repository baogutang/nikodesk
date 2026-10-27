import 'dart:io';

import 'package:path/path.dart' as path;

typedef NikoProcessRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);

/// Windows' Apps settings start the GUI with this to open its removal page.
const nikoUninstallArgument = '--nikodesk-uninstall';

const _uninstallKey =
    r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NikoDesk';

/// What makes the copy the setup extracted (libs/portable/src/installer.rs)
/// an installed program for this user once the service is installed: a
/// Start menu shortcut and an entry in Settings > Apps whose Uninstall opens
/// this GUI's removal page. The service and Program Files stay with the
/// broker; this only touches the user's own shortcut, key and folder.
class NikoWindowsInstall {
  final NikoProcessRunner _run;
  final String executable;
  final Map<String, String> environment;

  NikoWindowsInstall(
      {NikoProcessRunner? run, String? executable, Map<String, String>? environment})
      : _run = run ?? Process.run,
        executable = executable ?? Platform.resolvedExecutable,
        environment = environment ?? Platform.environment;

  String get directory => path.windows.dirname(executable);

  /// The folder the setup extracts each release into, one subfolder each.
  String? get programs {
    final local = environment['LOCALAPPDATA'];
    return local == null || local.isEmpty
        ? null
        : path.windows.join(local, 'Programs', 'NikoDesk');
  }

  /// Whether this GUI is a copy the setup extracted, the only kind that
  /// registers itself.
  bool get isSetupCopy {
    final programs = this.programs;
    return programs != null &&
        path.windows.equals(path.windows.dirname(directory), programs);
  }

  String? get shortcut {
    final roaming = environment['APPDATA'];
    return roaming == null || roaming.isEmpty
        ? null
        : path.windows.join(roaming, 'Microsoft', 'Windows', 'Start Menu',
            'Programs', 'NikoDesk.lnk');
  }

  static String _quote(String value) => "'${value.replaceAll("'", "''")}'";

  Future<bool> _powershell(String script) async {
    final result = await _run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
    return result.exitCode == 0;
  }

  /// Points the Start menu shortcut and the Apps entry at this copy.
  Future<bool> register({required String version}) async {
    final shortcut = this.shortcut;
    if (!isSetupCopy || shortcut == null) return false;
    final exe = _quote(executable);
    final key = _quote(_uninstallKey);
    final script = [
      r"$ErrorActionPreference = 'Stop'",
      '\$link = (New-Object -ComObject WScript.Shell).CreateShortcut(${_quote(shortcut)})',
      '\$link.TargetPath = $exe',
      '\$link.WorkingDirectory = ${_quote(directory)}',
      '\$link.IconLocation = ${_quote('$executable,0')}',
      r'$link.Save()',
      'New-Item -Path $key -Force | Out-Null',
      for (final (name, value) in [
        ('DisplayName', 'NikoDesk'),
        ('DisplayVersion', version),
        ('Publisher', 'NikoDesk'),
        ('DisplayIcon', '$executable,0'),
        ('InstallLocation', directory),
        ('UninstallString', '"$executable" $nikoUninstallArgument'),
      ])
        'Set-ItemProperty -Path $key -Name $name -Value ${_quote(value)}',
      'Set-ItemProperty -Path $key -Name NoModify -Value 1 -Type DWord',
      'Set-ItemProperty -Path $key -Name NoRepair -Value 1 -Type DWord',
    ].join('; ');
    return _powershell(script);
  }

  /// Removes the shortcut and the Apps entry, if they point at this copy.
  Future<bool> unregister() async {
    final shortcut = this.shortcut;
    if (shortcut == null) return false;
    final key = _quote(_uninstallKey);
    final script = [
      'Remove-Item -LiteralPath ${_quote(shortcut)} -Force -ErrorAction SilentlyContinue',
      'Remove-Item -Path $key -Force -ErrorAction SilentlyContinue',
    ].join('; ');
    return _powershell(script);
  }

  /// Deletes the other extracted releases, e.g. after an upgrade; a copy
  /// still running keeps its folder until the next time.
  Future<void> removeOtherCopies() async {
    final programs = this.programs;
    if (programs == null || !isSetupCopy) return;
    final root = Directory(programs);
    if (!await root.exists()) return;
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory || path.windows.equals(entry.path, directory)) {
        continue;
      }
      try {
        await entry.delete(recursive: true);
      } catch (_) {
        // In use; it goes with a later cleanup.
      }
    }
  }

  /// After this process exits, deletes every extracted release.
  Future<void> removeAllAfterExit() async {
    final programs = this.programs;
    if (programs == null || !isSetupCopy) return;
    await Process.start(
        'cmd.exe',
        [
          '/d',
          '/c',
          'ping -n 4 127.0.0.1 >nul & rmdir /s /q "${programs.replaceAll('"', '')}"',
        ],
        mode: ProcessStartMode.detached);
  }
}
