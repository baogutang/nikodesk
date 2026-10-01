import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/nikodesk/cm_tunnel.dart';
import 'package:flutter_hbb/nikodesk/cm_tunnel_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_cm_tunnel_test.dart'
    show actualTunnelFixtures, tunnelStatus, tunnelStatusRaw, tunnelQueued;

NikoTunnelCmContext context(NikoTunnelStatus status, {bool cleanup = false}) =>
    NikoTunnelCmContext.verifiedNative(
        identity: status.identity, active: !cleanup, cleanupOnly: cleanup);

NikoTunnelStatus changedIdentity(String field, dynamic value,
    {String phase = 'Pending', String revision = '1'}) {
  final raw = tunnelStatusRaw(phase: phase, revision: revision);
  raw['identity'] = Map<String, dynamic>.from(raw['identity'])..[field] = value;
  return NikoTunnelStatus.parse(jsonEncode(raw))!;
}

void main() {
  test(
      'actual Rust Pending creates one original owner and no automatic command',
      () {
    var sent = 0;
    final ledger = NikoCmTunnelLedger(command: (command) async {
      sent++;
      return tunnelQueued(command);
    });
    addTearDown(ledger.dispose);
    final status =
        NikoTunnelStatus.parse(jsonEncode(actualTunnelFixtures()['pending']))!;
    expect(ledger.anchor(status, context(status)), true);
    final original = ledger.model(status.identity.connectionId);
    expect(ledger.anchor(status, context(status)), true);
    expect(ledger.model(status.identity.connectionId), same(original));
    expect(sent, 0);
  });

  test(
      'first active anchor rejects advanced counters, phase or resolved address',
      () {
    for (final status in [
      tunnelStatus(revision: '2'),
      tunnelStatus(resourceEpoch: '2'),
      tunnelStatus(addresses: ['127.0.0.1:23456']),
      tunnelStatus(
          phase: 'Starting',
          addresses: ['127.0.0.1:23456'],
          selected: '127.0.0.1:23456'),
      tunnelStatus(
          phase: 'Running',
          addresses: ['127.0.0.1:23456'],
          selected: '127.0.0.1:23456'),
      tunnelStatus(phase: 'Stopped'),
    ]) {
      final ledger = NikoCmTunnelLedger(command: (c) async => tunnelQueued(c));
      expect(ledger.anchor(status, context(status)), false);
      expect(ledger.isNotEmpty, false);
      ledger.dispose();
    }
  });

  test('trusted retired native snapshots restore only readonly cleanup phases',
      () {
    for (final phase in ['Revoking', 'RecoveryRequired', 'Stopped']) {
      final ledger = NikoCmTunnelLedger(command: (c) async => tunnelQueued(c));
      final status =
          tunnelStatus(phase: phase, revision: '5', cleanupOnly: true);
      expect(ledger.anchor(status, context(status, cleanup: true)), true);
      expect(ledger.model(status.identity.connectionId)!.cleanupOnly, true);
      expect(ledger.model(status.identity.connectionId)!.mayResolve, false);
      ledger.dispose();
    }
    for (final phase in ['Pending', 'Starting', 'Running']) {
      final ledger = NikoCmTunnelLedger(command: (c) async => tunnelQueued(c));
      final status = tunnelStatus(
          phase: phase,
          addresses: phase == 'Pending' ? [] : ['127.0.0.1:23456'],
          selected: phase == 'Pending' ? null : '127.0.0.1:23456');
      expect(ledger.anchor(status, context(status, cleanup: true)), false);
      ledger.dispose();
    }
  });

  test('ordinary cleanup_only payload cannot manufacture retired authority',
      () {
    final status = tunnelStatus(cleanupOnly: true);
    final ledger = NikoCmTunnelLedger(command: (c) async => tunnelQueued(c));
    addTearDown(ledger.dispose);
    expect(ledger.anchor(status, context(status)), false);
    expect(ledger.isNotEmpty, false);
  });

  test('wrong captured context identity cannot establish an owner', () {
    final status = tunnelStatus();
    final foreign = changedIdentity('namespace', 'b' * 64);
    final ledger = NikoCmTunnelLedger(command: (c) async => tunnelQueued(c));
    addTearDown(ledger.dispose);
    expect(ledger.anchor(status, context(foreign)), false);
  });

  test('same peer new connection never evicts prior cleanup owner', () {
    final ledger = NikoCmTunnelLedger(command: (c) async => tunnelQueued(c));
    addTearDown(ledger.dispose);
    final old = tunnelStatus();
    final newer =
        changedIdentity('connection_id', old.identity.connectionId + 1);
    ledger.anchor(old, context(old));
    final original = ledger.model(old.identity.connectionId)!;
    ledger.retire(old.identity.connectionId);
    expect(ledger.anchor(newer, context(newer)), true);
    ledger.retain({newer.identity.connectionId});
    expect(ledger.model(old.identity.connectionId), same(original));
    expect(original.cleanupOnly, true);
    expect(original.status.phase, 'Pending');
    expect(ledger.model(newer.identity.connectionId)!.cleanupOnly, false);
  });

  test(
      'same id foreign namespace, peer, nonce or epoch never replaces live owner',
      () {
    for (final change in {
      'namespace': 'b' * 64,
      'peer_id': '987654321',
      'connection_nonce': 'c' * 32,
      'request_nonce': 'd' * 32,
      'epoch': '2',
    }.entries) {
      final ledger = NikoCmTunnelLedger(command: (c) async => tunnelQueued(c));
      final status = tunnelStatus();
      ledger.anchor(status, context(status));
      final original = ledger.model(status.identity.connectionId)!;
      final other = changedIdentity(change.key, change.value);
      expect(ledger.anchor(other, context(other)), false);
      expect(ledger.model(status.identity.connectionId), same(original));
      expect(original.status.identity.sameRequest(status.identity), true);
      expect(original.cleanupOnly, true);
      ledger.dispose();
    }
  });

  test('snapshot absence, remove and clear retain uncertainty without Stopped',
      () {
    final ledger = NikoCmTunnelLedger(command: (c) async => tunnelQueued(c));
    addTearDown(ledger.dispose);
    final status = tunnelStatus();
    ledger.anchor(status, context(status));
    final original = ledger.model(status.identity.connectionId)!;
    ledger.retain({});
    expect(ledger.remove(status.identity.connectionId), false);
    ledger.clear();
    expect(ledger.model(status.identity.connectionId), same(original));
    expect(original.cleanupOnly, true);
    expect(original.cleanupUnconfirmed, true);
    expect(original.status.phase, 'Pending');
    expect(original.maySend('query'), true);
    expect(original.maySend('retry_cleanup'), true);
    expect(original.maySend('resolve'), false);
  });

  test(
      'retired queued, missing native connection and malformed reply never stop',
      () async {
    for (final reason in ['queued', 'cm_connection_missing', 'closed', null]) {
      final ledger = NikoCmTunnelLedger(
          command: (command) async => reason == null
              ? '{}'
              : jsonEncode({
                  'ok': reason == 'queued',
                  'reason': reason,
                  'identity': command.captured.identity.toJson(),
                  'revision': command.captured.revision,
                }));
      final status = tunnelStatus();
      ledger.anchor(status, context(status));
      ledger.retire(status.identity.connectionId);
      final original = ledger.model(status.identity.connectionId)!;
      await original.send('retry_cleanup');
      expect(original.status.phase, 'Pending');
      expect(original.cleanupUnconfirmed, true);
      expect(ledger.remove(status.identity.connectionId), false);
      ledger.dispose();
    }
  });

  test(
      'new native cleanup snapshot retains same model then actual Stopped removes',
      () {
    final ledger = NikoCmTunnelLedger(command: (c) async => tunnelQueued(c));
    addTearDown(ledger.dispose);
    final initial = tunnelStatus();
    ledger.anchor(initial, context(initial));
    final original = ledger.model(initial.identity.connectionId)!;
    final retiring =
        tunnelStatus(phase: 'Revoking', revision: '2', cleanupOnly: true);
    expect(ledger.anchor(retiring, context(retiring, cleanup: true)), true);
    expect(ledger.model(initial.identity.connectionId), same(original));
    final stopped =
        tunnelStatus(phase: 'Stopped', revision: '3', cleanupOnly: true);
    expect(ledger.anchor(stopped, context(stopped, cleanup: true)), true);
    expect(original.cleanupUnconfirmed, false);
    expect(ledger.remove(initial.identity.connectionId), true);
    expect(ledger.isNotEmpty, false);
  });

  test('immutable target and rollback snapshots cannot overwrite current owner',
      () {
    final ledger = NikoCmTunnelLedger(command: (c) async => tunnelQueued(c));
    addTearDown(ledger.dispose);
    final initial = tunnelStatus();
    ledger.anchor(initial, context(initial));
    final next = tunnelStatus(revision: '3', resourceEpoch: '2');
    expect(ledger.anchor(next, context(next)), true);
    final changed = NikoTunnelStatus.parse(jsonEncode(
        tunnelStatusRaw(revision: '4')
          ..['target'] = {'host': 'private.example', 'port': 23456}))!;
    for (final stale in [initial, changed]) {
      expect(ledger.anchor(stale, context(stale)), false);
    }
    expect(ledger.model(initial.identity.connectionId)!.status, same(next));
  });

  test(
      'late queued after retirement cannot restore active grant or old message',
      () async {
    final pending = Completer<String>();
    late NikoTunnelCommand sent;
    final ledger = NikoCmTunnelLedger(command: (command) {
      sent = command;
      return pending.future;
    });
    addTearDown(ledger.dispose);
    final status = tunnelStatus();
    ledger.anchor(status, context(status));
    final original = ledger.model(status.identity.connectionId)!;
    final future = original.send('resolve');
    ledger.retire(status.identity.connectionId);
    pending.complete(tunnelQueued(sent));
    expect(await future, false);
    expect(original.cleanupOnly, true);
    expect(original.mayResolve, false);
    expect(original.operationMessage, isNull);
  });

  test(
      'timeout survives ledger refresh; disposed owner cannot affect replacement',
      () async {
    final pending = Completer<String>();
    late NikoTunnelCommand sent;
    final ledger = NikoCmTunnelLedger(
        commandTimeout: const Duration(milliseconds: 5),
        command: (command) {
          sent = command;
          return pending.future;
        });
    final status = tunnelStatus();
    ledger.anchor(status, context(status));
    final original = ledger.model(status.identity.connectionId)!;
    ledger.retire(status.identity.connectionId);
    expect(await original.send('retry_cleanup'), false);
    expect(ledger.anchor(status, context(status)), true);
    expect(original.cleanupOnly, true);
    expect(original.cleanupUnconfirmed, true);
    expect(original.operationMessage, 'operation_unconfirmed');
    ledger.dispose();
    pending.complete(tunnelQueued(sent));
    await Future<void>.delayed(Duration.zero);
    expect(original.cleanupUnconfirmed, true);
  });
}
