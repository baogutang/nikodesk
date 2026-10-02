// A real TCP tunnel: the controller listens locally, the controlled side
// connects to the approved target, and bytes make the round trip.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/tunnel_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('an approved tunnel carries bytes to the target and back', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final namespace = await native.configureServer();

    // The target runs on this machine, which is also where the controlled
    // profile runs, so its loopback address is what gets approved.
    final target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(target.close);
    target.listen((socket) => socket.listen(
        (data) => socket.add(utf8.encode('echo:') + data),
        onDone: socket.destroy,
        onError: (_) => socket.destroy()));
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final localPort = probe.port;
    await probe.close();

    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'), tunnel: true);
    addTearDown(session.close);
    final command = NikoTunnelCommand.add(
        namespace, host, localPort, '127.0.0.1', target.port)!;
    final reply = jsonDecode(await native.bind
        .sessionNikoTunnelCommand(sessionId: session.id, json: command.json));
    expect(reply['ok'], isTrue, reason: 'tunnel command refused: $reply');

    NikoTunnelStatus? status() {
      NikoTunnelStatus? latest;
      for (final event in session.named('nikodesk_tunnel_controller')) {
        final parsed = NikoTunnelStatus.parse('${event['status']}');
        if (parsed != null && parsed.localPort == localPort) latest = parsed;
      }
      return latest;
    }

    try {
      await session.until(
          () => status()?.phase == NikoTunnelPhase.listening, 'tunnel listening',
          timeout: const Duration(seconds: 60));
    } finally {
      printOnFailure('last tunnel status: phase=${status()?.phase} '
          'reason=${status()?.reason} remote=${status()?.remotePhase}');
      printOnFailure('raw: ${session.named('nikodesk_tunnel_controller').map((e) => e['status']).toList()}');
    }

    final socket = await Socket.connect(InternetAddress.loopbackIPv4, localPort)
        .timeout(const Duration(seconds: 10));
    addTearDown(socket.destroy);
    socket.add(utf8.encode('niko-tunnel-payload'));
    await socket.flush();
    final received = await socket
        .map(utf8.decode)
        .firstWhere((text) => text.contains('niko-tunnel-payload'))
        .timeout(const Duration(seconds: 20));
    expect(received, 'echo:niko-tunnel-payload');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
