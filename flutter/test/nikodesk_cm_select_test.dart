import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/cm_camera.dart';
import 'package:flutter_hbb/nikodesk/cm_camera_panel.dart';
import 'package:flutter_hbb/nikodesk/cm_tunnel.dart';
import 'package:flutter_hbb/nikodesk/cm_tunnel_panel.dart';
import 'package:flutter_hbb/nikodesk/cm_voice_panel.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/voice_session_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_cm_camera_test.dart'
    show cameraCatalog, cameraStatus, macFormat;
import 'nikodesk_cm_tunnel_test.dart'
    show resolvedTunnel, tunnelModel, tunnelQueued;
import 'nikodesk_voice_session_model_test.dart'
    show parsedVoiceCatalog, parsedVoiceStatus, voiceQueued;

// The connection manager's choices in the design system: NlSelect instead of
// the Material dropdown, with the same explicit-choice rules the panels'
// legacy tests pin. Fixtures only; nothing reaches a native session.
Widget _host(Widget child, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
        theme: nightlineTheme(brightness),
        home: Scaffold(body: SingleChildScrollView(child: child)));

Future<void> _pick(WidgetTester tester, String key, String option) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

VoidCallback? _approve(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(find.byKey(ValueKey(key))).onPressed;

void main() {
  tearDown(() => NikoLanguage.english = false);

  group('NlSelect', () {
    Widget select(String? value, ValueChanged<String>? onChanged) =>
        _host(SizedBox(
            width: 260,
            child: NlSelect<String>(
                key: const ValueKey('select'),
                label: 'Camera',
                placeholder: 'Choose a camera',
                value: value,
                options: const [
                  NlSelectOption('a', 'FaceTime HD Camera'),
                  NlSelectOption('b', 'Desk View Camera'),
                  NlSelectOption('c', '4K Camera', enabled: false),
                ],
                onChanged: onChanged)));

    testWidgets('lists the options, checks the choice and reports a pick',
        (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(select(null, picked.add));
      expect(find.text('Choose a camera'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('select')));
      await tester.pumpAndSettle();
      expect(find.text('Desk View Camera'), findsOneWidget);
      expect(find.byIcon(NlIcons.check), findsNothing);
      // A disabled option stays shut.
      await tester.tap(find.text('4K Camera'));
      await tester.pumpAndSettle();
      expect(picked, isEmpty);
      await tester.tap(find.text('Desk View Camera'));
      await tester.pumpAndSettle();
      expect(picked, ['b']);

      await tester.pumpWidget(select('b', picked.add));
      expect(find.text('Desk View Camera'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('select')));
      await tester.pumpAndSettle();
      expect(find.byIcon(NlIcons.check), findsOneWidget);
    });

    testWidgets('a field without a handler or options does not open',
        (tester) async {
      await tester.pumpWidget(select(null, null));
      await tester.tap(find.byKey(const ValueKey('select')));
      await tester.pumpAndSettle();
      expect(find.text('Desk View Camera'), findsNothing);
      expect(
          tester
              .widget<NlSelect<String>>(find.byType(NlSelect<String>))
              .enabled,
          isFalse);
    });

    testWidgets('a long choice fits 200 px at 200% text', (tester) async {
      await tester.pumpWidget(MaterialApp(
          theme: nightlineTheme(Brightness.light),
          home: Builder(
              builder: (context) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: Scaffold(
                      body: SizedBox(
                          width: 200,
                          child: NlSelect<String>(
                              label: 'Microphone format',
                              placeholder: 'Choose a format',
                              value: 'a',
                              options: const [
                                NlSelectOption('a',
                                    'MacBook Pro Microphone, 48 kHz, f32, stereo')
                              ],
                              onChanged: (_) {})))))));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
      'voice: approval waits for all four choices; a new catalog '
      'clears them', (tester) async {
    final sent = <NikoVoiceCommand>[];
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(),
        availability: NikoVoiceAvailability.enabled,
        transport: (command) async {
          sent.add(command);
          return voiceQueued(command);
        });
    addTearDown(model.dispose);
    model.applyCatalog(parsedVoiceCatalog());
    await tester.pumpWidget(_host(NikoCmVoicePanel(model: model)));
    await tester.pumpAndSettle();
    expect(_approve(tester, 'niko-voice-approve'), isNull);
    await _pick(tester, 'niko-voice-capture-device', 'Test microphone');
    await _pick(tester, 'niko-voice-capture-format', '48 kHz，f32，单声道');
    await _pick(tester, 'niko-voice-playback-device', 'Test speaker');
    expect(_approve(tester, 'niko-voice-approve'), isNull);
    await _pick(tester, 'niko-voice-playback-format', '48 kHz，f32，双声道');
    expect(_approve(tester, 'niko-voice-approve'), isNotNull);

    model.applyCatalog(parsedVoiceCatalog(roster: '2'));
    await tester.pump();
    expect(_approve(tester, 'niko-voice-approve'), isNull);
    expect(
        tester
            .widget<NlSelect<String>>(
                find.byKey(const ValueKey('niko-voice-capture-device')))
            .value,
        isNull);
    // Choosing devices sends nothing; reading the state is its own action.
    expect(sent, isEmpty);
    await tester.ensureVisible(find.byKey(const ValueKey('niko-voice-query')));
    await tester.tap(find.byKey(const ValueKey('niko-voice-query')));
    await tester.pumpAndSettle();
    expect(sent.map((c) => c.op), ['query']);
  });

  testWidgets(
      'camera: a Mac format needs an in-range frame rate before '
      'approval', (tester) async {
    final sent = <String>[];
    final catalog = cameraCatalog(formats: [macFormat()]);
    await tester.pumpWidget(_host(NikoCameraCapabilityPanel(
        status: NikoCameraStatus.parse(jsonEncode(cameraStatus()))!,
        catalog: NikoCameraCatalog.parse(jsonEncode(catalog))!,
        canRequestSystemPermission: true,
        sendCommand: (json) async {
          sent.add(json);
          return jsonEncode({'ok': true, 'status': 'queued'});
        })));
    await tester.pumpAndSettle();
    await _pick(tester, 'niko-camera-device', 'Camera name');
    await _pick(tester, 'niko-camera-format', '1280 × 720，15.0–60.0 FPS');
    final approve = find.widgetWithText(FilledButton, '选择并授权此会话');
    expect(tester.widget<FilledButton>(approve).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('niko-camera-fps')), '14');
    await tester.pump();
    expect(tester.widget<FilledButton>(approve).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('niko-camera-fps')), '30');
    await tester.pump();
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('允许此会话')));
    await tester.pumpAndSettle();
    expect(jsonDecode(sent.single)['fps'], 30);
    expect(jsonDecode(sent.single)['format_token'], 'e' * 32);
  });

  testWidgets('tunnel: each non-loopback choice must be allowed again',
      (tester) async {
    final sent = <NikoTunnelCommand>[];
    final model = tunnelModel(
        resolvedTunnel(addresses: ['10.0.0.7:23456', '10.0.0.8:23456']),
        transport: (command) async {
      sent.add(command);
      return tunnelQueued(command);
    });
    addTearDown(model.dispose);
    await tester.pumpWidget(_host(NikoCmTunnelPanel(model: model)));
    await tester.pumpAndSettle();
    await _pick(tester, 'niko-tunnel-address', '10.0.0.7:23456');
    final checkbox = find.byKey(const ValueKey('niko-tunnel-non-loopback'));
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
    expect(_approve(tester, 'niko-tunnel-approve'), isNull);
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(_approve(tester, 'niko-tunnel-approve'), isNotNull);
    await _pick(tester, 'niko-tunnel-address', '10.0.0.8:23456');
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
    expect(_approve(tester, 'niko-tunnel-approve'), isNull);
    expect(sent, isEmpty);
  });
}
