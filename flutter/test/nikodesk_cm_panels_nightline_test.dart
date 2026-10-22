import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/cm_capability_frame.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/voice_call_panel.dart';
import 'package:flutter_hbb/nikodesk/voice_session_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/nikodesk_cm_panels.dart';

// The connection manager's terminal, camera, voice and tunnel panels on
// Nightline: one card each, the phase as a status light, stop actions in the
// danger outline, and the earlier layout without Nightline.
void main() {
  setUp(() => NikoLanguage.english = true);
  tearDown(() => NikoLanguage.english = false);

  Future<void> load(WidgetTester tester, NikoTestCmPanel panel,
      {bool running = false, ThemeData? theme, double scale = 1}) async {
    await tester.binding.setSurfaceSize(const Size(300, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: theme ?? nightlineTheme(Brightness.dark),
        home: Builder(
            builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                    body: NikoTestCmCard(panel,
                        key: ValueKey('${panel.name}-$running'),
                        running: running))))));
    await tester.pumpAndSettle();
  }

  NlLedState light(WidgetTester tester) => tester
      .widget<NlLed>(find.descendant(
          of: find.byType(NikoCmCapabilityFrame), matching: find.byType(NlLed)))
      .state;

  test('a phase is amber while waiting, green running, red in recovery', () {
    expect(nikoCmPhaseTone('Pending'), NlTone.warn);
    expect(nikoCmPhaseTone('Starting'), NlTone.warn);
    expect(nikoCmPhaseTone('Revoking'), NlTone.warn);
    expect(nikoCmPhaseTone('Running'), NlTone.ok);
    expect(nikoCmPhaseTone('RecoveryRequired'), NlTone.danger);
    expect(nikoCmPhaseTone('Stopped'), NlTone.neutral);
  });

  for (final (panel, label, stop) in [
    (
      NikoTestCmPanel.terminal,
      'LOCAL TERMINAL APPROVAL',
      'Revoke terminal access'
    ),
    (
      NikoTestCmPanel.camera,
      'LOCAL CAMERA APPROVAL',
      'Stop and revoke camera access'
    ),
    (NikoTestCmPanel.voice, 'LOCAL VOICE APPROVAL', 'End voice call'),
    (NikoTestCmPanel.tunnel, 'LOCAL TUNNEL APPROVAL', 'Stop this tunnel'),
  ]) {
    testWidgets('${panel.name}: one card, amber while waiting, green running',
        (tester) async {
      await load(tester, panel);
      expect(find.byType(NikoCmCapabilityFrame), findsOneWidget);
      expect(find.text(label), findsOneWidget);
      expect(light(tester), NlLedState.warn);
      await load(tester, panel, running: true);
      expect(light(tester), NlLedState.ok);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${panel.name}: "$stop" is a 48 px danger outline',
        (tester) async {
      await load(tester, panel, running: true);
      final nl = NlColors.forBrightness(Brightness.dark);
      final button = find.widgetWithText(OutlinedButton, stop);
      final style = tester.widget<OutlinedButton>(button).style!;
      expect(style.foregroundColor!.resolve({}), nl.dangerText);
      expect(style.side!.resolve({})!.color, nl.danger.withOpacity(.6));
      expect(style.foregroundColor!.resolve({WidgetState.disabled}), nl.fg3);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    });

    testWidgets('${panel.name}: 200% text fits the 300 px window',
        (tester) async {
      await load(tester, panel, scale: 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${panel.name}: without Nightline the panel keeps its layout',
        (tester) async {
      await load(tester, panel, theme: nikoTheme(Brightness.light));
      expect(find.byType(NikoCmCapabilityFrame), findsNothing);
      expect(find.byType(NlLed), findsNothing);
      await load(tester, panel,
          running: true, theme: nikoTheme(Brightness.light));
      final style = tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, stop))
          .style;
      expect(style?.foregroundColor, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('other actions keep the neutral outline', (tester) async {
    await load(tester, NikoTestCmPanel.voice, running: true);
    final read = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Read current status'));
    expect(read.style!.foregroundColor, isNull);
  });

  testWidgets('terminal: Allow and Deny are 48 px and Deny is outlined',
      (tester) async {
    await load(tester, NikoTestCmPanel.terminal);
    expect(
        tester
            .getSize(find.widgetWithText(FilledButton, 'Allow this session'))
            .height,
        48);
    expect(find.widgetWithText(OutlinedButton, 'Deny'), findsOneWidget);
    await load(tester, NikoTestCmPanel.terminal,
        theme: nikoTheme(Brightness.dark));
    expect(find.widgetWithText(TextButton, 'Deny'), findsOneWidget);
  });

  testWidgets('the label is a heading and the phase a live region',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await load(tester, NikoTestCmPanel.camera);
    expect(tester.getSemantics(find.text('LOCAL CAMERA APPROVAL')),
        containsSemantics(isHeader: true));
    expect(tester.getSemantics(find.text('Camera waiting for local approval')),
        containsSemantics(isLiveRegion: true));
    semantics.dispose();
  });

  testWidgets('the call offer is one card with the prepare step inside',
      (tester) async {
    await load(tester, NikoTestCmPanel.voiceStart);
    expect(find.byType(NikoCmCapabilityFrame), findsOneWidget);
    expect(find.text('Call the controller'), findsOneWidget);
    expect(find.byKey(const ValueKey('niko-voice-prepare')), findsOneWidget);
    expect(light(tester), NlLedState.off);
  });

  testWidgets('outside the offer the prepare step is its own card',
      (tester) async {
    final preparation = NikoVoicePreparation(
        contextKey: '12/${'b' * 32}',
        availability: NikoVoiceAvailability.enabled);
    addTearDown(preparation.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: nightlineTheme(Brightness.light),
        home: Scaffold(body: NikoVoiceCallPanel(preparation: preparation))));
    expect(find.byType(NikoCmCapabilityFrame), findsOneWidget);
    expect(find.text('VOICE CALL'), findsOneWidget);
    expect(find.byKey(const ValueKey('niko-voice-prepare')), findsOneWidget);
  });
}
