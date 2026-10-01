import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/cm_voice_start.dart';
import 'package:flutter_hbb/nikodesk/mac_background_agent.dart';
import 'package:flutter_hbb/nikodesk/unattended_install.dart';
import 'package:flutter_hbb/nikodesk/virtual_display.dart';
import 'package:flutter_test/flutter_test.dart';
import 'nikodesk_unattended_install_test.dart' show installReply;

void main() {
  test(
      'virtual screen snapshots reject malformed, duplicated and overlapping slots',
      () {
    final raw = {
      'schema': 1,
      'supported': true,
      'allowed': true,
      'active': [1, 4],
      'cleanup': [2]
    };
    expect(NikoVirtualDisplays.parse(raw)!.active, {1, 4});
    for (final patch in [
      {
        'active': [1, 1]
      },
      {
        'active': [0]
      },
      {
        'active': [5]
      },
      {
        'active': ['1']
      },
      {
        'cleanup': [4]
      },
      {'supported': 'true'},
      {'schema': 2},
      {'unknown': true}
    ]) {
      expect(NikoVirtualDisplays.parse({...raw, ...patch}), isNull);
    }
  });

  test(
      'owned launch agent can be identified after app relocation without trusting arbitrary jobs',
      () {
    for (final path in [
      '/Applications/NikoDesk.app/Contents/MacOS/NikoDesk',
      '/Users/fixture/Applications/Tools & <stuff>/NikoDesk.app/Contents/MacOS/NikoDesk'
    ]) {
      final plist = nikoMacBackgroundPlist(path);
      expect(nikoMacBackgroundExecutable(plist), path);
      expect(
          nikoMacBackgroundExecutable(
              plist.replaceFirst('io.nikodesk.background', 'other.job')),
          isNull);
      expect(
          nikoMacBackgroundExecutable(
              plist.replaceFirst('<true/>', '<false/>')),
          isNull);
      expect(
          nikoMacBackgroundExecutable(
              plist.replaceFirst('</dict>', '<key>Other</key><true/></dict>')),
          isNull);
    }
    expect(
        () => nikoMacBackgroundPlist(
            '/Applications/../NikoDesk.app/Contents/MacOS/NikoDesk'),
        throwsFormatException);
    expect(
        () => nikoMacBackgroundPlist(
            'relative/NikoDesk.app/Contents/MacOS/NikoDesk'),
        throwsFormatException);
  });

  test(
      'installer confirmation requires verified machine ID after process exit and task join',
      () {
    String reply(String id) => installReply(
        phase: 'complete',
        reason: 'complete',
        quiescent: true,
        processExited: true,
        taskJoined: true,
        machineId: id);
    expect(
        NikoUnattendedInstallReply.parse(reply('1234567890'))!.confirmed, true);
    expect(NikoUnattendedInstallReply.parse(reply(''))!.confirmed, false);
    for (final id in ['0' * 10, '123456789', 'a234567890']) {
      expect(NikoUnattendedInstallReply.parse(reply(id)), isNull);
    }
    expect(
        NikoUnattendedInstallReply.parse(installReply(machineId: '1234567890')),
        isNull);
  });

  testWidgets(
      'reverse voice preparation failure is bound to its attempt and can be retried explicitly',
      (tester) async {
    final context = NikoCmVoiceStartContext.parse({
      'schema': 1,
      'connection_id': 7,
      'namespace': 'a' * 64,
      'peer_id': '123456789',
      'connection_nonce': 'b' * 32
    })!;
    const availability =
        '{"supported":true,"requests_allowed":true,"peer_supported":true,"peer_requests_allowed":true,"reason":""}';
    int? deadline;
    var attempts = 0;
    Future<String> prepare(String raw) async {
      deadline = jsonDecode(raw)['expires_at_ms'];
      attempts++;
      return '{"ok":true,"status":"queued"}';
    }

    Widget host({String? error, int? failedAt}) => MaterialApp(
        home: Scaffold(
            body: NikoCmVoiceStart(
                key: const ValueKey('same-connection'),
                context: context,
                availability: (_) async => availability,
                prepare: prepare,
                prepareError: error,
                prepareDeadline: failedAt)));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('niko-voice-prepare')));
    await tester.pumpAndSettle();
    final first = deadline!;
    await tester.pumpWidget(host(error: 'stale_command', failedAt: first));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('niko-voice-prepare')), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, '检查语音可用性'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('niko-voice-prepare')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(deadline, greaterThan(first));
    await tester.pumpWidget(host(error: 'stale_command', failedAt: first));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('niko-voice-prepare')), findsOneWidget);
  });
}
