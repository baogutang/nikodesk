import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/link_handler.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gateway implements ServerGateway {
  ServerSnapshot snapshot = ServerSnapshot(
      PrivateServerConfig('test.invalid:21116', 'test.invalid:21117',
          base64Encode(List.filled(32, 1))),
      1,
      true);
  int reads = 0;
  @override
  Future<ServerSnapshot> read() async {
    reads++;
    return snapshot;
  }

  @override
  Future<void> save(PrivateServerConfig config) async {}
}

void main() {
  setUp(() => NikoLanguage.english = true);

  test('parses supported private IDs without alternate-server overrides', () {
    final request = NikoLinkRequest.parse(
        uriString:
            'nikodesk://file-transfer/123456?password=synthetic%20secret&relay');
    expect(request?.id, '123456');
    expect(request?.password, 'synthetic secret');
    expect(request?.mode, 'file-transfer');
    expect(request?.forceRelay, isTrue);
    for (final url in [
      'rustdesk://123456',
      'nikodesk://123456/r@other.invalid',
      'nikodesk://123456?key=override',
      'nikodesk://config/secret',
      'nikodesk://password/secret',
      'nikodesk://123456?password=a&password=b',
      'nikodesk://connect/not-an-id?password=synthetic-secret',
      'nikodesk://[broken?password=synthetic-secret',
    ]) {
      expect(NikoLinkRequest.parse(uriString: url), isNull);
    }
  });

  test('malformed command arguments never throw credential-bearing errors', () {
    expect(NikoLinkRequest.parse(args: ['--connect']), isNull);
    expect(NikoLinkRequest.parse(args: ['--connect', '123456', '--password']),
        isNull);
    expect(
        NikoLinkRequest.parse(
            args: ['--connect', '123456', '--switch_uuid', 'x']),
        isNull);
  });

  test('cold and hot links share one handler and detached homes receive none',
      () async {
    const cold = NikoLinkRequest('123456', 'connect', null, false);
    const hot = NikoLinkRequest('234567', 'connect', null, false);
    final owner = Object();
    final requests = <String>[];
    NikoLinkInbox.receive(cold);
    NikoLinkInbox.attach(owner, (request) async {
      requests.add(request.id);
    });
    await Future<void>.delayed(Duration.zero);
    NikoLinkInbox.receive(hot);
    await Future<void>.delayed(Duration.zero);
    expect(requests, ['123456', '234567']);
    NikoLinkInbox.detach(owner);
  });

  test('a second hot link cannot dispatch while credential handling is active',
      () async {
    final owner = Object();
    final done = Completer<void>();
    var calls = 0;
    NikoLinkInbox.attach(owner, (_) async {
      calls++;
      await done.future;
    });
    const request = NikoLinkRequest('123456', 'connect', null, false);
    NikoLinkInbox.receive(request);
    NikoLinkInbox.receive(request);
    expect(calls, 1);
    done.complete();
    await Future<void>.delayed(Duration.zero);
    NikoLinkInbox.detach(owner);
  });

  for (final supplied in [null, '']) {
    testWidgets(
        'missing/empty link password requires a prompt and cancel dispatches nothing ($supplied)',
        (tester) async {
      final gateway = _Gateway();
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => dispatchNikoLink(
                              context,
                              NikoLinkRequest(
                                  '123456', 'connect', supplied, false),
                              gateway: gateway, onConnect: (_, __, ___,
                                  {isFileTransfer = false, password}) async {
                            calls++;
                          }),
                      child: const Text('Link'))))));
      await tester.tap(find.text('Link'));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const Key('nikodesk-connect-password')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(gateway.reads, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('link submission rechecks pause after password entry',
      (tester) async {
    final gateway = _Gateway();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => dispatchNikoLink(
                            context,
                            const NikoLinkRequest(
                                '123456', 'file-transfer', null, true),
                            gateway: gateway, onConnect: (_, __, ___,
                                {isFileTransfer = false, password}) async {
                          calls++;
                        }),
                    child: const Text('Link'))))));
    await tester.tap(find.text('Link'));
    await tester.pumpAndSettle();
    gateway.snapshot = ServerSnapshot(gateway.snapshot.config, 1, false);
    await tester.enterText(
        find.byKey(const Key('nikodesk-connect-password')), 'synthetic-secret');
    await tester.tap(find.byKey(const Key('nikodesk-connect-submit')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(gateway.reads, 2);
    expect(find.textContaining('connections are paused'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
