import 'dart:convert';

import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/nikodesk/cm_tunnel_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_cm_tunnel_test.dart'
    show actualTunnelFixtures, tunnelStatusRaw, tunnelQueued;

Map<String, dynamic> tunnelClient({Map<String, dynamic>? status}) {
  final actual = status ?? actualTunnelFixtures()['pending'];
  return {
    'id': actual['identity']['connection_id'],
    'authorized': true,
    'is_file_transfer': false,
    'is_view_camera': false,
    'is_terminal': false,
    'port_forward': '127.0.0.1:23456',
    'name': 'Synthetic tunnel peer',
    'peer_id': actual['identity']['peer_id'],
    'keyboard': false,
    'clipboard': false,
    'audio': false,
    'file': false,
    'restart': false,
    'recording': false,
    'block_input': false,
    'disconnected': false,
    'from_switch': false,
    'in_voice_call': false,
    'incoming_voice_call': false,
    'niko_tunnel': actual,
  };
}

void main() {
  const niko = bool.fromEnvironment('NIKODESK');
  test('actual Rust DTO anchors only authenticated native pure tunnel Client',
      () {
    final client = Client.fromJson(tunnelClient());
    expect(client.nikoTunnel != null, niko);
    expect(client.nikoTunnelContext?.active == true, niko);
    expect(client.nikoTunnelCleanup, false);
    expect(client.type_(), ClientType.portForward);
    expect(client.keyboard || client.audio || client.file, false);
  });

  test(
      'Client parser rejects mismatched route, authentication and session types',
      () {
    for (final changes in [
      {'id': 999},
      {'peer_id': '987654321'},
      {'authorized': false},
      {'disconnected': true},
      {'port_forward': ''},
      {'is_file_transfer': true},
      {'is_view_camera': true},
      {'is_terminal': true},
      {'niko_tunnel': tunnelStatusRaw()..['cleanup_only'] = true},
      {'niko_tunnel': tunnelStatusRaw()..['kind'] = 'terminal'},
      {'niko_tunnel': tunnelStatusRaw()..['unexpected'] = 'bad'},
      {'niko_tunnel': 'not a native snapshot'},
      {'niko_tunnel_cleanup': true},
      {'niko_tunnel_cleanup': 'true'},
    ]) {
      final client = Client.fromJson(tunnelClient()..addAll(changes));
      expect(client.nikoTunnel, isNull);
      expect(client.nikoTunnelContext, isNull);
      expect(client.nikoTunnelCleanup, false);
    }
  });

  test(
      'only native retired flag plus closed unauthorised cleanup phase anchors',
      () {
    for (final phase in ['Revoking', 'RecoveryRequired', 'Stopped']) {
      final raw = tunnelClient(
          status:
              tunnelStatusRaw(phase: phase, revision: '2', cleanupOnly: true))
        ..addAll({
          'niko_tunnel_cleanup': true,
          'authorized': false,
          'disconnected': true
        });
      final client = Client.fromJson(raw);
      expect(client.nikoTunnelCleanup, niko);
      expect(client.nikoTunnelContext?.cleanupOnly == true, niko);
      expect(client.nikoTunnelContext?.active == false, niko);
      for (final invalid in [
        {'niko_tunnel_cleanup': false},
        {'niko_tunnel_cleanup': 'true'},
        {'authorized': true},
        {'disconnected': false},
      ]) {
        expect(
            Client.fromJson(Map<String, dynamic>.from(raw)..addAll(invalid))
                .nikoTunnel,
            isNull);
      }
    }
    for (final phase in ['Pending', 'Starting', 'Running']) {
      final status = tunnelStatusRaw(
          phase: phase,
          addresses: phase == 'Pending' ? [] : ['127.0.0.1:23456'],
          selected: phase == 'Pending' ? null : '127.0.0.1:23456');
      expect(
          Client.fromJson(tunnelClient(status: status)
                ..addAll({
                  'niko_tunnel_cleanup': true,
                  'authorized': false,
                  'disconnected': true,
                }))
              .nikoTunnel,
          isNull);
    }
  });

  test(
      'production Client snapshots update original ledger and preserve late identity fence',
      () {
    if (!niko) return;
    final ledger = NikoCmTunnelLedger(command: (c) async => tunnelQueued(c));
    addTearDown(ledger.dispose);
    final pending = Client.fromJson(tunnelClient());
    expect(
        ledger.anchor(pending.nikoTunnel!, pending.nikoTunnelContext!), true);
    final original = ledger.model(pending.id)!;
    final resolved = Client.fromJson(tunnelClient(
        status: tunnelStatusRaw(
            revision: '2',
            reason: 'select_exact_address',
            addresses: ['127.0.0.1:23456'])));
    expect(
        ledger.anchor(resolved.nikoTunnel!, resolved.nikoTunnelContext!), true);
    expect(ledger.model(pending.id), same(original));
    final retiring = Client.fromJson(tunnelClient(
        status: tunnelStatusRaw(
            phase: 'Revoking', revision: '3', cleanupOnly: true))
      ..addAll({
        'niko_tunnel_cleanup': true,
        'authorized': false,
        'disconnected': true,
      }));
    expect(
        ledger.anchor(retiring.nikoTunnel!, retiring.nikoTunnelContext!), true);
    ledger.retain({});
    expect(ledger.model(pending.id), same(original));
    expect(original.cleanupOnly, true);
    final foreignIdentity =
        Map<String, dynamic>.from(tunnelStatusRaw()['identity'])
          ..['namespace'] = 'e' * 64;
    final foreignRaw = tunnelStatusRaw()..['identity'] = foreignIdentity;
    final foreign = Client.fromJson(tunnelClient(status: foreignRaw));
    expect(
        ledger.anchor(foreign.nikoTunnel!, foreign.nikoTunnelContext!), false);
    expect(original.status.identity.namespace,
        actualTunnelFixtures()['pending']['identity']['namespace']);
  });

  test('stock Client ignores actual tunnel DTO rather than enabling Niko route',
      () {
    final client = Client.fromJson(tunnelClient());
    if (!niko) {
      expect(client.nikoTunnel, isNull);
      expect(client.nikoTunnelContext, isNull);
      expect(client.nikoTunnelCleanup, false);
    }
    expect(jsonDecode(jsonEncode(client.toJson()))['port_forward'],
        '127.0.0.1:23456');
  });
}
