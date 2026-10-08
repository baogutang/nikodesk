import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/connect_dialog.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gateway implements ServerGateway {
  final String namespace;
  final bool enabled;
  _Gateway(this.namespace, {this.enabled = true});
  @override
  Future<ServerSnapshot> read() async => ServerSnapshot(
      PrivateServerConfig('fixture.invalid', 'fixture.invalid:21117',
          base64Encode(List.filled(32, 7))),
      1,
      enabled,
      namespace: namespace);
  @override
  Future<void> save(PrivateServerConfig config) async {}
}

void main() {
  final scope = 'a' * 64;
  setUp(() => NikoLanguage.english = true);
  for (final state in [
    'present',
    'missing',
    'unavailable',
    'other-server',
    'paused'
  ]) {
    testWidgets('saved dispatch rechecks scope and secure storage ($state)',
        (tester) async {
      var calls = 0;
      final reads = <String>[];
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => nikoDispatchConnection(context,
                              id: '123456',
                              password: '',
                              useSavedCredential: true,
                              expectedServerNamespace: scope,
                              gateway: _Gateway(
                                  state == 'other-server' ? 'b' * 64 : scope,
                                  enabled: state != 'paused'),
                              credentialStatusLoader: (namespace, id) async {
                            reads.add('$namespace/$id');
                            return state;
                          }, onConnect: (_, __, ___,
                                  {isFileTransfer = false, password}) async {
                            expect(password, isEmpty);
                            calls++;
                          }),
                      child: const Text('connect'))))));
      await tester.tap(find.text('connect'));
      await tester.pumpAndSettle();
      expect(calls, state == 'present' ? 1 : 0);
      expect(
          reads,
          ['other-server', 'paused'].contains(state)
              ? isEmpty
              : ['$scope/123456']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'disposed dispatch caller cannot connect after delayed secure lookup',
      (tester) async {
    var calls = 0;
    final status = Completer<String>();
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => nikoDispatchConnection(context,
                        id: '123456',
                        password: '',
                        useSavedCredential: true,
                        expectedServerNamespace: scope,
                        gateway: _Gateway(scope),
                        credentialStatusLoader: (_, __) => status.future,
                        onConnect: (_, __, ___,
                            {isFileTransfer = false, password}) async {
                          calls++;
                        }),
                    child: const Text('connect'))))));
    await tester.tap(find.text('connect'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    status.complete('present');
    await tester.pump();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });
}
