import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/nikodesk/tunnel_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

const owner = NikoTunnelOwnerIdentity(
    '11111111-1111-4111-8111-111111111111',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    '123456789');
Map<String, dynamic> reply(
        {NikoTunnelOwnerIdentity identity = owner,
        bool ok = true,
        String reason = 'closed',
        bool closed = true}) =>
    {
      'session_id': identity.sessionId,
      'namespace': identity.namespace,
      'peer_id': identity.peerId,
      'ok': ok,
      'reason': reason,
      'local_resources_closed': closed,
    };
String roster({bool ok = true, String reason = 'cleanup_pending'}) =>
    jsonEncode({
      'ok': ok,
      'reason': reason,
      'owners': [
        {
          'session_id': owner.sessionId,
          'namespace': owner.namespace,
          'peer_id': owner.peerId,
          'reason': 'cleanup_pending'
        }
      ]
    });

void main() {
  test('only strict exact-owner closed+ok+true is a cleanup proof', () {
    expect(NikoTunnelCleanupReply.parse(jsonEncode(reply()), owner)!.confirmed,
        true);
    for (final changed in [
      {...reply(), 'extra': true},
      {...reply(), 'namespace': 'b' * 64},
      {...reply(), 'peer_id': '987654321'},
      {...reply(), 'session_id': '22222222-2222-4222-8222-222222222222'},
      reply(reason: 'cleanup_pending'),
      reply(ok: false),
      reply(reason: 'ui_detached'),
    ]) {
      expect(NikoTunnelCleanupReply.parse(jsonEncode(changed), owner), isNull);
    }
    expect(
        NikoTunnelCleanupReply.parse(
                jsonEncode(reply(reason: 'ui_detached', closed: false)), owner)!
            .confirmed,
        false);
    expect(
        NikoTunnelCleanupReply.parse(
                jsonEncode(
                    reply(reason: 'cleanup_pending', ok: false, closed: false)),
                owner)!
            .confirmed,
        false);
  });
  test(
      'query uses only immutable original scope and peer; empty list does not publish proof',
      () async {
    var value = roster();
    final m = NikoTunnelCleanupModel(
        readRetired: () async => value,
        query: (_) async => jsonEncode(reply()));
    addTearDown(m.dispose);
    expect(jsonDecode(owner.requestJson),
        {'namespace': owner.namespace, 'peer_id': owner.peerId});
    await m.refresh();
    expect(m.entries.single.owner.key, owner.key);
    final before = NikoTunnelCleanupProofs.confirmed.value;
    value = '{"ok":true,"reason":"closed","owners":[]}';
    await m.refresh();
    expect(m.entries, isEmpty);
    expect(NikoTunnelCleanupProofs.confirmed.value, same(before));
  });
  test('busy, malformed and timed-out list preserve previous owner', () async {
    var value = roster();
    final m = NikoTunnelCleanupModel(
        readRetired: () async => value,
        query: (_) async => '',
        timeout: const Duration(milliseconds: 1));
    addTearDown(m.dispose);
    await m.refresh();
    for (final bad in [
      '{"ok":false,"reason":"busy","owners":[]}',
      'invalid',
      '{"ok":true,"reason":"closed","owners":[{}]}'
    ]) {
      value = bad;
      await m.refresh();
      expect(m.entries.single.owner.key, owner.key);
      expect(m.unconfirmed, true);
    }
  });
  test(
      'false stopped-like response and identity mismatch cannot remove original owner',
      () async {
    var response = jsonEncode(reply(reason: 'cleanup_pending', closed: false));
    final m = NikoTunnelCleanupModel(
        readRetired: () async => roster(), query: (_) async => response);
    addTearDown(m.dispose);
    await m.refresh();
    await m.retry(m.entries.single);
    expect(m.entries.length, 1);
    expect(m.unconfirmed, true);
    response = jsonEncode({...reply(), 'namespace': 'b' * 64});
    await m.retry(m.entries.single);
    expect(m.entries.length, 1);
    response = jsonEncode(reply());
    await m.retry(m.entries.single);
    expect(m.entries, isEmpty);
    expect(NikoTunnelCleanupProofs.confirmed.value!.owner.same(owner), true);
  });
  test('a stale list cannot restore an owner after actual cleanup proof',
      () async {
    final list = Completer<String>();
    var count = 0;
    final m = NikoTunnelCleanupModel(
        readRetired: () {
          count++;
          return count == 1 ? Future.value(roster()) : list.future;
        },
        query: (_) async => jsonEncode(reply()));
    addTearDown(m.dispose);
    await m.refresh();
    final refreshing = m.refresh();
    await m.retry(m.entries.single);
    list.complete(roster());
    await refreshing;
    expect(m.entries, isEmpty);
  });
  test(
      'bounded timeout releases operation busy without clearing unknown resources',
      () async {
    final m = NikoTunnelCleanupModel(
        readRetired: () async => roster(),
        query: (_) => Completer<String>().future,
        timeout: const Duration(milliseconds: 1));
    addTearDown(m.dispose);
    await m.refresh();
    final entry = m.entries.single;
    await m.retry(entry);
    expect(m.busy(entry), false);
    expect(m.entries.single.owner.same(owner), true);
    expect(m.unconfirmed, true);
  });
}
