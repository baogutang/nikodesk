import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/cm_capabilities.dart';
import 'package:flutter_hbb/nikodesk/cm_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

// Production tunnel_flow serializer output; synthetic inputs and regeneration
// instructions are tracked beside the fixture in test/fixtures/nikodesk/.
Map<String, dynamic> actualTunnelFixtures() =>
    jsonDecode(File('test/fixtures/nikodesk/tunnel-flow-serde.json')
        .readAsStringSync());

Map<String, dynamic> tunnelStatusRaw(
        {String phase = 'Pending',
        String reason = 'local_approval_required',
        String revision = '1',
        String resourceEpoch = '1',
        List<String> addresses = const [],
        String? selected,
        bool cleanupOnly = false}) =>
    Map<String, dynamic>.from(actualTunnelFixtures()['pending'])
      ..addAll({
        'phase': phase,
        'reason': reason,
        'revision': revision,
        'resource_epoch': resourceEpoch,
        'addresses': addresses,
        'selected_address': selected,
        'cleanup_only': cleanupOnly,
      });
NikoTunnelStatus tunnelStatus(
        {String phase = 'Pending',
        String reason = 'local_approval_required',
        String revision = '1',
        String resourceEpoch = '1',
        List<String> addresses = const [],
        String? selected,
        bool cleanupOnly = false}) =>
    NikoTunnelStatus.parse(jsonEncode(tunnelStatusRaw(
        phase: phase,
        reason: reason,
        revision: revision,
        resourceEpoch: resourceEpoch,
        addresses: addresses,
        selected: selected,
        cleanupOnly: cleanupOnly)))!;
String tunnelQueued(NikoTunnelCommand command) => jsonEncode({
      'ok': true,
      'reason': 'queued',
      'identity': command.captured.identity.toJson(),
      'revision': command.captured.revision,
    });
NikoCmTunnelModel tunnelModel(NikoTunnelStatus initial,
        {NikoTunnelTransport? transport,
        bool cleanupOnly = false,
        bool active = true,
        Duration timeout = const Duration(seconds: 5)}) =>
    NikoCmTunnelModel.fromVerifiedContext(
        // Explicit substitute for the verified native CM producer in these tests.
        context: NikoTunnelCmContext.verifiedNative(
            identity: initial.identity,
            active: active,
            cleanupOnly: cleanupOnly),
        initialStatus: initial,
        commandTimeout: timeout,
        transport: transport ?? (command) async => tunnelQueued(command));
NikoTunnelStatus resolvedTunnel(
        {String revision = '2',
        List<String> addresses = const ['127.0.0.1:23456']}) =>
    tunnelStatus(
        revision: revision,
        reason: 'select_exact_address',
        addresses: addresses);

void main() {
  test('actual Rust pending, commands and queued Reply cross the Dart boundary',
      () {
    final fixture = actualTunnelFixtures();
    final pending = NikoTunnelStatus.parse(jsonEncode(fixture['pending']))!;
    expect(pending.phase, 'Pending');
    expect(pending.target.label, '127.0.0.1:23456');
    for (final op in ['query', 'resolve', 'retry_cleanup']) {
      final command = NikoTunnelCommand.create(pending, op)!;
      expect(command.toJson(), fixture[op]);
      expect(
          NikoTunnelReply.parse(jsonEncode(fixture['queued']), command)!.queued,
          isTrue);
    }
    final resolved = resolvedTunnel(revision: '1');
    expect(
        NikoTunnelCommand.create(resolved, 'approve',
                address: '127.0.0.1:23456')!
            .toJson(),
        fixture['approve']);
  });
  test('status rejects unknown fields, legacy kind and missing required data',
      () {
    for (final raw in [
      tunnelStatusRaw()..['kind'] = 'port_forward',
      tunnelStatusRaw()..['phase'] = 'Ready',
      tunnelStatusRaw()..['raw_error'] = 'private path',
      tunnelStatusRaw()..remove('cleanup_only'),
      tunnelStatusRaw()..['cleanup_only'] = 'false',
      tunnelStatusRaw()..['reason'] = '/Users/private',
      tunnelStatusRaw()..['reason'] = 'x' * 97,
      tunnelStatusRaw()..['target'] = {'host': 'http://private:80', 'port': 80},
      tunnelStatusRaw()..['target'] = {'host': 'private', 'port': 0},
      tunnelStatusRaw()..['target'] = {'host': '0.0.0.0', 'port': 23456},
      tunnelStatusRaw()..['selected_address'] = '127.0.0.1:23456',
      tunnelStatusRaw(phase: 'Running'),
    ]) {
      expect(NikoTunnelStatus.parse(jsonEncode(raw)), isNull);
    }
    expect(NikoTunnelStatus.parse('x' * 8193), isNull);
  });
  test('u64 decimal identity, revision and resource epochs are canonical', () {
    for (final value in ['0', '01', '-1', '1e3', '18446744073709551616', 1]) {
      for (final key in ['revision', 'resource_epoch']) {
        expect(
            NikoTunnelStatus.parse(
                jsonEncode(tunnelStatusRaw()..[key] = value)),
            isNull);
      }
      final raw = tunnelStatusRaw();
      raw['identity']['epoch'] = value;
      expect(NikoTunnelStatus.parse(jsonEncode(raw)), isNull);
    }
    expect(tunnelStatus(revision: '18446744073709551615').revision,
        '18446744073709551615');
  });
  test('bounded SocketAddr results preserve real IP, port and loopback meaning',
      () {
    for (final address in ['127.12.3.4:23456', '[::1]:23456']) {
      expect(NikoTunnelAddress.parse(address)!.loopback, isTrue);
    }
    for (final address in ['10.0.0.7:23456', '[2001:db8::1]:23456']) {
      expect(NikoTunnelAddress.parse(address)!.loopback, isFalse);
    }
    for (final address in [
      'private:23456',
      'tcp://127.0.0.1:23456',
      '127.0.0.1:02345',
      '127.0.0.1:65536',
      '0.0.0.0:23456',
      '224.0.0.1:23456',
      '[ff01::1]:23456',
      '[::]:23456',
      '[fe80::1%en0]:23456',
      '[0:0:0:0:0:0:0:1]:23456',
      '[::ffff:127.0.0.1]:23456'
    ]) {
      expect(NikoTunnelAddress.parse(address), isNull);
    }
    for (final addresses in [
      ['127.0.0.1:23456', '127.0.0.1:23456'],
      ['127.0.0.1:22'],
      List.generate(9, (i) => '10.0.0.${i + 1}:23456')
    ]) {
      expect(
          NikoTunnelStatus.parse(
              jsonEncode(tunnelStatusRaw(addresses: addresses))),
          isNull);
    }
  });
  test('arbitrary event Status cannot create or replace the verified CM anchor',
      () {
    final initial = tunnelStatus();
    final other = Map<String, dynamic>.from(initial.identity.toJson())
      ..['connection_id'] = 8;
    expect(
        () => NikoCmTunnelModel.fromVerifiedContext(
            context: NikoTunnelCmContext.verifiedNative(
                identity: NikoCapabilityIdentity.parse(other)!),
            initialStatus: initial,
            transport: (command) async => tunnelQueued(command)),
        throwsArgumentError);
    final model = tunnelModel(initial);
    addTearDown(model.dispose);
    for (final mutation in [
      {'connection_id': 8},
      {'peer_id': '987654321'},
      {'namespace': 'b' * 64},
      {'connection_nonce': '3' * 32},
      {'request_nonce': '4' * 32},
      {'epoch': '2'}
    ]) {
      final raw = tunnelStatusRaw(revision: '2');
      raw['identity'] = Map<String, dynamic>.from(raw['identity'])
        ..addAll(mutation);
      expect(
          model.applyStatus(NikoTunnelStatus.parse(jsonEncode(raw))!), isFalse);
    }
    expect(model.status.sameSnapshot(initial), isTrue);
  });
  test(
      'malformed identity and zero nonce reject rather than using global identity',
      () {
    for (final mutation in [
      {'connection_id': 2147483648},
      {'peer_id': 'abc'},
      {'connection_nonce': '0' * 32},
      {'request_nonce': 'FF' * 16},
      {'namespace': 'A' * 64},
      {'global_scope': true}
    ]) {
      final raw = tunnelStatusRaw();
      raw['identity'].addAll(mutation);
      expect(NikoTunnelStatus.parse(jsonEncode(raw)), isNull);
    }
  });
  test('revision, resource and immutable target cannot roll back or mutate',
      () {
    final model = tunnelModel(tunnelStatus(revision: '4', resourceEpoch: '3'));
    addTearDown(model.dispose);
    for (final value in [
      tunnelStatus(revision: '3', resourceEpoch: '3'),
      tunnelStatus(revision: '5', resourceEpoch: '2'),
      tunnelStatus(
          revision: '4', resourceEpoch: '3', reason: 'select_exact_address')
    ]) {
      expect(model.applyStatus(value), isFalse);
    }
    final raw = tunnelStatusRaw(revision: '5', resourceEpoch: '3');
    raw['target'] = {'host': 'other.example', 'port': 23456};
    expect(
        model.applyStatus(NikoTunnelStatus.parse(jsonEncode(raw))!), isFalse);
  });
  test('unknown bounded reason is readable but cannot grant or resolve', () {
    final model = tunnelModel(tunnelStatus(reason: 'unknown_future_reason'));
    addTearDown(model.dispose);
    expect(model.mayResolve, isFalse);
    expect(model.mayApprove('127.0.0.1:23456'), isFalse);
    expect(model.maySend('query'), isTrue);
  });
  test('opening and queuing resolution neither resolves locally nor starts',
      () async {
    final sent = <NikoTunnelCommand>[];
    final model = tunnelModel(tunnelStatus(), transport: (command) async {
      sent.add(command);
      return tunnelQueued(command);
    });
    addTearDown(model.dispose);
    expect(sent, isEmpty);
    expect(await model.send('resolve'), isTrue);
    expect(model.status.addresses, isEmpty);
    expect(model.status.phase, 'Pending');
    expect(model.resolveUnconfirmed, isTrue);
    expect(model.mayApprove('127.0.0.1:23456'), isFalse);
    expect(model.applyStatus(tunnelStatus(revision: '2', reason: 'resolving')),
        isTrue);
    expect(model.resolveUnconfirmed, isTrue);
    expect(model.applyStatus(resolvedTunnel(revision: '3')), isTrue);
    expect(model.resolveUnconfirmed, isFalse);
    expect(sent.single.op, 'resolve');
  });
  test('late queued reply cannot overwrite newer native resolution', () async {
    final reply = Completer<String>();
    NikoTunnelCommand? command;
    final model = tunnelModel(tunnelStatus(), transport: (value) {
      command = value;
      return reply.future;
    });
    addTearDown(model.dispose);
    final request = model.send('resolve');
    expect(model.applyStatus(resolvedTunnel()), isTrue);
    reply.complete(tunnelQueued(command!));
    expect(await request, isFalse);
    expect(model.operationMessage, isNull);
    expect(model.status.revision, '2');
  });
  test('exact selected address and explicit nonloopback approval are mandatory',
      () async {
    final model = tunnelModel(resolvedTunnel(addresses: ['10.0.0.7:23456']));
    addTearDown(model.dispose);
    expect(model.mayApprove(null), isFalse);
    expect(model.mayApprove('10.0.0.8:23456', allowNonLoopback: true), isFalse);
    expect(model.mayApprove('10.0.0.7:23456'), isFalse);
    final command = NikoTunnelCommand.create(model.status, 'approve',
        address: '10.0.0.7:23456', allowNonLoopback: true)!;
    expect(command.toJson()['access'], 'non_loopback');
    expect(
        NikoTunnelCommand.create(model.status, 'query',
            address: '10.0.0.7:23456'),
        isNull);
    expect(NikoTunnelCommand.create(model.status, 'legacy'), isNull);
    expect(utf8.encode(command.json).length, lessThanOrEqualTo(4096));
  });
  test(
      'queued approval stays Pending, then only native FD facts establish Running',
      () async {
    final model = tunnelModel(resolvedTunnel());
    addTearDown(model.dispose);
    expect(await model.send('approve', address: '127.0.0.1:23456'), isTrue);
    expect(model.status.phase, 'Pending');
    expect(model.approvalUnconfirmed, isTrue);
    expect(model.applyStatus(model.status), isTrue);
    expect(model.approvalUnconfirmed, isTrue);
    expect(
        model.applyStatus(tunnelStatus(
            phase: 'Starting',
            revision: '3',
            reason: 'awaiting_first_owned_socket',
            addresses: ['127.0.0.1:23456'],
            selected: '127.0.0.1:23456')),
        isTrue);
    expect(model.status.phase, 'Starting');
    expect(
        model.applyStatus(tunnelStatus(
            phase: 'Running',
            revision: '4',
            reason: 'running',
            addresses: ['127.0.0.1:23456'],
            selected: '127.0.0.1:23456')),
        isTrue);
    expect(model.status.phase, 'Running');
  });
  test('selected address freezes after approval and stopping never revives',
      () async {
    final addresses = ['127.0.0.1:23456', '127.0.0.2:23456'];
    final model = tunnelModel(resolvedTunnel(addresses: addresses));
    addTearDown(model.dispose);
    await model.send('approve', address: addresses.first);
    expect(
        model.applyStatus(tunnelStatus(
            phase: 'Starting',
            revision: '3',
            addresses: addresses,
            selected: addresses.last)),
        isFalse);
    expect(
        model.applyStatus(
            tunnelStatus(phase: 'RecoveryRequired', revision: '3')),
        isTrue);
    expect(
        model.applyStatus(tunnelStatus(
            phase: 'Running',
            revision: '4',
            addresses: addresses,
            selected: addresses.first)),
        isFalse);
    expect(model.applyStatus(tunnelStatus(phase: 'Stopped', revision: '4')),
        isTrue);
    expect(model.applyStatus(resolvedTunnel(revision: '5')), isFalse);
  });
  test('only trusted context retirement enables cleanup across rebuilds',
      () async {
    final model = tunnelModel(resolvedTunnel());
    addTearDown(model.dispose);
    expect(model.applyStatus(tunnelStatus(revision: '3', cleanupOnly: true)),
        isFalse);
    final wrongContext = NikoCapabilityIdentity.parse(
        Map<String, dynamic>.from(model.status.identity.toJson())
          ..['namespace'] = 'f' * 64)!;
    expect(
        model.updateContext(NikoTunnelCmContext.verifiedNative(
            identity: wrongContext, active: false)),
        isFalse);
    expect(model.cleanupOnly, isFalse);
    expect(
        model.updateContext(NikoTunnelCmContext.verifiedNative(
            identity: model.status.identity, active: false)),
        isTrue);
    expect(model.cleanupOnly, isTrue);
    expect(model.mayResolve, isFalse);
    expect(model.maySend('deny'), isFalse);
    expect(model.maySend('query'), isTrue);
    expect(model.maySend('retry_cleanup'), isTrue);
    expect(
        model.updateContext(NikoTunnelCmContext.verifiedNative(
            identity: model.status.identity)),
        isTrue);
    expect(model.cleanupOnly, isTrue);
    expect(await model.send('retry_cleanup'), isTrue);
    expect(model.cleanupUnconfirmed, isTrue);
  });
  test('revoke timeout retains original owner cleanup until new Stopped fact',
      () async {
    final never = Completer<String>();
    final model = tunnelModel(
        tunnelStatus(
            phase: 'Running',
            reason: 'running',
            addresses: ['127.0.0.1:23456'],
            selected: '127.0.0.1:23456'),
        timeout: const Duration(milliseconds: 5),
        transport: (_) => never.future);
    addTearDown(model.dispose);
    expect(await model.send('revoke'), isFalse);
    expect(model.busy, isFalse);
    expect(model.cleanupUnconfirmed, isTrue);
    expect(model.status.phase, 'Running');
    expect(model.maySend('query'), isTrue);
    expect(model.maySend('retry_cleanup'), isTrue);
    expect(
        model.applyStatus(
            tunnelStatus(phase: 'RecoveryRequired', revision: '2')),
        isTrue);
    expect(model.cleanupUnconfirmed, isTrue);
    expect(
        model.applyStatus(tunnelStatus(
            phase: 'Stopped', revision: '3', reason: 'cleanup_confirmed')),
        isTrue);
    expect(model.cleanupUnconfirmed, isFalse);
  });
  test('queued cleanup, failures and unknown reply never synthesize Stopped',
      () async {
    final model =
        tunnelModel(tunnelStatus(phase: 'RecoveryRequired'), cleanupOnly: true);
    addTearDown(model.dispose);
    expect(await model.send('retry_cleanup'), isTrue);
    expect(model.status.phase, 'RecoveryRequired');
    expect(model.cleanupUnconfirmed, isTrue);
    final bad = tunnelModel(tunnelStatus(phase: 'RecoveryRequired'),
        transport: (_) async => '{"ok":true,"status":"Stopped"}');
    addTearDown(bad.dispose);
    expect(await bad.send('retry_cleanup'), isFalse);
    expect(bad.status.phase, 'RecoveryRequired');
    expect(bad.operationMessage, 'operation_unconfirmed');
    expect(bad.cleanupUnconfirmed, isTrue);
  });
  test('expired reply blocks approval without pretending shutdown was observed',
      () async {
    final model = tunnelModel(resolvedTunnel(),
        transport: (command) async => jsonEncode({
              'ok': false,
              'reason': 'tunnel_request_expired',
              'identity': command.captured.identity.toJson(),
              'revision': command.captured.revision
            }));
    addTearDown(model.dispose);
    expect(await model.send('approve', address: '127.0.0.1:23456'), isFalse);
    expect(model.status.phase, 'Pending');
    expect(model.mayResolve, isFalse);
    expect(model.maySend('query'), isTrue);
    expect(
        model.applyStatus(tunnelStatus(
            phase: 'Stopped', revision: '3', reason: 'tunnel_request_expired')),
        isTrue);
    expect(model.mayApprove('127.0.0.1:23456'), isFalse);
  });
  test('reply rejects mismatched request, revision and fake Running success',
      () {
    final command = NikoTunnelCommand.create(tunnelStatus(), 'query')!;
    final raw = jsonDecode(tunnelQueued(command));
    for (final mutation in [
      {'revision': '2'},
      {'reason': 'running'},
      {'status': 'queued'},
      {'ok': false}
    ]) {
      expect(
          NikoTunnelReply.parse(
              jsonEncode(Map.from(raw)..addAll(mutation)), command),
          isNull);
    }
    raw['identity']['namespace'] = 'f' * 64;
    expect(NikoTunnelReply.parse(jsonEncode(raw), command), isNull);
  });
  test(
      'dispose and replacing context cannot let an old future alter a new owner',
      () async {
    final late = Completer<String>();
    NikoTunnelCommand? command;
    final old = tunnelModel(tunnelStatus(), transport: (value) {
      command = value;
      return late.future;
    });
    final pending = old.send('query');
    old.dispose();
    final fresh = tunnelModel(tunnelStatus());
    addTearDown(fresh.dispose);
    late.complete(tunnelQueued(command!));
    expect(await pending, isFalse);
    expect(fresh.operationMessage, isNull);
    expect(fresh.status.phase, 'Pending');
  });
  test('transport exceptions stay bounded and retain cleanup recovery',
      () async {
    final model = tunnelModel(tunnelStatus(phase: 'RecoveryRequired'),
        transport: (_) async => throw StateError('/Users/private/password'));
    addTearDown(model.dispose);
    expect(await model.send('retry_cleanup'), isFalse);
    expect(model.operationMessage, 'channel_unavailable');
    expect(model.maySend('retry_cleanup'), isTrue);
    expect(model.cleanupUnconfirmed, isTrue);
  });
}
