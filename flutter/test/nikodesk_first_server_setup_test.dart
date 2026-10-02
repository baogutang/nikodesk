import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/first_server_setup.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

// Form/navigation fixtures, not native server or remote-session acceptance.
class _Gateway implements ServerGateway {
  ServerSnapshot snapshot;
  Object? readError;
  Object? saveError;
  Completer<void>? pendingSave;
  int saves = 0;

  _Gateway(this.snapshot);

  @override
  Future<ServerSnapshot> read() async {
    if (readError != null) throw readError!;
    return snapshot;
  }

  @override
  Future<void> save(PrivateServerConfig config) async {
    saves++;
    if (saveError != null) throw saveError!;
    if (pendingSave != null) await pendingSave!.future;
    snapshot = ServerSnapshot(config, null, true);
  }
}

void main() {
  final config = PrivateServerConfig('test.invalid:21116', 'test.invalid:21117',
      base64Encode(List.filled(32, 1)));
  const empty = ServerSnapshot(PrivateServerConfig('', '', ''), null, false);
  setUp(() => NikoLanguage.english = true);

  Future<void> load(WidgetTester tester, _Gateway gateway,
      {double scale = 1, VoidCallback? onSaved}) async {
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale)),
          child: child!),
      home: NikoFirstServerSetup(
        gateway: gateway,
        onSaved: onSaved ?? () {},
        onLanguageChanged: () async {},
        child: const Scaffold(body: Text('Existing workspace')),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> enterSettings(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).at(0), config.idServer);
    await tester.enterText(find.byType(TextFormField).at(1), config.relayServer);
    await tester.enterText(find.byType(TextFormField).at(2), config.publicKey);
    await tester.ensureVisible(find.text('Save and enable private server'));
  }

  testWidgets('valid paused configuration keeps the existing workspace',
      (tester) async {
    final gateway = _Gateway(ServerSnapshot(config, null, false));
    await load(tester, gateway);
    expect(find.text('Existing workspace'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(gateway.saves, 0);
  });

  testWidgets('read failure stays unknown and retry does not write settings',
      (tester) async {
    final gateway = _Gateway(empty)..readError = StateError('fixture');
    await load(tester, gateway);
    expect(find.text('Could not read server settings'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    gateway.readError = null;
    gateway.snapshot = ServerSnapshot(config, null, false);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Existing workspace'), findsOneWidget);
    expect(gateway.saves, 0);
  });

  testWidgets('deferred setup remains dismissed across home rebuilds',
      (tester) async {
    final gateway = _Gateway(empty);
    await load(tester, gateway);
    await tester.ensureVisible(find.text('Set up later'));
    await tester.tap(find.text('Set up later'));
    await tester.pumpAndSettle();
    await load(tester, gateway, scale: 2);
    expect(find.text('Existing workspace'), findsOneWidget);
    expect(gateway.saves, 0);
  });

  testWidgets('save failure retains input and completion waits for confirmation',
      (tester) async {
    final gateway = _Gateway(empty)
      ..saveError = const PrivateServerSaveException(stoppedVerified: true);
    var completed = 0;
    await load(tester, gateway, onSaved: () => completed++);
    await enterSettings(tester);
    await tester.tap(find.text('Save and enable private server'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connections are confirmed paused'), findsOneWidget);
    expect(completed, 0);
    expect(tester.widget<TextFormField>(find.byType(TextFormField).at(0))
        .controller!.text, config.idServer);
    gateway.saveError = null;
    gateway.pendingSave = Completer<void>();
    await tester.ensureVisible(find.text('Save and enable private server'));
    await tester.tap(find.text('Save and enable private server'));
    await tester.pump();
    expect(completed, 0);
    expect(find.text('Existing workspace'), findsNothing);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Set up later'))
        .onPressed, isNull);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(gateway.saves, 2);
    gateway.pendingSave!.complete();
    await tester.pumpAndSettle();
    expect(completed, 1);
    expect(find.text('Existing workspace'), findsOneWidget);
  });

  for (final size in [
    const Size(800, 600),
    const Size(320, 700),
    const Size(844, 390),
  ]) {
    testWidgets('setup remains usable at $size and 200% text', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _Gateway(empty);
      await load(tester, gateway, scale: 2);
      await enterSettings(tester);
      expect(find.text('Save and enable private server').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Save and enable private server'));
      await tester.pumpAndSettle();
      expect(find.text('Existing workspace'), findsOneWidget);
      expect(gateway.saves, 1);
    });
  }
}
