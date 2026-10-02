// A real remote terminal: approved by the controlled side's connection
// manager, then a command's output comes back over the session.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('an approved terminal runs a command and returns its output', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'), terminal: true);
    addTearDown(session.close);
    await session.event((event) => event['name'] == 'peer_info',
        'peer info for the terminal session');
    await native.bind.sessionOpenTerminal(
        sessionId: session.id, terminalId: 1, rows: 24, cols: 100);
    final opened = await session.event(
        (event) =>
            event['name'] == 'terminal_response' && event['type'] == 'opened',
        'terminal opened',
        timeout: const Duration(seconds: 40));
    expect('${opened['success']}', 'true',
        reason: 'terminal refused: ${opened['message']}');

    String output() => session
        .named('terminal_response')
        .where((event) => event['type'] == 'data')
        .map((event) =>
            utf8.decode(base64Decode('${event['data']}'), allowMalformed: true))
        .join();
    // The marker only appears in output once the shell has evaluated it.
    await native.bind.sessionSendTerminalInput(
        sessionId: session.id,
        terminalId: 1,
        data: 'echo NIKO_E2E_\$((6*7))_DONE\n');
    await session.until(
        () => output().contains('NIKO_E2E_42_DONE'), 'the command output',
        timeout: const Duration(seconds: 30));
    expect(
        session
            .named('terminal_response')
            .where((event) => event['type'] == 'error'),
        isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
