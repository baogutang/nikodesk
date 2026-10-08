import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/device_page.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/server_scope.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression for the first real-device launches: the device page freezes
/// its store (and the store's namespace) on first access, which happens
/// before the first gateway read activates the private-server scope. Quick
/// connect must resolve the live scope at dispatch time instead of that
/// frozen empty value, or every session creation fails locally.
class _LateScopeGateway implements ServerGateway {
  @override
  Future<ServerSnapshot> read() async {
    // The native gateway activates the scope only when its read completes,
    // strictly after the page state has already frozen its store.
    NikoServerScope.activate('b' * 64);
    return ServerSnapshot(
        PrivateServerConfig('fixture.invalid', 'fixture.invalid:21117',
            base64Encode(List.filled(32, 9))),
        1,
        true,
        namespace: 'b' * 64);
  }

  @override
  Future<void> save(PrivateServerConfig config) async {}
}

/// Plays the role of the page's frozen `DeviceStore.instance`: constructed
/// before the scope activated, so its namespace stays empty forever.
class _FrozenEmptyStore implements DeviceStore {
  @override
  final Directory directory = Directory('/synthetic-frozen-store');
  @override
  final String? serverNamespace = null;
  @override
  Future<DeviceDirectory> load() async => const DeviceDirectory([]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('quick connect resolves the live scope, not the frozen store',
      (tester) async {
    NikoLanguage.english = true;
    addTearDown(() => NikoServerScope.activate(null));
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final statusScopes = <String>[];
    var connects = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoDevicePage(
                store: _FrozenEmptyStore(),
                gateway: _LateScopeGateway(),
                native: false,
                credentialStatusLoader: (scope, id) async {
                  statusScopes.add(scope);
                  return 'missing';
                },
                onConnect: (_, __, ___,
                    {isFileTransfer = false, password}) async {
                  connects++;
                }))));
    // First build + refresh: the store stays frozen while the gateway read
    // activates the real scope.
    await tester.pumpAndSettle();
    expect(NikoServerScope.current, 'b' * 64);

    // Empty password: with the live namespace resolved, the credential
    // dialog must open (and observe the live scope) instead of silently
    // dispatching with no namespace.
    await tester.enterText(find.byKey(const Key('nikodesk-hero-id')), '123456789');
    final button = find.byKey(const Key('nikodesk-hero-connect'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('nikodesk-connect-password')), findsOneWidget,
        reason: 'the credential dialog opens only when a namespace resolved');
    expect(statusScopes, contains('b' * 64),
        reason: 'the dialog observes the live private-server scope');
    expect(connects, 0,
        reason: 'nothing is dispatched while the dialog is pending');
  });
}
