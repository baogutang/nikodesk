import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/nikodesk/cm_permissions.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

Client _client() => Client(12, true, false, false, 'Test device', '123456789',
    true, true, true)..file = true..restart = true..recording = true
    ..blockInput = true..privacyMode = true;

Widget _host(Widget child, {Brightness brightness = Brightness.light, double scale = 1}) =>
    MaterialApp(theme: nikoTheme(brightness), home: Builder(builder: (context) =>
      MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(body: child))));

void main() {
  tearDown(() => NikoLanguage.english = false);

  test('native snapshot respects feature flag and preserves chat and authorization', () {
    const nikoEnabled = bool.fromEnvironment('NIKODESK');
    final shown = _client();
    shown.unreadChatMessageCount.value = 3;
    final confirmed = Client.fromJson(shown.toJson()
      ..addAll({'keyboard': false, 'clipboard': false, 'audio': false, 'file': false,
        'restart': false, 'recording': false, 'block_input': false, 'privacy_mode': false}));
    expect(shown.applyNikoPermissions(confirmed), nikoEnabled);
    for (final name in ['keyboard', 'clipboard', 'audio', 'file', 'restart',
        'recording', 'block_input', 'privacy_mode']) {
      expect(shown.toJson()[name], !nikoEnabled, reason: name);
    }
    expect(shown.authorized, isTrue);
    expect(shown.disconnected, isFalse);
    expect(shown.unreadChatMessageCount.value, 3);
  });

  test('different connection, peer, kind and retired snapshots cannot rewrite permissions', () {
    for (final mutate in <void Function(Client)>[
      (client) => client.id = 13,
      (client) => client.peerId = '987654321',
      (client) => client.isFileTransfer = true,
      (client) => client.disconnected = true,
      (client) => client.nikoCameraCleanup = true,
      (client) => client.nikoVoiceCleanup = true,
      (client) => client.nikoTunnelCleanup = true,
    ]) {
      final shown = _client();
      final confirmed = _client()..keyboard = false;
      mutate(confirmed);
      expect(shown.applyNikoPermissions(confirmed), isFalse);
      expect(shown.keyboard, isTrue);
    }
    final retired = _client()..disconnected = true;
    expect(retired.applyNikoPermissions(_client()), isFalse);
  });

  testWidgets('request does not optimistically change confirmed checkbox and supports keyboard', (tester) async {
    final semantics = tester.ensureSemantics();
    final changes = <String>[];
    Widget board(bool enabled, {bool canModify = true}) => NikoCmPermissions(
      permissions: [NikoCmPermission('keyboard', 'Keyboard and mouse', Icons.keyboard, enabled)],
      canModify: canModify, onChange: (name, value) => changes.add('$name:$value'));
    await tester.pumpWidget(_host(board(true)));
    final checkbox = find.byType(CheckboxListTile);
    expect(tester.getSemantics(find.bySemanticsLabel('Keyboard and mouse'))
        .getSemanticsData().hasFlag(SemanticsFlag.isChecked), isTrue);
    await tester.tap(checkbox);
    expect(changes, ['keyboard:false']);
    expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
    await tester.pumpWidget(_host(board(false)));
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(changes.last, 'keyboard:true');
    await tester.pumpWidget(_host(board(false, canModify: false)));
    expect(tester.widget<CheckboxListTile>(checkbox).onChanged, isNull);
    await tester.tap(checkbox);
    expect(changes, hasLength(2));
    expect(tester.getSemantics(find.bySemanticsLabel('Keyboard and mouse'))
        .getSemanticsData().hasFlag(SemanticsFlag.isEnabled), isFalse);
    semantics.dispose();
  });

  for (final english in [false, true]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('request and all permissions remain usable at 280x480/200% $english $brightness', (tester) async {
        NikoLanguage.english = english;
        await tester.binding.setSurfaceSize(const Size(280, 480));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var accepted = 0;
        await tester.pumpWidget(_host(NikoCmSessionLayout(
          header: const NikoCmRequestHeader(
            requester: 'A remote computer with a long descriptive name',
            peerId: '123456789123456789123456789', action: 'Screen and input control',
            status: 'Waiting for local approval'),
          permissions: NikoCmPermissions(canModify: true, onChange: (_, __) {},
            permissions: [for (final name in ['Keyboard and mouse', 'Text clipboard',
              'Device audio', 'File copy and paste', 'Remote restart', 'Session recording',
              'Block local input', 'Privacy screen'])
                NikoCmPermission(name, name, Icons.keyboard, true)]),
          controls: NikoCmActionButton(label: english ? 'Allow this session' : '允许此会话',
            onPressed: () => accepted++)), brightness: brightness, scale: 2));
        expect(tester.takeException(), isNull);
        expect(find.byType(FittedBox), findsNothing);
        final action = find.byType(FilledButton);
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
        await tester.tap(action);
        expect(accepted, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('session action is keyboard operable with readable theme colors $brightness', (tester) async {
      var accepted = 0;
      await tester.pumpWidget(_host(Column(children: [
        NikoCmActionButton(label: 'Allow', onPressed: () => accepted++),
        NikoCmActionButton(label: 'End session', danger: true, onPressed: () {}),
        NikoCmActionButton(label: 'Deny', outlined: true, onPressed: () {}),
      ]), brightness: brightness));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(accepted, 1);
      for (final button in tester.widgetList<FilledButton>(find.byType(FilledButton))) {
        final background = button.style!.backgroundColor!.resolve({})!;
        final foreground = button.style!.foregroundColor!.resolve({})!;
        final a = background.computeLuminance();
        final b = foreground.computeLuminance();
        final contrast = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
    });
  }
}
