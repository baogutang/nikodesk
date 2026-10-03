import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/server_settings.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

// Only exercises form state. It never reads or writes local native settings.
class _NetworkGateway implements ServerGateway {
  ServerSnapshot snapshot;
  Object? error;
  Completer<ServerSnapshot>? pending;
  int reads = 0, saves = 0;
  _NetworkGateway(this.snapshot);

  @override
  Future<ServerSnapshot> read() async {
    reads++;
    if (error != null) throw error!;
    if (pending != null) return pending!.future;
    return snapshot;
  }

  @override
  Future<void> save(PrivateServerConfig config) async {
    saves++;
    snapshot = ServerSnapshot(config, null, true);
  }
}

void main() {
  final config = PrivateServerConfig('server.test.invalid:21116',
      'relay.test.invalid:21117', base64Encode(List.filled(32, 7)));
  setUp(() => NikoLanguage.english = true);

  Future<void> load(WidgetTester tester, _NetworkGateway gateway,
      {double scale = 1}) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: NikoNetworkSettings(gateway: gateway)))));
    await tester.pump();
  }

  testWidgets('failed settings can be retried in place without blank writes',
      (tester) async {
    final gateway = _NetworkGateway(ServerSnapshot(config, null, false))
      ..error = StateError('synthetic read failure');
    await load(tester, gateway);
    await tester.pumpAndSettle();
    expect(find.text('Cannot read settings'), findsOneWidget);
    expect(find.text('Configure server'), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    expect(gateway.saves, 0);

    gateway.error = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Configuration complete'), findsOneWidget);
    expect(
        find.textContaining('Registration status is unknown'), findsOneWidget);
    await tester.tap(find.text('Configure server'));
    await tester.pumpAndSettle();
    final fields = tester.widgetList<TextFormField>(find.byType(TextFormField));
    expect(fields.map((field) => field.controller!.text),
        [config.idServer, config.relayServer, config.publicKey]);
    expect(gateway.reads, 2);
    expect(gateway.saves, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(gateway.reads, 2);
  });

  testWidgets('parent rebuilds do not restart the native settings read',
      (tester) async {
    final gateway = _NetworkGateway(ServerSnapshot(config, 1, true));
    await load(tester, gateway);
    await tester.pumpAndSettle();
    await load(tester, gateway, scale: 2);
    await tester.pumpAndSettle();
    expect(find.text('Configuration complete'), findsOneWidget);
    expect(gateway.reads, 1);
    expect(gateway.saves, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending retry hides the old failure and prevents extra reads',
      (tester) async {
    final gateway = _NetworkGateway(ServerSnapshot(config, null, false))
      ..error = StateError('synthetic read failure');
    await load(tester, gateway);
    await tester.pumpAndSettle();
    gateway.error = null;
    gateway.pending = Completer<ServerSnapshot>();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Configure server'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    await load(tester, gateway, scale: 2);
    expect(gateway.reads, 2);
    gateway.pending!.complete(gateway.snapshot);
    await tester.pumpAndSettle();
    expect(find.text('Configuration complete'), findsOneWidget);
    expect(gateway.saves, 0);
  });

  testWidgets('a pending settings read times out to a recoverable error',
      (tester) async {
    final gateway = _NetworkGateway(ServerSnapshot(config, null, false))
      ..pending = Completer<ServerSnapshot>();
    await load(tester, gateway);
    await tester.pump(const Duration(seconds: 8));
    await tester.pump();
    expect(find.text('Cannot read settings'), findsOneWidget);
    expect(find.text('Configure server'), findsNothing);
    gateway.pending!.complete(gateway.snapshot);
    await tester.pump();
    expect(find.text('Cannot read settings'), findsOneWidget);
    gateway.pending = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Configuration complete'), findsOneWidget);
    expect(gateway.saves, 0);
    expect(gateway.reads, 2);
  });

  testWidgets('confirmed saves refresh settings and retain the saved fields',
      (tester) async {
    final gateway = _NetworkGateway(ServerSnapshot(config, null, false));
    await load(tester, gateway);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Configure server'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextFormField).at(0), 'changed.test.invalid:21116');
    await tester.ensureVisible(find.text('Save and enable private server'));
    await tester.tap(find.text('Save and enable private server'));
    await tester.pumpAndSettle();
    expect(gateway.saves, 1);
    expect(gateway.reads, 2);
    await tester.tap(find.text('Configure server'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        'changed.test.invalid:21116');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(gateway.reads, 2);
  });

  for (final english in [false, true]) {
    for (final dark in [false, true]) {
      for (final failed in [false, true]) {
        testWidgets(
            'network state is accessible at 320px/200% '
            '(English=$english, dark=$dark, failed=$failed)', (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          NikoLanguage.english = english;
          final gateway = _NetworkGateway(ServerSnapshot(config, null, false));
          if (failed) gateway.error = StateError('synthetic read failure');
          await tester.pumpWidget(MaterialApp(
              theme: nikoTheme(dark ? Brightness.dark : Brightness.light),
              home: Scaffold(
                  body: MediaQuery(
                      data: const MediaQueryData(
                          textScaler: TextScaler.linear(2)),
                      child: NikoNetworkSettings(gateway: gateway)))));
          await tester.pumpAndSettle();
          final action = find.text(failed
              ? (english ? 'Retry' : '重试')
              : (english ? 'Configure server' : '配置服务器'));
          await tester.ensureVisible(action);
          expect(action.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(gateway.saves, 0);
        });
      }
    }
  }
}
