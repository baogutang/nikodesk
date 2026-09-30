import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/nikodesk/peer_event_scope.dart';
import 'package:flutter_hbb/nikodesk/server_scope.dart';

void main() {
  final a = 'a' * 64;
  final b = 'b' * 64;
  Map<String, dynamic> online(String? ns, Object? on, Object? off) => {
        'name': 'callback_query_onlines',
        if (ns != null) 'nikodesk-server-namespace': ns,
        'onlines': on,
        'offlines': off,
      };
  test('malformed, unattributed or ambiguous online events are ignored', () {
    for (final event in [
      online(null, '123456789', ''),
      online(b, '123456789', ''),
      online(a, null, ''),
      online(a, '123456789,', ''),
      online(a, '123456789,123456789', ''),
      online(a, '123456789', '123456789'),
      online(a, 'endpoint.example', ''),
      online(a, List.filled(4097, '123456789').join(','), ''),
    ]) {
      expect(nikoScopedOnlineEvent(event, a), isNull);
    }
    final ready =
        nikoScopedOnlineEvent(online(a, '123456789', '987654321'), a)!;
    expect(ready.onlines, {'123456789'});
    expect(ready.offlines, {'987654321'});
    expect(nikoScopedOnlineEvent(online(a, '', ''), a), isNotNull);
  });

  test(
      'actual event dispatcher refuses queued server-A state after switch to B',
      () async {
    NikoServerScope.activate(a);
    final peers = Peers(
        name: 'online-scope-regression',
        getInitPeers: null,
        loadEvent: 'load_recent_peers');
    addTearDown(() {
      peers.dispose();
      NikoServerScope.activate(null);
    });
    Map<String, dynamic> load(String ns) => {
          'name': 'load_recent_peers',
          'nikodesk-server-namespace': ns,
          'nikodesk-load-status': 'ready',
          'peers': jsonEncode([
            {'id': '123456789', 'alias': 'Work'}
          ]),
        };
    await platformFFI.tryHandle(load(a));
    await platformFFI.tryHandle(online(a, '123456789', ''));
    expect(peers.peers.single.online, isTrue);
    NikoServerScope.activate(b);
    await platformFFI.tryHandle(load(b));
    expect(peers.peers.single.online, isFalse);
    await platformFFI.tryHandle(online(a, '123456789', ''));
    await platformFFI.tryHandle(online(null, '123456789', ''));
    expect(peers.peers.single.online, isFalse);
    await platformFFI.tryHandle(online(b, '123456789', ''));
    expect(peers.peers.single.online, isTrue);
    await platformFFI.tryHandle(online(b, '', '123456789'));
    expect(peers.peers.single.online, isFalse);
  }, skip: !const bool.fromEnvironment('NIKODESK'));

  test('stock peer dispatch retains original unscoped online events', () async {
    final peers = Peers(
        name: 'online-stock-regression',
        getInitPeers: null,
        loadEvent: 'load_recent_peers');
    addTearDown(peers.dispose);
    peers.peers = [
      Peer.fromJson({'id': '123456789'})
    ];
    await platformFFI.tryHandle(online(null, '123456789', ''));
    expect(peers.peers.single.online, isTrue);
  }, skip: const bool.fromEnvironment('NIKODESK'));
}
