import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/first_server_setup.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
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
      {double scale = 1, VoidCallback? onSaved, ThemeData? theme}) async {
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Material(
        // The desktop shell hosts the Nightline page on transparent material.
        type: MaterialType.transparency,
        child: NikoFirstServerSetup(
          gateway: gateway,
          onSaved: onSaved ?? () {},
          onLanguageChanged: () async {},
          child: const Scaffold(body: Text('Existing workspace')),
        ),
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

  group('Nightline', () {
    final theme = nightlineTheme(Brightness.light);
    Finder field(String name) => find.byKey(ValueKey('niko-server-$name'));
    String text(WidgetTester tester, String name) =>
        tester.widget<TextField>(field(name)).controller!.text;
    Future<void> save(WidgetTester tester) async {
      final button = find.text('Save and enable private server');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testWidgets('saving checks every field and writes nothing until valid',
        (tester) async {
      final gateway = _Gateway(empty);
      var completed = 0;
      await load(tester, gateway,
          theme: theme, onSaved: () => completed++);
      expect(find.byType(NlTextField), findsNWidgets(3));
      expect(find.byType(TextFormField), findsNothing);
      await tester.enterText(field('id'), 'https://nas');
      await save(tester);
      expect(find.text('Enter a host/IP with an optional port, without a URL '
          'or public service.'), findsOneWidget);
      expect(find.text('Use a valid host/IP and a port between 1 and 65535.'),
          findsOneWidget);
      expect(find.text('Use the 32-byte public key in standard Base64 '
          '(44 characters).'), findsOneWidget);
      expect(gateway.saves, 0);
      // Editing a field clears only its own check.
      await tester.enterText(field('id'), ' ${config.idServer} ');
      await tester.pump();
      expect(find.textContaining('without a URL'), findsNothing);
      expect(find.textContaining('between 1 and 65535'), findsOneWidget);
      await tester.enterText(field('relay'), config.relayServer);
      await tester.enterText(field('key'), config.publicKey);
      await save(tester);
      expect(gateway.saves, 1);
      expect(gateway.snapshot.config.idServer, config.idServer);
      expect(completed, 1);
      expect(find.text('Existing workspace'), findsOneWidget);
    });

    testWidgets('fields keep their length limits without a counter',
        (tester) async {
      await load(tester, _Gateway(empty), theme: theme);
      await tester.enterText(field('key'), 'A' * 60);
      expect(text(tester, 'key').length, 44);
      await tester.enterText(field('id'), 'a' * 300);
      expect(text(tester, 'id').length, 260);
      expect(find.textContaining('/260'), findsNothing);
      final inner = tester.widget<TextField>(field('key'));
      expect(inner.autocorrect, isFalse);
      expect(inner.enableIMEPersonalizedLearning, isFalse);
      expect(inner.smartDashesType, SmartDashesType.disabled);
    });

    testWidgets('a failed save keeps the input and says what is known',
        (tester) async {
      final gateway = _Gateway(empty)
        ..saveError = const PrivateServerSaveException(stoppedVerified: false);
      await load(tester, gateway, theme: theme);
      await tester.enterText(field('id'), config.idServer);
      await tester.enterText(field('relay'), config.relayServer);
      await tester.enterText(field('key'), config.publicKey);
      await save(tester);
      expect(find.textContaining('the stopped state is unknown'),
          findsOneWidget);
      expect(text(tester, 'id'), config.idServer);
      expect(find.text('Existing workspace'), findsNothing);
    });

    testWidgets('a read failure retries without writing', (tester) async {
      final gateway = _Gateway(empty)..readError = StateError('fixture');
      await load(tester, gateway, theme: theme);
      expect(find.text('Could not read server settings'), findsOneWidget);
      expect(find.byType(NlTextField), findsNothing);
      gateway.readError = null;
      gateway.snapshot = ServerSnapshot(config, null, false);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Existing workspace'), findsOneWidget);
      expect(gateway.saves, 0);
    });

    testWidgets('setup fits 320 px at 200% text', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await load(tester, _Gateway(empty), theme: theme, scale: 2);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Set up later'));
      await tester.tap(find.text('Set up later'));
      await tester.pumpAndSettle();
      expect(find.text('Existing workspace'), findsOneWidget);
    });
  });
}
