import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/device_page.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/session_log.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

// Explicit directory/history/gateway/dispatch doubles; no native or file I/O.
class _Gateway implements ServerGateway {
  ServerSnapshot snapshot;
  int reads = 0;
  _Gateway(this.snapshot);
  @override
  Future<ServerSnapshot> read() async {
    reads++;
    return snapshot;
  }

  @override
  Future<void> save(PrivateServerConfig config) async {}
}

class _Store implements DeviceStore {
  @override
  final Directory directory;
  @override
  final String? serverNamespace;
  _Store(this.directory, this.serverNamespace);
  @override
  Future<DeviceDirectory> load() async => const DeviceDirectory([]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Log implements SessionLogStore {
  int records = 0;
  @override
  Future<void> record(SessionLogEntry entry) async {
    records++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
      'device quick-connect tunnel uses password and final server read, without false control history',
      (tester) async {
    NikoLanguage.english = true;
    final directory = Directory('/synthetic/niko-tunnel-device-test');
    final gateway = _Gateway(ServerSnapshot(
        PrivateServerConfig('fixture.invalid', 'fixture.invalid:21117',
            base64Encode(List.filled(32, 7))),
        1,
        true));
    final store = _Store(directory, gateway.snapshot.namespace);
    final log = _Log();
    var calls = 0;
    String? captured;
    await tester.binding.setSurfaceSize(const Size(390, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: NikoDevicePage(
                  store: store,
                  gateway: gateway,
                  sessionLog: log,
                  native: false,
                  controllerOnly: true,
                  onTunnelConnect: (context, id, relay,
                      {isFileTransfer = false, password}) async {
                    calls++;
                    captured = password;
                  }))));
      for (var i = 0; i < 100; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      }
    });
    await tester.pumpAndSettle();
    final mode = find.byKey(const Key('nikodesk-connect-mode-2'));
    await tester.ensureVisible(mode);
    await tester.pump();
    await tester.tap(mode);
    await tester.pump();
    expect(tester.widget<ChoiceChip>(mode).selected, true);
    await tester.enterText(
        find.byKey(const Key('nikodesk-hero-id')), '123456789');
    await tester.enterText(find.byKey(const Key('nikodesk-hero-password')), '');
    final button = find.byKey(const Key('nikodesk-hero-connect'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();
    expect(calls, 0);
    // Let the empty-password notice leave the tap area before trying again.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('nikodesk-hero-password')), 'synthetic-secret');
    final reads = gateway.reads;
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('nikodesk-hero-id')))
            .controller!
            .text,
        '123456789');
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('nikodesk-hero-password')))
            .controller!
            .text,
        'synthetic-secret');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(captured, 'synthetic-secret');
    expect(gateway.reads, greaterThan(reads));
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('nikodesk-hero-password')))
            .controller!
            .text,
        isEmpty);
    expect(log.records, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
