import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/device_page.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gateway implements ServerGateway {
  @override
  Future<ServerSnapshot> read() async => ServerSnapshot(
      PrivateServerConfig('fixture.invalid', 'fixture.invalid:21117',
          base64Encode(List.filled(32, 7))),
      1,
      true,
      namespace: 'a' * 64);
  @override
  Future<void> save(PrivateServerConfig config) async {}
}

class _Store implements DeviceStore {
  @override
  final Directory directory = Directory('/synthetic-quick-credential');
  @override
  final String serverNamespace = 'a' * 64;
  @override
  Future<DeviceDirectory> load() async => const DeviceDirectory([]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final saved in [false, true]) {
    testWidgets(
        'quick connect supports explicit remember and automatic saved choice ($saved)',
        (tester) async {
      NikoLanguage.english = true;
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var calls = 0;
      final reads = <String>[];
      String? received;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: NikoDevicePage(
                  store: _Store(),
                  gateway: _Gateway(),
                  native: false,
                  credentialStatusLoader: (scope, id) async {
                    reads.add('$scope/$id');
                    return saved ? 'present' : 'missing';
                  },
                  onConnect: (_, __, ___,
                      {isFileTransfer = false, password}) async {
                    received = password;
                    calls++;
                  }))));
      await tester.pumpAndSettle();
      final remember = find.byKey(const Key('nikodesk-hero-remember'));
      expect(tester.widget<Checkbox>(remember).value, false);
      await tester.enterText(
          find.byKey(const Key('nikodesk-hero-id')), '123456789');
      if (!saved) {
        await tester.enterText(find.byKey(const Key('nikodesk-hero-password')),
            'synthetic-password');
        await tester.tap(remember);
        await tester.pump();
        expect(tester.widget<Checkbox>(remember).value, true);
      }
      final button = find.byKey(const Key('nikodesk-hero-connect'));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(received, saved ? '' : 'synthetic-password');
      expect(reads, saved ? List.filled(2, '${'a' * 64}/123456789') : isEmpty);
      expect(find.byKey(const Key('nikodesk-connect-password')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('remember choice remains usable at 320px and 200 percent text',
      (tester) async {
    NikoLanguage.english = true;
    await tester.binding.setSurfaceSize(const Size(320, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: Scaffold(
            body: NikoDevicePage(
                store: _Store(),
                gateway: _Gateway(),
                native: false,
                credentialStatusLoader: (_, __) async => 'missing'))));
    await tester.pumpAndSettle();
    final choice = find.byKey(const Key('nikodesk-hero-remember'));
    await tester.ensureVisible(choice);
    await tester.pumpAndSettle();
    await tester.tap(choice);
    await tester.pump();
    expect(tester.widget<Checkbox>(choice).value, true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
