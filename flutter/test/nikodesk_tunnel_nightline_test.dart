import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/tunnel_cleanup.dart';
import 'package:flutter_hbb/nikodesk/tunnel_cleanup_view.dart';
import 'package:flutter_hbb/nikodesk/tunnel_controller.dart';
import 'package:flutter_hbb/nikodesk/tunnel_controller_view.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_tunnel_cleanup_test.dart' as cleanup;
import 'nikodesk_tunnel_controller_test.dart' as fixtures;

// The TCP tunnel window and page, and the reminder of earlier tunnels, under
// the Nightline theme. The stock layouts keep their own tests.

Widget _app(Widget body,
        {Brightness brightness = Brightness.light, double textScale = 1}) =>
    MaterialApp(
        theme:
            nightlineTheme(brightness).copyWith(platform: TargetPlatform.iOS),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!),
        home: Scaffold(body: body));

Future<void> _form(WidgetTester tester,
    {String local = '8000', String host = 'target.invalid'}) async {
  await tester.enterText(
      find.byKey(const Key('niko-tunnel-local-port')), local);
  await tester.enterText(
      find.byKey(const Key('niko-tunnel-target-host')), host);
  await tester.enterText(
      find.byKey(const Key('niko-tunnel-remote-port')), '443');
  await tester.pump();
}

void main() {
  setUp(() => NikoLanguage.english = true);
  tearDown(() => NikoLanguage.english = false);

  testWidgets('the form previews the route; a request shows its state',
      (tester) async {
    tester.view.physicalSize = const Size(1180, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final m = fixtures.model();
    addTearDown(m.dispose);
    final sent = <NikoTunnelCommand>[];
    await tester.pumpWidget(_app(NikoTunnelControllerView(
        controller: m,
        sendCommand: (command) async {
          sent.add(command);
          return '{"ok":true,"reason":"queued"}';
        })));
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.text('No tunnel yet'), findsOneWidget);
    await _form(tester);
    expect(
        find.text('127.0.0.1:8000  →  via the remote  →  target.invalid:443'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('niko-tunnel-add')));
    await tester.pump();
    expect(sent.single.target!.host, 'target.invalid');
    expect(find.text('Queued'), findsOneWidget);
    expect(find.text('Request queued; waiting for actual status.'),
        findsOneWidget);
    m.handleEvent(fixtures.event(fixtures.status(phase: 'Listening')));
    await tester.pump();
    expect(find.text('Listening'), findsOneWidget);
    expect(find.text('The local loopback port is listening.'), findsOneWidget);
    expect(find.text('No tunnel yet'), findsNothing);
    final semantics = tester.ensureSemantics();
    expect(
        tester
            .getSemantics(find.byKey(const Key('niko-tunnel-stop-8000')))
            .label,
        contains('Stop this port'));
    semantics.dispose();
    await tester.tap(find.byKey(const Key('niko-tunnel-stop-8000')));
    await tester.pump();
    expect(jsonDecode(sent.last.json)['op'], 'remove');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ports take digits only; a bad port is explained in place',
      (tester) async {
    final m = fixtures.model();
    addTearDown(m.dispose);
    var sends = 0;
    await tester.pumpWidget(_app(NikoTunnelControllerView(
        controller: m,
        sendCommand: (_) async {
          sends++;
          return '{"ok":true,"reason":"queued"}';
        })));
    await tester.enterText(
        find.byKey(const Key('niko-tunnel-local-port')), '80a0');
    expect(
        tester
            .widget<EditableText>(find.descendant(
                of: find.byKey(const Key('niko-tunnel-local-port')),
                matching: find.byType(EditableText)))
            .controller
            .text,
        '800');
    await _form(tester, local: '0');
    await tester.tap(find.byKey(const Key('niko-tunnel-add')));
    await tester.pump();
    expect(sends, 0);
    expect(find.text('Enter a valid target host and ports from 1 to 65535.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Tab from the last field reaches Request; Enter sends once',
      (tester) async {
    final m = fixtures.model();
    addTearDown(m.dispose);
    var sends = 0;
    await tester.pumpWidget(_app(NikoTunnelControllerView(
        controller: m,
        sendCommand: (_) async {
          sends++;
          return '{"ok":true,"reason":"queued"}';
        })));
    await _form(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sends, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a closed page says so and stops taking requests',
      (tester) async {
    final m = fixtures.model();
    addTearDown(m.dispose);
    m.invalidate();
    await tester.pumpWidget(_app(
        NikoTunnelControllerView(controller: m, sendCommand: (_) async => '')));
    expect(
        find.text('This page no longer submits new requests. Confirm exit '
            'of the original session before reconnecting.'),
        findsOneWidget);
    expect(
        tester
            .widget<NlButton>(find.byKey(const Key('niko-tunnel-add')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<NlButton>(
                find.byKey(const Key('niko-tunnel-request-wake-proxy')))
            .onPressed,
        isNull);
  });

  for (final english in [false, true]) {
    for (final brightness in Brightness.values) {
      testWidgets(
          'a 320 px phone at 200% text keeps every control reachable '
          '(${english ? 'en' : 'zh'} ${brightness.name})', (tester) async {
        NikoLanguage.english = english;
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final m = fixtures.model();
        addTearDown(m.dispose);
        await tester.pumpWidget(_app(
            NikoTunnelControllerView(
                controller: m,
                mobile: true,
                sendCommand: (_) async => '{"ok":true,"reason":"queued"}'),
            brightness: brightness,
            textScale: 2));
        expect(tester.takeException(), isNull);
        await _form(tester);
        final add = find.byKey(const Key('niko-tunnel-add'));
        await tester.ensureVisible(add);
        await tester.pump();
        expect(tester.getSize(add).height, greaterThanOrEqualTo(48));
        await tester.tap(add);
        await tester.pump();
        m.handleEvent(
            fixtures.event(fixtures.status(phase: 'WaitingApproval')));
        await tester.pump();
        final stop = find.byKey(const Key('niko-tunnel-stop-8000'));
        await tester.ensureVisible(stop);
        await tester.pump();
        expect(tester.getSize(stop).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('the earlier-tunnel reminder opens its panel in a dialog',
      (tester) async {
    NikoTunnelOwnerIdentity? queried;
    final model = NikoTunnelCleanupModel(
        readRetired: () async => cleanup.roster(),
        query: (owner) async {
          queried = owner;
          return '{"ok":false,"reason":"busy","owners":[]}';
        });
    addTearDown(model.dispose);
    await tester.pumpWidget(_app(NikoTunnelCleanupEntryPoint(
        model: model, interval: const Duration(hours: 1))));
    await tester.pump();
    await tester.pump();
    expect(find.text('Previous tunnel resources still need exit confirmation'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('niko-tunnel-cleanup-open')));
    await tester.pumpAndSettle();
    expect(find.text('Cleanup for previous tunnels'), findsOneWidget);
    expect(
        find.byKey(const Key('niko-tunnel-cleanup-refresh')), findsOneWidget);
    await tester
        .tap(find.byKey(Key('niko-tunnel-cleanup-${cleanup.owner.key}')));
    await tester.pump();
    expect(queried!.same(cleanup.owner), isTrue);
    await tester.tap(find.text('Close panel'));
    await tester.pumpAndSettle();
    expect(find.text('Cleanup for previous tunnels'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
