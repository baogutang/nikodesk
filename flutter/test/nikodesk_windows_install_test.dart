import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/home_board.dart';
import 'package:flutter_hbb/nikodesk/install_assistant.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/windows_install.dart';

import 'nikodesk_unattended_install_test.dart';

const _home = r"C:\Users\O'Neil";
const _local = '$_home\\AppData\\Local';
const _roaming = '$_home\\AppData\\Roaming';
const _copy = '$_local\\Programs\\NikoDesk\\package-1-2-0';

// Process runner substitute: no PowerShell, registry or file is touched.
class _Runs {
  final calls = <List<String>>[];
  int exitCode = 0;
  Future<ProcessResult> call(String executable, List<String> arguments) async {
    calls.add([executable, ...arguments]);
    return ProcessResult(1, exitCode, '', '');
  }

  String get script => calls.single.last;
}

NikoWindowsInstall _windows(_Runs runs,
        {String executable = '$_copy\\NikoDesk.exe',
        Map<String, String> environment = const {
          'LOCALAPPDATA': _local,
          'APPDATA': _roaming,
        }}) =>
    NikoWindowsInstall(
        run: runs.call, executable: executable, environment: environment);

class _Gateway implements ServerGateway {
  @override
  Future<ServerSnapshot> read() async => const ServerSnapshot(
      PrivateServerConfig('nas.example.net:21116', 'nas.example.net:21117',
          'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE='),
      1,
      true);
  @override
  Future<void> save(PrivateServerConfig config) async {}
}

Widget _app(Widget child) => MaterialApp(
    theme: nightlineTheme(Brightness.light),
    home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  setUp(() => NikoLanguage.english = true);
  tearDown(() => NikoLanguage.english = false);

  test('a copy the setup extracted registers a shortcut and an Apps entry',
      () async {
    final runs = _Runs();
    final windows = _windows(runs);
    expect(windows.isSetupCopy, isTrue);
    expect(await windows.register(version: '3.0.0'), isTrue);
    expect(runs.calls.single.first, 'powershell.exe');
    final script = runs.script;
    // Single quotes in a path are doubled inside PowerShell literals.
    expect(
        script,
        contains("CreateShortcut('C:\\Users\\O''Neil\\AppData\\Roaming\\"
            "Microsoft\\Windows\\Start Menu\\Programs\\NikoDesk.lnk')"));
    expect(
        script,
        contains("TargetPath = 'C:\\Users\\O''Neil\\AppData\\Local\\"
            "Programs\\NikoDesk\\package-1-2-0\\NikoDesk.exe'"));
    expect(script,
        contains(r"-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NikoDesk'"));
    expect(script, contains("-Name DisplayVersion -Value '3.0.0'"));
    expect(
        script,
        contains("-Name UninstallString -Value "
            "'\"C:\\Users\\O''Neil\\AppData\\Local\\Programs\\NikoDesk\\package-1-2-0\\NikoDesk.exe\" --nikodesk-uninstall'"));
    expect(script, contains('-Name NoModify -Value 1 -Type DWord'));
  });

  test('other copies never register and a failed script reports it', () async {
    final runs = _Runs();
    expect(
        await _windows(runs, executable: r'C:\Users\x\Downloads\NikoDesk\NikoDesk.exe')
            .register(version: '3.0.0'),
        isFalse);
    expect(
        await _windows(runs, environment: const {'APPDATA': _roaming})
            .register(version: '3.0.0'),
        isFalse);
    expect(runs.calls, isEmpty);
    runs.exitCode = 1;
    expect(await _windows(runs).register(version: '3.0.0'), isFalse);
  });

  test('unregistering removes only the shortcut and the Apps entry', () async {
    final runs = _Runs();
    expect(await _windows(runs).unregister(), isTrue);
    expect(runs.script, contains('NikoDesk.lnk'));
    expect(runs.script,
        contains(r"Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NikoDesk'"));
    expect(runs.script, isNot(contains('Program Files')));
  });

  testWidgets('a confirmed installation shows the new code and registers',
      (tester) async {
    final transport = InstallTransportDouble()
      ..onCurrent = (() async => installComplete())
      ..onStatus = ((_) async => installComplete());
    final model = installModel(transport);
    final runs = _Runs();
    await tester.pumpWidget(_app(NikoInstallAssistant(
        gateway: _Gateway(),
        model: model,
        setup: '$_copy\\nikodesk-setup.exe',
        windows: _windows(runs),
        readVersion: () async => '3.0.0')));
    await tester.runAsync(model.refresh);
    await tester.pumpAndSettle();
    expect(find.text('Installed'), findsOneWidget);
    expect(
        tester
            .widget<SelectableText>(
                find.byKey(const Key('install-assistant-machine-id')))
            .data,
        nikoGroupedId('1234567890'));
    expect(runs.calls, hasLength(1));
    expect(find.textContaining('NikoDesk is in the Start menu'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('uninstall removes the service before the program',
      (tester) async {
    final transport = InstallTransportDouble();
    final model = installModel(transport);
    final runs = _Runs();
    var quit = 0;
    await tester.pumpWidget(_app(NikoUninstallAssistant(
        model: model,
        setup: '$_copy\\nikodesk-setup.exe',
        // Not a setup copy, so no folder removal is scheduled in a test.
        windows: _windows(runs, environment: const {'APPDATA': _roaming}),
        quit: () async => quit++)));
    await tester.runAsync(model.refresh);
    await tester.pumpAndSettle();
    expect(runs.calls, isEmpty);
    transport.onBegin = (_) async => installReply(action: 'remove');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('uninstall-confirm')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(transport.requests.single['action'], 'remove');
    expect(transport.requests.single['password'], isEmpty);
    expect(transport.requests.single['selected_setup'], '$_copy\\nikodesk-setup.exe');
    transport.onCurrent = () async => installReply(
        action: 'remove',
        phase: 'complete',
        reason: 'complete',
        quiescent: true,
        processExited: true,
        taskJoined: true);
    transport.onStatus = (_) => transport.onCurrent!();
    await tester.runAsync(model.refresh);
    await tester.pumpAndSettle();
    expect(find.text('Background service removed'), findsOneWidget);
    expect(runs.calls, isEmpty);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('uninstall-finish')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(runs.calls, hasLength(1));
    expect(quit, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
