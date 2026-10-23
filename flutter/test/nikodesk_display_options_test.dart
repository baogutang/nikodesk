import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart'
    show TRadioMenu, TToggleMenu;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/nikodesk/display_options_view.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

// The stock menu models stand in for a session; no FFI call is made.
class _Menus {
  final calls = <String>[];

  List<TRadioMenu<String>> radios(
          String name, List<String> values, String selected,
          {Set<String> disabled = const {}}) =>
      [
        for (final value in values)
          TRadioMenu<String>(
              child: Text('$name $value'),
              value: value,
              groupValue: selected,
              onChanged: disabled.contains(value)
                  ? null
                  : (v) => calls.add('$name $v')),
      ];

  List<TToggleMenu> toggles(Map<String, bool?> values) => [
        for (final MapEntry(key: label, :value) in values.entries)
          TToggleMenu(
              child: Text(label),
              value: value ?? false,
              onChanged: value == null ? null : (v) => calls.add('$label $v')),
      ];
}

void main() {
  tearDown(() => NikoLanguage.english = false);

  Widget host(Widget child, {Brightness brightness = Brightness.dark}) =>
      MaterialApp(
          theme: nikoTheme(brightness),
          home: Scaffold(
              body: Padding(padding: const EdgeInsets.all(24), child: child)));

  NikoDisplayOptionsPanel panel(_Menus menus,
          {int displays = 0,
          ValueChanged<int>? onDisplay,
          WidgetBuilder? customScale,
          String viewStyle = kRemoteViewStyleAdaptive,
          String quality = kRemoteImageQualityBalanced,
          VoidCallback? onResolution,
          VoidCallback? onPictureMode,
          VoidCallback? onDiagnostics,
          VoidCallback? onClose}) =>
      NikoDisplayOptionsPanel(
          connection: 'Relayed and encrypted connection (TCP)',
          displays: displays,
          currentDisplay: 0,
          onDisplay: onDisplay,
          viewStyles: menus.radios(
              'view',
              [
                kRemoteViewStyleOriginal,
                kRemoteViewStyleAdaptive,
                kRemoteViewStyleCustom
              ],
              viewStyle),
          customScale: customScale,
          qualities: menus.radios(
              'quality',
              [
                kRemoteImageQualityBest,
                kRemoteImageQualityBalanced,
                kRemoteImageQualityLow,
                kRemoteImageQualityCustom
              ],
              quality),
          codecs: menus.radios('codec', ['auto', 'vp9', 'h264'], 'auto',
              disabled: {'h264'}),
          codecInUse: 'VP9',
          onPictureMode: onPictureMode,
          resolution: '2560×1440',
          onResolution: onResolution,
          cursors: menus.toggles({'Show remote cursor': true}),
          toggles: menus.toggles({
            'Lock canvas': false,
            'Mute': true,
            'Disable clipboard': null,
          }),
          onDiagnostics: onDiagnostics,
          onClose: onClose ?? () {});

  testWidgets('choices call the stock handler and keep the selection',
      (tester) async {
    NikoLanguage.english = true;
    final menus = _Menus();
    await tester.pumpWidget(host(
        panel(menus, customScale: (_) => const Text('custom scale control'))));
    await tester.pumpAndSettle();

    // Fit comes first, as in the control center.
    final fit = tester.getTopLeft(find.text('Fit window')).dx;
    expect(fit, lessThan(tester.getTopLeft(find.text('Original 1:1')).dx));
    expect(find.text('custom scale control'), findsNothing);

    await tester
        .tap(find.byKey(const ValueKey('nikodesk-view-style-adaptive')));
    await tester.tap(find.byKey(const ValueKey('nikodesk-view-style-custom')));
    await tester.pumpAndSettle();
    expect(menus.calls, ['view custom']);
    expect(find.text('custom scale control'), findsOneWidget);
    final view = tester.widget<NlSegmented<String?>>(
        find.byKey(const Key('nikodesk-view-style')));
    expect(view.selected, kRemoteViewStyleCustom);

    // Custom quality reopens its settings when chosen again.
    menus.calls.clear();
    final custom = find.byKey(const ValueKey('nikodesk-image-quality-custom'));
    await tester.tap(custom);
    await tester.tap(custom);
    await tester.tap(find.byKey(const ValueKey('nikodesk-image-quality-low')));
    await tester.tap(find.byKey(const ValueKey('nikodesk-image-quality-low')));
    await tester.pumpAndSettle();
    expect(menus.calls, ['quality custom', 'quality custom', 'quality low']);
    expect(find.text('Speed'), findsOneWidget);

    // A codec the peer cannot use stays unselected.
    menus.calls.clear();
    expect(find.text('Using VP9.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nikodesk-codec-h264')));
    await tester.tap(find.byKey(const ValueKey('nikodesk-codec-vp9')));
    await tester.pumpAndSettle();
    expect(menus.calls, ['codec vp9']);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('VP9'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switches call the stock handler; one without a handler is off',
      (tester) async {
    NikoLanguage.english = true;
    final menus = _Menus();
    await tester.pumpWidget(host(panel(menus)));
    await tester.pumpAndSettle();

    expect(find.text('Cursor'), findsOneWidget);
    expect(find.text('Session'), findsOneWidget);
    final lock = find.byKey(const Key('nikodesk-toggle-0'));
    await tester.ensureVisible(lock);
    await tester.tap(lock);
    await tester.pumpAndSettle();
    expect(menus.calls, ['Lock canvas true']);
    expect(tester.widget<NlSwitch>(lock).value, isTrue);

    final clipboard = find.byKey(const Key('nikodesk-toggle-2'));
    await tester.ensureVisible(clipboard);
    expect(tester.widget<NlSwitch>(clipboard).onChanged, isNull);
    await tester.tap(clipboard);
    await tester.pumpAndSettle();
    expect(menus.calls, ['Lock canvas true']);
  });

  testWidgets('display switcher shows only with several displays',
      (tester) async {
    final menus = _Menus();
    await tester.pumpWidget(host(panel(menus, displays: 1)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nikodesk-displays')), findsNothing);

    final picked = <int>[];
    await tester
        .pumpWidget(host(panel(menus, displays: 3, onDisplay: picked.add)));
    await tester.pumpAndSettle();
    expect(find.text('远端有 3 块显示器。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nikodesk-display-0')));
    await tester.tap(find.byKey(const ValueKey('nikodesk-display-2')));
    expect(picked, [2]);
  });

  testWidgets('rows open their tools and the header closes the sheet',
      (tester) async {
    NikoLanguage.english = true;
    final events = <String>[];
    await tester.pumpWidget(host(panel(_Menus(),
        onResolution: () => events.add('resolution'),
        onPictureMode: () => events.add('picture mode'),
        onDiagnostics: () => events.add('diagnostics'),
        onClose: () => events.add('close'))));
    await tester.pumpAndSettle();

    expect(find.text('Relayed and encrypted connection (TCP)'), findsOneWidget);
    expect(find.text('2560×1440'), findsOneWidget);
    final resolution = find.byKey(const Key('nikodesk-resolution'));
    await tester.ensureVisible(resolution);
    await tester.tap(resolution);
    final picture = find.byKey(const Key('nikodesk-picture-mode'));
    await tester.ensureVisible(picture);
    await tester.tap(picture);
    await tester.tap(find.byTooltip('Session diagnostics'));
    await tester.tap(find.byKey(const Key('nikodesk-display-close')));
    expect(events, ['resolution', 'picture mode', 'diagnostics', 'close']);
    expect(find.byKey(const Key('nikodesk-virtual-display')), findsNothing);
  });

  testWidgets('scale slider steps and reports its percent', (tester) async {
    NikoLanguage.english = true;
    final steps = <int>[];
    final moves = <double>[];
    await tester.pumpWidget(host(NikoScaleSlider(
        percent: 125,
        position: .4,
        divisions: 995,
        onChanged: moves.add,
        onStep: steps.add)));
    expect(find.text('125%'), findsOneWidget);
    await tester.tap(find.byTooltip('Smaller'));
    await tester.tap(find.byTooltip('Larger'));
    await tester.drag(
        find.byKey(const Key('nikodesk-custom-scale')), const Offset(40, 0));
    expect(steps, [-1, 1]);
    expect(moves, isNotEmpty);
  });

  for (final english in [false, true]) {
    for (final brightness in Brightness.values) {
      testWidgets(
          'display options fit 320px at 200% text ($english/$brightness)',
          (tester) async {
        NikoLanguage.english = english;
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var closes = 0;
        await tester.pumpWidget(MaterialApp(
            theme: nikoTheme(brightness),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(2)),
                child: child!),
            home: Scaffold(
                body: Padding(
                    padding: const EdgeInsets.all(16),
                    child: panel(_Menus(),
                        displays: 2,
                        onDisplay: (_) {},
                        viewStyle: kRemoteViewStyleCustom,
                        customScale: (_) => NikoScaleSlider(
                            percent: 100,
                            position: 1 / 3,
                            divisions: 995,
                            onChanged: (_) {},
                            onStep: (_) {}),
                        onResolution: () {},
                        onPictureMode: () {},
                        onDiagnostics: () {},
                        onClose: () => closes++)))));
        await tester.pumpAndSettle();
        final last = find.byKey(const Key('nikodesk-toggle-2'));
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nikodesk-display-close')));
        expect(closes, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
