import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/tunnel_controller.dart';
import 'package:flutter_hbb/nikodesk/tunnel_controller_view.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_tunnel_controller_test.dart' as fixtures;

Future<void> form(WidgetTester tester) async {
  await tester.enterText(
      find.byKey(const Key('niko-tunnel-local-port')), '8000');
  await tester.enterText(
      find.byKey(const Key('niko-tunnel-target-host')), 'target.invalid');
  await tester.enterText(
      find.byKey(const Key('niko-tunnel-remote-port')), '443');
}

void main() {
  testWidgets(
      'wake preset requests the exact loopback proxy and waits for original approval',
      (tester) async {
    NikoLanguage.english = true;
    final m = fixtures.model();
    addTearDown(m.dispose);
    final sent = <NikoTunnelCommand>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoTunnelControllerView(
                controller: m,
                mobile: true,
                sendCommand: (command) async {
                  sent.add(command);
                  return '{"ok":true,"reason":"queued"}';
                }))));
    await tester.tap(find.byKey(const Key('niko-tunnel-request-wake-proxy')));
    await tester.pumpAndSettle();
    expect(sent.single.localPort, 21129);
    expect(sent.single.target!.host, '127.0.0.1');
    expect(sent.single.target!.port, 21128);
    expect(m.statuses, isEmpty);
    expect(find.byKey(const Key('niko-tunnel-wake-21129')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final english in [false, true]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
          '320px 200% ${english ? "English" : "Chinese"} $brightness form/status/touch',
          (tester) async {
        NikoLanguage.english = english;
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final m = fixtures.model();
        addTearDown(m.dispose);
        final sent = <NikoTunnelCommand>[];
        await tester.pumpWidget(MaterialApp(
            theme: nikoTheme(brightness),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(2)),
                child: child!),
            home: Scaffold(
                body: NikoTunnelControllerView(
                    controller: m,
                    mobile: true,
                    sendCommand: (c) async {
                      sent.add(c);
                      return '{"ok":true,"reason":"queued"}';
                    }))));
        expect(tester.takeException(), isNull);
        await form(tester);
        final add = find.byKey(const Key('niko-tunnel-add'));
        await tester.ensureVisible(add);
        await tester.pump();
        expect(tester.getSize(add).height, greaterThanOrEqualTo(48));
        await tester.tap(add);
        await tester.pump();
        expect(sent.single.target!.host, 'target.invalid');
        expect(m.statuses, isEmpty);
        expect(
            find.text(english
                ? 'Request queued; waiting for actual status.'
                : '请求已排队，等待实际状态确认。'),
            findsOneWidget);
        m.handleEvent(
            fixtures.event(fixtures.status(phase: 'WaitingApproval')));
        await tester.pump();
        final stop = find.byKey(const Key('niko-tunnel-stop-8000'));
        await tester.ensureVisible(stop);
        await tester.pump();
        expect(tester.getSize(stop).height, greaterThanOrEqualTo(48));
        await tester.tap(stop);
        await tester.pump();
        expect(jsonDecode(sent.last.json)['op'], 'remove');
        expect(sent.last.target, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  testWidgets(
      'keyboard activation requests once; semantic stop label remains available',
      (tester) async {
    NikoLanguage.english = true;
    final m = fixtures.model();
    addTearDown(m.dispose);
    var sends = 0;
    await tester.pumpWidget(MaterialApp(
        theme: nikoTheme(Brightness.light),
        home: Scaffold(
            body: NikoTunnelControllerView(
                controller: m,
                sendCommand: (_) async {
                  sends++;
                  return '{"ok":true,"reason":"queued"}';
                }))));
    await form(tester);
    // The remote-port field is focused by enterText; Tab reaches Request.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sends, 1);
    final semantics = tester.ensureSemantics();
    expect(
        tester
            .getSemantics(find.byKey(const Key('niko-tunnel-stop-8000')))
            .label,
        contains('Stop this port'));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'unknown reply does not show listening or allow replacing original target',
      (tester) async {
    NikoLanguage.english = true;
    final m = fixtures.model(timeout: const Duration(milliseconds: 1));
    addTearDown(m.dispose);
    final reply = Completer<String>();
    var sends = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoTunnelControllerView(
                controller: m,
                sendCommand: (_) {
                  sends++;
                  return reply.future;
                }))));
    await form(tester);
    await tester.tap(find.byKey(const Key('niko-tunnel-add')));
    await tester.pump(const Duration(milliseconds: 5));
    expect(find.text('The local loopback port is listening.'), findsNothing);
    await tester.enterText(
        find.byKey(const Key('niko-tunnel-target-host')), 'other.invalid');
    await tester.tap(find.byKey(const Key('niko-tunnel-add')));
    await tester.pump();
    expect(sends, 1);
    expect(m.requests[8000]!.command.target!.host, 'target.invalid');
    m.invalidate();
    reply.complete('{"ok":true,"reason":"queued"}');
    await tester.pump();
    expect(
        tester
            .widget<ElevatedButton>(find.byKey(const Key('niko-tunnel-add')))
            .onPressed,
        isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
