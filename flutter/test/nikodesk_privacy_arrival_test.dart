import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/privacy_connection.dart';
import 'package:flutter_hbb/nikodesk/privacy_style.dart';
import 'package:flutter_hbb/nikodesk/privacy_style_events.dart';
import 'package:flutter_hbb/nikodesk/privacy_screen_policy.dart';
import 'package:flutter_hbb/nikodesk/privacy_style_model.dart';
import 'package:flutter_hbb/nikodesk/privacy_wallpaper.dart';
import 'package:flutter_hbb/nikodesk/session_quick_actions_view.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => NikoLanguage.english = true);
  tearDown(() => NikoLanguage.english = false);
  testWidgets('connection reminder is optional and automatic mode is opt-in',
      (tester) async {
    var skipped = 0, enabled = 0;
    bool? preference;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoPrivacyArrivalView(
                allowed: true,
                auto: false,
                busy: false,
                onAuto: (value) => preference = value,
                onEnable: () => enabled++,
                onSkip: () => skipped++))));
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('privacy-arrival-auto')))
            .value,
        isFalse);
    expect(enabled, 0);
    await tester.tap(find.byKey(const Key('privacy-arrival-skip')));
    expect(skipped, 1);
    expect(enabled, 0);
    await tester.tap(find.byKey(const Key('privacy-arrival-auto')));
    expect(preference, isTrue);
    expect(enabled, 0);
    await tester.tap(find.byKey(const Key('privacy-arrival-enable')));
    expect(enabled, 1);
  });
  testWidgets(
      'a pending request prevents duplicate toggles and shows its failure',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoPrivacyArrivalView(
                allowed: true,
                auto: true,
                busy: true,
                error: 'Screen capture is not ready',
                onAuto: (_) {},
                onEnable: () {},
                onSkip: () {}))));
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('privacy-arrival-enable')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('privacy-arrival-auto')))
            .onChanged,
        isNull);
    expect(find.text('Screen capture is not ready'), findsOneWidget);
  });
  testWidgets(
      'missing permission offers settings without claiming privacy is active',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoPrivacyArrivalView(
                allowed: false,
                auto: false,
                busy: false,
                onAuto: (_) {},
                onEnable: () {},
                onSkip: () {}))));
    expect(find.text('Check settings'), findsOneWidget);
    expect(find.text('Privacy screen is on'), findsNothing);
  });
  test('capture stage failures give the controller an actionable explanation',
      () {
    for (final reason in [
      'excluded_capture_content_timeout',
      'excluded_capture_start_timeout',
      'excluded_capture_not_ready'
    ]) {
      expect(nikoPrivacyStyleError(NikoPrivacyStyleError(reason)),
          contains('screen-recording prompt'));
    }
    expect(
        nikoPrivacyStyleError(
            const NikoPrivacyStyleError('excluded_capture_helper_unavailable')),
        contains('screen-recording permission'));
  });
  testWidgets('password-protected hosts always show the status and exit key',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: SizedBox(
            width: 600,
            height: 400,
            child: NikoPrivacyWallpaper(
                style: NikoPrivacyStyle(hint: false), animate: false))));
    expect(find.text('Privacy screen is on'), findsOneWidget);
    expect(
        find.textContaining('System login password required'), findsOneWidget);
    expect(find.textContaining('⌃⌥⇧ Esc'), findsOneWidget);
  });
  testWidgets('old hosts do not claim a password-protected exit',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: SizedBox(
            width: 600,
            height: 400,
            child: NikoPrivacyWallpaper(
                style: NikoPrivacyStyle(hint: false),
                animate: false,
                passwordExit: false))));
    expect(find.textContaining('System login password required'), findsNothing);
    expect(
        nikoPrivacyScreenDetail(NikoPrivacyScreenStatus.on, 'Mac OS',
            passwordExit: true),
        contains('verify the system login password'));
    expect(nikoPrivacyScreenDetail(NikoPrivacyScreenStatus.on, 'Mac OS'),
        isNot(contains('system login password')));
  });
  testWidgets('automatic preference preserves old black-screen explanations',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoSessionQuickActionsPanel(
                peerPlatform: 'Mac OS',
                keyboardAllowed: true,
                canvasAllowed: true,
                viewStyle: 'adaptive',
                onShortcut: (_) async {},
                onViewStyle: (_) async {},
                onClose: () {},
                privacyScreen: NikoPrivacyScreenStatus.on,
                onPrivacyScreen: (_) async {},
                privacyAuto: const Text('Auto preference')))));
    expect(find.textContaining('remote screen is black'), findsOneWidget);
    expect(find.text('Auto preference'), findsOneWidget);
    expect(
        find.textContaining('leave it on to have it every time'), findsNothing);
  });
  testWidgets('old hosts retain their optional recovery hint setting',
      (tester) async {
    NikoPrivacyStyle? applied;
    Widget editor(bool passwordExit) => MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: NikoPrivacyStyleEditor(
                    initial: const NikoPrivacyStyle(motion: false),
                    passwordExit: passwordExit,
                    allowed: true,
                    active: false,
                    onApply: (style) async {
                      applied = style;
                    }))));
    await tester.pumpWidget(editor(false));
    await tester.ensureVisible(find.text('Restore hint'));
    await tester.tap(find.text('Restore hint'));
    await tester.pump();
    final apply = find.byKey(const Key('privacy-apply-style'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pump();
    expect(applied!.hint, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(editor(true));
    expect(find.text('Restore hint'), findsNothing);
    expect(find.text('Privacy screen is on'), findsOneWidget);
  });
}
