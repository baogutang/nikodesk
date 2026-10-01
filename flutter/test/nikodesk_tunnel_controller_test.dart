import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/tunnel_controller.dart';
import 'package:flutter_test/flutter_test.dart';

const scope =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
Map<String, dynamic> status(
        {String phase = 'Connecting',
        String generation = '1',
        String revision = '1',
        bool closed = false,
        int port = 8000,
        String namespace = scope,
        String peer = '123456789',
        String host = 'target.invalid'}) =>
    {
      'namespace': namespace,
      'peer_id': peer,
      'local_port': port,
      'target': {'host': host, 'port': 443},
      'generation': generation,
      'revision': revision,
      'phase': phase,
      'reason': 'tunnel_connecting',
      'remote_phase': null,
      'local_resources_closed': closed,
    };
Map<String, dynamic> event(Map<String, dynamic> value) =>
    {'name': 'nikodesk_tunnel_controller', 'status': jsonEncode(value)};
NikoTunnelController model({bool Function()? current, Duration? timeout}) =>
    NikoTunnelController(
        contextKey: 'synthetic-uuid/$scope/123456789',
        namespace: scope,
        peerId: '123456789',
        isCurrent: current ?? () => true,
        commandTimeout: timeout ?? const Duration(seconds: 5));

void main() {
  test(
      'production Rust Publisher fixture crosses Dart parser without numeric precision loss',
      () {
    final fixture = jsonDecode(
        File('../../artifacts/m6-tunnel-controller/ui-status-fixture.json')
            .readAsStringSync()) as Map;
    expect(fixture['synthetic'], true);
    expect(fixture['schema'], 'nikodesk-tunnel-controller-fixture-v1');
    final statuses = (fixture['statuses'] as List)
        .map((value) => NikoTunnelStatus.parse(jsonEncode(value))!)
        .toList();
    expect(statuses.length, 8);
    expect(statuses.map((s) => s.phase).toSet().length, 8);
    expect(statuses.every((s) => s.generation == '9007199254740993'), true);
    expect(statuses.every((s) => s.target.label == '[::1]:23456'), true);
    final closed =
        statuses.firstWhere((s) => s.phase == NikoTunnelPhase.closed);
    expect(closed.localResourcesClosed, true);
    expect(closed.remotePhase, 'Revoking');
  });
  test('exact ten-key status accepts maximum u64 and all native phases', () {
    for (final phase in [
      'Connecting',
      'WaitingApproval',
      'Starting',
      'Listening',
      'Stopping',
      'Closed',
      'Failed',
      'RecoveryRequired'
    ]) {
      expect(
          NikoTunnelStatus.parse(jsonEncode(status(
              phase: phase,
              generation: '18446744073709551615',
              revision: '18446744073709551615',
              closed: phase == 'Closed' || phase == 'Failed'))),
          isNotNull);
    }
  });
  test(
      'unknown fields, invalid numeric counters and false release facts fail closed',
      () {
    for (final bad in [0, 1, '0', '01', '+1', ' 1', '18446744073709551616']) {
      expect(
          NikoTunnelStatus.parse(jsonEncode({...status(), 'generation': bad})),
          isNull);
    }
    for (final bad in [
      {...status(), 'extra': true},
      {...status(), 'local_port': 0},
      {...status(), 'remote_phase': 'Approved'},
      {...status(), 'local_resources_closed': true},
      {...status(), 'reason': 'raw error /private/secret'},
      {...status(), 'phase': 'listening'},
      {...status(), 'namespace': 'b' * 63},
      {
        ...status(),
        'target': {'host': 'https://secret.invalid', 'port': 443}
      },
    ]) {
      expect(NikoTunnelStatus.parse(jsonEncode(bad)), isNull);
    }
    expect(NikoTunnelStatus.parse('x' * 8193), isNull);
  });
  test(
      'host and command serialization bind exact target; remove has no target fields',
      () {
    expect(nikoTunnelHost(' Example.INVALID. '), 'example.invalid');
    expect(nikoTunnelHost('[::1]'), '::1');
    for (final bad in [
      'https://target.invalid',
      'user@target.invalid',
      'target.invalid:443',
      'a b',
      '-bad.invalid'
    ]) {
      expect(nikoTunnelHost(bad), isNull);
    }
    final add = NikoTunnelCommand.add(scope, '123456789', 1, '[::1]', 65535)!;
    expect(add.target!.label, '[::1]:65535');
    expect(jsonDecode(add.json), {
      'namespace': scope,
      'peer_id': '123456789',
      'op': 'add',
      'local_port': 1,
      'host': '::1',
      'remote_port': 65535
    });
    expect(jsonDecode(NikoTunnelCommand.remove(scope, '123456789', 1)!.json), {
      'namespace': scope,
      'peer_id': '123456789',
      'op': 'remove',
      'local_port': 1
    });
  });
  test('first any phase is accepted only on captured namespace and peer', () {
    final m = model();
    addTearDown(m.dispose);
    expect(
        m.handleEvent(event(status(phase: 'Listening', namespace: 'b' * 64))),
        isFalse);
    expect(m.handleEvent(event(status(peer: '987654321'))), isFalse);
    expect(
        m.handleEvent(
            {'name': 'nikodesk_tunnel_controller', 'status': status()}),
        isFalse);
    expect(m.handleEvent(event(status(phase: 'Listening'))), isTrue);
    expect(m.statuses[8000]!.phase, NikoTunnelPhase.listening);
  });
  test(
      'old generations, stale revisions, same-revision mutation and target swap are rejected',
      () {
    final m = model();
    addTearDown(m.dispose);
    m.handleEvent(
        event(status(generation: '8', revision: '9', phase: 'Listening')));
    for (final late in [
      status(generation: '7', revision: '99'),
      status(generation: '8', revision: '8'),
      status(generation: '8', revision: '9', phase: 'Closed', closed: true),
      status(generation: '8', revision: '10', host: 'other.invalid')
    ]) {
      expect(m.handleEvent(event(late)), isFalse);
    }
    expect(
        m.handleEvent(event(status(
            generation: '8', revision: '10', phase: 'Closed', closed: true))),
        isTrue);
    expect(
        m.handleEvent(event(
            status(generation: '9', revision: '1', host: 'other.invalid'))),
        isTrue);
    expect(
        m.handleEvent(event(status(
            generation: '8', revision: '999', phase: 'Closed', closed: true))),
        isFalse);
    expect(m.statuses[8000]!.target.host, 'other.invalid');
  });
  test('cleanup cannot revive an attempt or certify remote release', () {
    final m = model();
    addTearDown(m.dispose);
    m.handleEvent(event(status(phase: 'RecoveryRequired')));
    expect(m.canAdd(8000), isFalse);
    expect(m.handleEvent(event(status(phase: 'Listening', revision: '2'))),
        isFalse);
    expect(
        m.handleEvent(
            event(status(phase: 'Closed', revision: '2', closed: true))),
        isTrue);
    expect(m.canAdd(8000), isTrue);
    expect(m.statuses[8000]!.remotePhase, isNull);
    expect(m.handleEvent(event(status(phase: 'Connecting', revision: '3'))),
        isFalse);
  });
  test('queued add never becomes Listening and duplicate port is not sent',
      () async {
    final m = model();
    addTearDown(m.dispose);
    var sent = 0;
    final command =
        NikoTunnelCommand.add(scope, '123456789', 8000, 'target.invalid', 443)!;
    Future<String> transport(NikoTunnelCommand c) async {
      sent++;
      return '{"ok":true,"reason":"queued"}';
    }

    await m.send(command, transport);
    expect(m.statuses, isEmpty);
    expect(m.requests[8000]!.state, NikoTunnelRequestState.queued);
    await m.send(command, transport);
    expect(sent, 1);
    m.handleEvent(event(status(phase: 'WaitingApproval')));
    expect(m.requests, isEmpty);
    expect(m.statuses[8000]!.phase, NikoTunnelPhase.waitingApproval);
  });
  test(
      'timed-out add remains unconfirmed; cancel contains only original local port',
      () async {
    final m = model(timeout: const Duration(milliseconds: 1));
    addTearDown(m.dispose);
    final pending = Completer<String>();
    await m.send(
        NikoTunnelCommand.add(scope, '123456789', 8000, 'target.invalid', 443)!,
        (_) => pending.future);
    expect(m.requests[8000]!.state, NikoTunnelRequestState.unconfirmed);
    expect(m.canAdd(8000), isFalse);
    String? cancel;
    await m.send(NikoTunnelCommand.remove(scope, '123456789', 8000)!,
        (c) async {
      cancel = c.json;
      return '{"ok":true,"reason":"queued"}';
    });
    expect((jsonDecode(cancel!) as Map).keys,
        unorderedEquals(['namespace', 'peer_id', 'op', 'local_port']));
    pending.complete('{"ok":true,"reason":"queued"}');
    await Future<void>.delayed(Duration.zero);
    expect(m.requests[8000]!.command.op, 'remove');
    expect(m.requests[8000]!.target!.host, 'target.invalid');
    expect(m.statuses, isEmpty);
  });
  test('actual status arriving before queued reply is never overwritten',
      () async {
    final m = model();
    addTearDown(m.dispose);
    final reply = Completer<String>();
    final request = m.send(
        NikoTunnelCommand.add(scope, '123456789', 8000, 'target.invalid', 443)!,
        (_) => reply.future);
    m.handleEvent(event(status(phase: 'Listening')));
    reply.complete('{"ok":true,"reason":"queued"}');
    await request;
    expect(m.requests, isEmpty);
    expect(m.statuses[8000]!.phase, NikoTunnelPhase.listening);
  });
  test('malformed/unknown replies never clear an unconfirmed port', () async {
    for (final reply in [
      '{"ok":true,"reason":"running"}',
      '{"ok":true,"reason":"queued","phase":"Listening"}',
      'invalid'
    ]) {
      final m = model();
      await m.send(
          NikoTunnelCommand.add(
              scope, '123456789', 8000, 'target.invalid', 443)!,
          (_) async => reply);
      expect(m.requests[8000]!.state, NikoTunnelRequestState.unconfirmed);
      expect(m.canAdd(8000), isFalse);
      m.dispose();
    }
  });
  test('closed scope/session rejects late status and command result', () async {
    var current = true;
    final m = model(current: () => current);
    addTearDown(m.dispose);
    final reply = Completer<String>();
    final request = m.send(
        NikoTunnelCommand.add(scope, '123456789', 8000, 'target.invalid', 443)!,
        (_) => reply.future);
    current = false;
    m.invalidate();
    reply.complete('{"ok":true,"reason":"queued"}');
    await request;
    expect(m.handleEvent(event(status(phase: 'Listening'))), isFalse);
    expect(m.requests[8000]!.state, NikoTunnelRequestState.sending);
    expect(m.active, isFalse);
    expect(m.busy, isFalse);
  });
  test('status storage is bounded for a long-lived session', () {
    final m = model();
    addTearDown(m.dispose);
    for (var i = 1; i <= 64; i++) {
      expect(
          m.handleEvent(event(status(port: i, phase: 'Closed', closed: true))),
          isTrue);
    }
    expect(m.handleEvent(event(status(port: 65))), isFalse);
    expect(m.statuses.length, 64);
    expect(m.canAdd(65), isFalse);
  });
}
