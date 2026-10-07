import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/nikodesk/privacy_screen.dart';
import 'package:flutter_hbb/nikodesk/session_quick_actions_view.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

NikoPrivacyScreenStatus _status(
        {bool supported = true,
        bool allowed = true,
        bool viewOnly = false,
        String active = ''}) =>
    nikoPrivacyScreenStatus(
        supported: supported,
        allowed: allowed,
        viewOnly: viewOnly,
        active: active);

void main() {
  tearDown(() {
    NikoLanguage.english = false;
    Get.reset();
  });

  test('the state follows what the controlled side reported and allows', () {
    expect(_status(), NikoPrivacyScreenStatus.off);
    expect(_status(active: 'privacy_mode_impl_macos'),
        NikoPrivacyScreenStatus.on);
    expect(_status(allowed: false), NikoPrivacyScreenStatus.notAllowed);
    expect(_status(viewOnly: true), NikoPrivacyScreenStatus.viewOnly);
    expect(_status(supported: false), NikoPrivacyScreenStatus.unsupported);
    // The more basic reason is the one shown.
    expect(_status(supported: false, allowed: false),
        NikoPrivacyScreenStatus.unsupported);
    expect(_status(allowed: false, viewOnly: true),
        NikoPrivacyScreenStatus.notAllowed);
  });

  test('a running privacy screen is shown as on so it can be turned off', () {
    // Permission withdrawn, session made view-only, feature no longer listed:
    // the screen over there is still black until someone turns it off.
    for (final status in [
      _status(active: 'x', allowed: false),
      _status(active: 'x', viewOnly: true),
      _status(active: 'x', supported: false),
    ]) {
      expect(status, NikoPrivacyScreenStatus.on);
      expect(nikoPrivacyScreenCanToggle(status), isTrue);
    }
    expect(nikoPrivacyScreenCanToggle(NikoPrivacyScreenStatus.off), isTrue);
    for (final status in [
      NikoPrivacyScreenStatus.notAllowed,
      NikoPrivacyScreenStatus.viewOnly,
      NikoPrivacyScreenStatus.unsupported,
    ]) {
      expect(nikoPrivacyScreenCanToggle(status), isFalse);
    }
  });

  test('the implementation asked for is one the controlled side offered', () {
    const mac = [
      ['privacy_mode_impl_macos', 'privacy_mode_impl_macos_tip']
    ];
    const windows = [
      ['privacy_mode_impl_exclude_from_capture', 'a'],
      ['privacy_mode_impl_virtual_display', 'b'],
    ];
    expect(nikoPrivacyScreenImpl(mac, null), 'privacy_mode_impl_macos');
    expect(nikoPrivacyScreenImpl(mac, ''), 'privacy_mode_impl_macos');
    // What this device used last, while it is still offered.
    expect(nikoPrivacyScreenImpl(windows, 'privacy_mode_impl_virtual_display'),
        'privacy_mode_impl_virtual_display');
    // Remembered from another computer, or from an older version of this one.
    expect(nikoPrivacyScreenImpl(windows, 'privacy_mode_impl_mag'),
        'privacy_mode_impl_exclude_from_capture');
    expect(nikoPrivacyScreenImpl(mac, 'privacy_mode_impl_mag'),
        'privacy_mode_impl_macos');
    // Nothing offered, or something that is not a list of pairs.
    expect(nikoPrivacyScreenImpl(const [], null), isNull);
    expect(nikoPrivacyScreenImpl('privacy_mode_impl_macos', null), isNull);
    expect(nikoPrivacyScreenImpl(const [[], 3, 'x'], null), isNull);
    // Versions from before the list existed take a plain toggle.
    expect(nikoPrivacyScreenImpl(null, 'privacy_mode_impl_macos'), '');
  });

  test('each state says what it means for the person at the controller', () {
    final on = nikoPrivacyScreenDetail(NikoPrivacyScreenStatus.on, 'Mac OS');
    expect(on, contains('黑'));
    expect(on, contains('Control + Option + Shift + Esc'));
    final windows =
        nikoPrivacyScreenDetail(NikoPrivacyScreenStatus.on, 'Windows');
    expect(windows, contains('遮住'));
    expect(windows, contains('Esc'));
    expect(windows, isNot(contains('Option')));
    final blocked =
        nikoPrivacyScreenDetail(NikoPrivacyScreenStatus.notAllowed, 'Mac OS');
    expect(blocked, contains('会话安全'));
    expect(blocked, contains('允许新连接使用隐私屏'));
    NikoLanguage.english = true;
    expect(nikoPrivacyScreenLabel(NikoPrivacyScreenStatus.on),
        'Privacy screen is on');
    expect(
        nikoPrivacyScreenDetail(NikoPrivacyScreenStatus.notAllowed, 'Windows'),
        contains('Session security'));
  });

  Widget panel(NikoPrivacyScreenStatus? status,
          {Future<void> Function(bool)? change, String platform = 'Mac OS'}) =>
      MaterialApp(
          home: Scaffold(
              body: NikoSessionQuickActionsPanel(
        peerPlatform: platform,
        keyboardAllowed: true,
        canvasAllowed: true,
        viewStyle: 'adaptive',
        onShortcut: (_) async {},
        onViewStyle: (_) async {},
        privacyScreen: status,
        onPrivacyScreen: change,
        onClose: () {},
      )));

  SwitchListTile tile(WidgetTester tester) => tester.widget<SwitchListTile>(
      find.byKey(const Key('nikodesk-privacy-screen')));

  testWidgets('the control center has no privacy section without a state',
      (tester) async {
    await tester.pumpWidget(panel(null));
    expect(find.byKey(const Key('nikodesk-privacy-screen')), findsNothing);
    expect(find.text('隐私屏'), findsNothing);
  });

  testWidgets('switching asks for the opposite state and reports the request',
      (tester) async {
    final asked = <bool>[];
    await tester.pumpWidget(panel(NikoPrivacyScreenStatus.off,
        change: (on) async => asked.add(on)));
    expect(find.text('隐私屏已关闭'), findsOneWidget);
    expect(tile(tester).value, isFalse);
    await tester.tap(find.byKey(const Key('nikodesk-privacy-screen')));
    await tester.pumpAndSettle();
    expect(asked, [true]);
    expect(find.textContaining('已请求开启'), findsOneWidget);
    // The switch itself only moves when the controlled side confirms.
    expect(tile(tester).value, isFalse);

    await tester.pumpWidget(panel(NikoPrivacyScreenStatus.on,
        change: (on) async => asked.add(on)));
    expect(find.text('隐私屏已开启'), findsOneWidget);
    expect(tile(tester).value, isTrue);
    await tester.tap(find.byKey(const Key('nikodesk-privacy-screen')));
    await tester.pumpAndSettle();
    expect(asked, [true, false]);
  });

  testWidgets('a request that could not be sent says so', (tester) async {
    await tester.pumpWidget(panel(NikoPrivacyScreenStatus.off,
        change: (_) async => throw StateError('closed')));
    await tester.tap(find.byKey(const Key('nikodesk-privacy-screen')));
    await tester.pumpAndSettle();
    expect(find.textContaining('请求没有发出'), findsOneWidget);
    expect(tile(tester).value, isFalse);
  });

  testWidgets('states that are not a switch explain themselves instead',
      (tester) async {
    for (final status in [
      NikoPrivacyScreenStatus.notAllowed,
      NikoPrivacyScreenStatus.viewOnly,
      NikoPrivacyScreenStatus.unsupported,
    ]) {
      var asked = false;
      await tester
          .pumpWidget(panel(status, change: (_) async => asked = true));
      expect(tile(tester).onChanged, isNull, reason: '$status');
      expect(find.text(nikoPrivacyScreenLabel(status)), findsOneWidget);
      expect(find.text(nikoPrivacyScreenDetail(status, 'Mac OS')),
          findsOneWidget);
      expect(find.textContaining('下次连接这台设备会自动再开启'), findsNothing);
      expect(asked, isFalse);
    }
  });

  Widget button(NikoPrivacyScreenStatus status, List<Object> log) =>
      MaterialApp(
          home: Scaffold(
              body: NikoPrivacyScreenButtonView(
        status: status,
        onSwitch: (on) async {
          log.add(on);
          if (log.contains('fail')) throw StateError('not sent');
        },
        onExplain: () => log.add('explain'),
      )));

  testWidgets('the toolbar button shows the state and switches it in one click',
      (tester) async {
    final log = <Object>[];
    final key = find.byKey(const Key('nikodesk-privacy-screen-button'));
    await tester.pumpWidget(button(NikoPrivacyScreenStatus.off, log));
    expect(find.byTooltip('隐私屏已关闭，点击开启'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    await tester.tap(key);
    await tester.pump();
    expect(log, [true]);

    await tester.pumpWidget(button(NikoPrivacyScreenStatus.on, log));
    expect(find.byTooltip('隐私屏已开启，点击关闭'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(
                find.descendant(of: key, matching: find.byType(IconButton)))
            .isSelected,
        isTrue);
    await tester.tap(key);
    await tester.pump();
    expect(log, [true, false]);
  });

  testWidgets('the toolbar button explains instead of switching when it cannot',
      (tester) async {
    final key = find.byKey(const Key('nikodesk-privacy-screen-button'));
    for (final status in [
      NikoPrivacyScreenStatus.notAllowed,
      NikoPrivacyScreenStatus.viewOnly,
    ]) {
      final log = <Object>[];
      await tester.pumpWidget(button(status, log));
      expect(find.byTooltip('${nikoPrivacyScreenLabel(status)}，点击查看原因'),
          findsOneWidget);
      await tester.tap(key);
      await tester.pump();
      expect(log, ['explain'], reason: '$status');
    }
    // A request that could not be sent ends in the explanation too.
    final log = <Object>['fail'];
    await tester.pumpWidget(button(NikoPrivacyScreenStatus.off, log));
    await tester.tap(key);
    await tester.pumpAndSettle();
    expect(log, ['fail', true, 'explain']);
    // A remote without a privacy screen gets no button.
    await tester.pumpWidget(button(NikoPrivacyScreenStatus.unsupported, []));
    expect(key, findsNothing);
  });

  testWidgets('the badge shows only while the privacy screen is on',
      (tester) async {
    const peer = '123456789';
    Widget page() => const MaterialApp(
        home: Stack(children: [NikoPrivacyScreenBadge(peerId: peer)]));
    // Outside a session page nothing is registered and nothing is drawn.
    await tester.pumpWidget(page());
    expect(find.byKey(const Key('nikodesk-privacy-screen-badge')), findsNothing);

    PrivacyModeState.init(peer);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    expect(find.byKey(const Key('nikodesk-privacy-screen-badge')), findsNothing);
    PrivacyModeState.find(peer).value = 'privacy_mode_impl_macos';
    await tester.pump();
    expect(
        find.byKey(const Key('nikodesk-privacy-screen-badge')), findsOneWidget);
    expect(find.text('隐私屏已开启'), findsOneWidget);
    PrivacyModeState.find(peer).value = '';
    await tester.pump();
    expect(find.byKey(const Key('nikodesk-privacy-screen-badge')), findsNothing);
  });
}
