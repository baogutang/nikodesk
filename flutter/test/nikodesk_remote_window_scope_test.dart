import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/nikodesk/remote_window_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final a = 'a' * 64;
  final b = 'b' * 64;
  const peer = '1000000001';
  const otherPeer = '1000000002';
  Map<String, Object> identity(int window,
          {String? namespace, String id = peer}) =>
      NikoRemoteWindowIdentity(window, id, namespace ?? a).toJson();
  Map<String, dynamic> geometry(int window,
          {String? namespace, String id = peer}) =>
      {
        ...identity(window, namespace: namespace, id: id),
        'windowRect': {'l': 100.0, 't': 0.0, 'w': 600.0, 'h': 400.0},
        'remoteRect': {'l': 0.0, 't': 0.0, 'w': 1920.0, 'h': 1080.0},
        'canvas': {
          'x': 0.0,
          'y': 0.0,
          'scale': 1.0,
          'scrollX': 0.0,
          'scrollY': 0.0,
          'scrollStyle': 'scrollauto',
          'size': {'w': 600.0, 'h': 400.0},
        },
        'cursor': {'offset_x': 0.0, 'offset_y': 0.0},
      };

  test('only the same server and peer supply multi-display coordinates',
      () async {
    final reads = <int>[];
    final identities = {
      1: identity(1),
      2: identity(2, namespace: b),
      3: identity(3, id: otherPeer),
      4: identity(4),
      5: identity(5),
    };
    final result = await nikoCollectRemoteWindowCoordinates(
      request: identity(1),
      fromWindowId: 1,
      windows: [1, 2, 3, 4, 5],
      readIdentity: (id) async => identities[id],
      readCoordinates: (id, request) async {
        reads.add(id);
        expect(NikoRemoteWindowIdentity.parse(request)?.windowId, id);
        return jsonEncode(geometry(id));
      },
    );
    expect(reads, [4, 5]);
    expect(result.map((e) => jsonDecode(e)['windowId']), [4, 5]);
  });

  test('spoofed origin or absent identity performs no window RPC', () async {
    var reads = 0;
    for (final request in [
      identity(1),
      {},
      {'windowId': 2},
      'malformed'
    ]) {
      expect(
          await nikoCollectRemoteWindowCoordinates(
            request: request,
            fromWindowId: 2,
            windows: [3],
            readIdentity: (_) async {
              reads++;
              return identity(2);
            },
            readCoordinates: (_, __) async {
              reads++;
              return geometry(3);
            },
          ),
          isEmpty);
    }
    expect(reads, 0);
  });

  test('the real origin must currently select the requested peer and scope',
      () async {
    var coordinateReads = 0;
    for (final actual in [
      identity(1, namespace: b),
      identity(1, id: otherPeer),
      null
    ]) {
      expect(
          await nikoCollectRemoteWindowCoordinates(
            request: identity(1),
            fromWindowId: 1,
            windows: [2],
            readIdentity: (_) async => actual,
            readCoordinates: (_, __) async {
              coordinateReads++;
              return geometry(2);
            },
          ),
          isEmpty);
    }
    expect(coordinateReads, 0);
  });

  test(
      'origin switching tabs or closing during collection discards all replies',
      () async {
    for (final changed in [
      identity(1, id: otherPeer),
      identity(1, namespace: b),
      null
    ]) {
      var originReads = 0;
      expect(
          await nikoCollectRemoteWindowCoordinates(
            request: identity(1),
            fromWindowId: 1,
            windows: [2],
            readIdentity: (id) async {
              if (id != 1) return identity(id);
              return ++originReads == 1 ? identity(1) : changed;
            },
            readCoordinates: (id, _) async => geometry(id),
          ),
          isEmpty);
      expect(originReads, 2);
    }
  });

  test('a foreign or switched candidate cannot label its reply as the original',
      () async {
    for (final reply in [
      geometry(2, namespace: b),
      geometry(2, id: otherPeer),
      geometry(3),
      null
    ]) {
      expect(
          await nikoCollectRemoteWindowCoordinates(
            request: identity(1),
            fromWindowId: 1,
            windows: [2],
            readIdentity: (id) async => identity(id),
            readCoordinates: (_, __) async => reply,
          ),
          isEmpty);
    }
  });

  test(
      'closed and timed-out candidates are skipped without losing same-peer replies',
      () async {
    final result = await nikoCollectRemoteWindowCoordinates(
      request: identity(1),
      fromWindowId: 1,
      windows: [2, 3, 4, 5],
      timeout: const Duration(milliseconds: 5),
      readIdentity: (id) async {
        if (id == 2) throw StateError('Closed');
        return identity(id);
      },
      readCoordinates: (id, _) {
        if (id == 3) return Completer<Object?>().future;
        if (id == 4) throw StateError('Closed after the identity query');
        return Future.value(geometry(id));
      },
    );
    expect(result.map((e) => jsonDecode(e)['windowId']), [5]);
  });

  test(
      'coordinate reply checks the selected identity before and after reading geometry',
      () async {
    var reads = 0;
    expect(
        await nikoRemoteWindowCoordinateReply(
          request: identity(2),
          readIdentity: () => identity(2, namespace: b),
          readCoordinates: () async {
            reads++;
            return geometry(2);
          },
        ),
        isNull);
    expect(reads, 0);
    for (final changed in [
      identity(2, id: otherPeer),
      identity(2, namespace: b),
      null
    ]) {
      Object? selected = identity(2);
      expect(
          await nikoRemoteWindowCoordinateReply(
            request: identity(2),
            readIdentity: () => selected,
            readCoordinates: () async {
              selected = changed;
              return geometry(2);
            },
          ),
          isNull);
    }
    final result = await nikoRemoteWindowCoordinateReply(
      request: identity(2),
      readIdentity: () => identity(2),
      readCoordinates: () async => geometry(2, namespace: b),
    );
    expect(NikoRemoteWindowIdentity.parse(result)?.namespace, a);
  });

  test('the receiving window independently filters peer, scope, and own window',
      () {
    final replies = jsonEncode([
      jsonEncode(geometry(2)),
      geometry(3, namespace: b),
      geometry(4, id: otherPeer),
      geometry(1),
      'malformed',
    ]);
    expect(
        nikoMatchingRemoteCoordinateReplies(replies, peer, a, 1)
            .map((e) => e['windowId']),
        [2]);
    expect(
        nikoMatchingRemoteCoordinateReplies(replies, peer, null, 1), isEmpty);
    expect(
        nikoMatchingRemoteCoordinateReplies(replies, 'unknown', a, 1), isEmpty);
  });
}
