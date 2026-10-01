import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/tunnel_controller.dart';
import 'package:flutter_hbb/nikodesk/wake_on_lan.dart';
import 'package:flutter_test/flutter_test.dart';

const scope =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const mac = '02:00:00:00:00:01';

NikoTunnelController proxy(int port) {
  final model = NikoTunnelController(
      contextKey: 'wake-test/$scope/123456789',
      namespace: scope,
      peerId: '123456789',
      isCurrent: () => true);
  model.handleEvent({
    'name': 'nikodesk_tunnel_controller',
    'status': jsonEncode({
      'namespace': scope,
      'peer_id': '123456789',
      'local_port': port,
      'target': {'host': '127.0.0.1', 'port': 21128},
      'generation': '1',
      'revision': '1',
      'phase': 'Listening',
      'reason': 'tunnel_listening',
      'remote_phase': 'Running',
      'local_resources_closed': false
    })
  });
  return model;
}

void main() {
  test('local sender sends three real loopback UDP magic packets', () async {
    final receiver =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(receiver.close);
    final packets = <List<int>>[];
    final received = Completer<void>();
    final subscription = receiver.listen((event) {
      if (event == RawSocketEvent.read) {
        Datagram? packet;
        while ((packet = receiver.receive()) != null) {
          packets.add(packet!.data);
          if (packets.length == 3 && !received.isCompleted) received.complete();
        }
      }
    });
    addTearDown(subscription.cancel);
    final profile = WakeProfile(mac, '127.0.0.1', port: receiver.port);
    expect(await WakeSender.local(profile), 3);
    await received.future.timeout(const Duration(seconds: 3));
    for (final packet in packets) {
      expect(packet.length, 102);
      expect(packet.take(6), List.filled(6, 255));
      expect(packet.skip(6), [
        for (var i = 0; i < 16; i++) ...[2, 0, 0, 0, 0, 1]
      ]);
    }
  });

  test(
      'profiles merge concurrent disk writes and retain independent server scopes',
      () async {
    final directory =
        await Directory('../target/wake-tests').create(recursive: true);
    final temporary = await directory.createTemp('profiles-');
    addTearDown(() => temporary.delete(recursive: true));
    final first = WakeProfileStore(temporary, scope);
    final second = WakeProfileStore(temporary, 'b' * 64);
    await Future.wait([
      first.save('123456789',
          const WakeProfile(mac, '192.168.1.255', proxyId: '234567890')),
      first.save(
          '987654321', const WakeProfile('02:00:00:00:00:02', '10.0.0.255')),
      second.save(
          '123456789', const WakeProfile('02:00:00:00:00:03', '10.1.0.255'))
    ]);
    expect((await first.load('123456789'))!.mac, mac);
    expect((await first.load('123456789'))!.proxyId, '234567890');
    expect((await first.load('987654321'))!.broadcast, '10.0.0.255');
    expect((await second.load('123456789'))!.mac, '02:00:00:00:00:03');
    final file = File('${temporary.path}/wake-profiles-$scope.json');
    await file.writeAsString(
        jsonEncode({'version': 99, 'namespace': scope, 'devices': {}}));
    final before = await file.readAsBytes();
    await expectLater(
        first.save('123456789', const WakeProfile(mac, '10.0.0.255')),
        throwsFormatException);
    expect(await file.readAsBytes(), before);
  });

  test('proxy sends a real TCP request and accepts only its own acknowledgment',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var mismatch = false;
    final subscription = server.listen((socket) async {
      final raw =
          await utf8.decoder.bind(socket).transform(const LineSplitter()).first;
      final request = jsonDecode(raw) as Map;
      expect(request['mac'], mac);
      expect(request['namespace'], scope);
      expect(request['broadcast'], '10.0.0.255');
      socket.write('${jsonEncode({
            'schema': 1,
            'request_id': mismatch ? '0' * 32 : request['request_id'],
            'sent': true,
            'packets': 3
          })}\n');
      await socket.flush();
      socket.destroy();
    });
    addTearDown(subscription.cancel);
    final model = proxy(server.port);
    expect(
        await WakeSender.throughProxy(
            const WakeProfile(mac, '10.0.0.255'), model, server.port),
        3);
    mismatch = true;
    await expectLater(
        WakeSender.throughProxy(
            const WakeProfile(mac, '10.0.0.255'), model, server.port),
        throwsStateError);
    model.dispose();
    expect(WakeSender.proxyReady(model, server.port), false);
  });

  test('invalid multicast MAC and external broadcast destinations refuse', () {
    expect(WakeProfile.parse('02-00-00-00-00-01', '192.168.1.255')!.mac, mac);
    expect(WakeProfile.parse('FF:FF:FF:FF:FF:FF', '255.255.255.255'), isNull);
    expect(WakeProfile.parse(mac, '8.8.8.8'), isNull);
    expect(WakeProfile.parse(mac, '224.0.0.1'), isNull);
    expect(WakeProfile.parse(mac, '10.0.0.255', port: 0), isNull);
  });
}
