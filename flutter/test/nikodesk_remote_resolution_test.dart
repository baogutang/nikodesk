import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/remote_resolution_policy.dart';
import 'package:flutter_hbb/nikodesk/session_quick_actions_view.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

const _retina5k = [
  NikoDisplayMode(5120, 2880),
  NikoDisplayMode(3840, 2160),
  NikoDisplayMode(3200, 1800),
  NikoDisplayMode(2560, 1600),
  NikoDisplayMode(2560, 1440),
  NikoDisplayMode(2304, 1296),
  NikoDisplayMode(2048, 1152),
  NikoDisplayMode(1920, 1200),
  NikoDisplayMode(1920, 1080),
  NikoDisplayMode(1600, 900),
  NikoDisplayMode(1280, 720),
  NikoDisplayMode(1024, 576),
];

NikoDisplayMode? _fit(int localLongEdge,
        {Iterable<NikoDisplayMode> supported = _retina5k,
        NikoDisplayMode original = const NikoDisplayMode(2560, 1440),
        double scale = 2}) =>
    nikoFitDisplayMode(
        supported: supported,
        original: original,
        remoteScale: scale,
        localLongEdge: localLongEdge);

void main() {
  tearDown(() => NikoLanguage.english = false);

  test('a 4K controller gets the Retina mode that captures exactly 4K', () {
    expect(_fit(3840), const NikoDisplayMode(1920, 1080));
  });

  test('a phone gets the smallest mode that still fills its long edge', () {
    expect(_fit(2400), const NikoDisplayMode(1280, 720));
  });

  test('a screen as large as the remote keeps the original mode', () {
    expect(_fit(5120), isNull);
    expect(_fit(6016), isNull);
  });

  test('other aspect ratios and larger modes are never picked', () {
    final picked = _fit(3840, supported: const [
      NikoDisplayMode(5120, 2880),
      NikoDisplayMode(1920, 1200),
      NikoDisplayMode(2560, 1600),
    ]);
    expect(picked, isNull);
  });

  test('a non-Retina remote compares its modes as pixels', () {
    const modes = [
      NikoDisplayMode(3840, 2160),
      NikoDisplayMode(2560, 1440),
      NikoDisplayMode(1920, 1080),
      NikoDisplayMode(1280, 720),
    ];
    NikoDisplayMode? fit(int edge) => _fit(edge,
        supported: modes,
        original: const NikoDisplayMode(3840, 2160),
        scale: 1);
    expect(fit(2560), const NikoDisplayMode(2560, 1440));
    expect(fit(1920), const NikoDisplayMode(1920, 1080));
    expect(fit(3840), isNull);
  });

  test('unknown local size or original mode picks nothing', () {
    expect(_fit(0), isNull);
    expect(_fit(3840, original: const NikoDisplayMode(0, 0)), isNull);
  });

  test('a Retina display is in its original mode until a switch is reported',
      () {
    NikoRemoteResolution state(int width, int height) => nikoResolutionState(
        width: width,
        height: height,
        originalWidth: 2560,
        originalHeight: 1440,
        scale: 2,
        supported: _retina5k,
        localLongEdge: 3840);
    final before = state(5120, 2880);
    expect(before.current, const NikoDisplayMode(2560, 1440));
    expect(before.changed, isFalse);
    expect(before.fit, const NikoDisplayMode(1920, 1080));
    final after = state(3840, 2160);
    expect(after.current, const NikoDisplayMode(1920, 1080));
    expect(after.capturedPixels, const NikoDisplayMode(3840, 2160));
    expect(after.changed, isTrue);
    expect(after.fit, after.current);
  });

  test('a plain display reports its mode in pixels', () {
    final state = nikoResolutionState(
        width: 2560,
        height: 1440,
        originalWidth: 3840,
        originalHeight: 2160,
        scale: 1,
        supported: const [
          NikoDisplayMode(3840, 2160),
          NikoDisplayMode(2560, 1440),
        ],
        localLongEdge: 2560);
    expect(state.current, const NikoDisplayMode(2560, 1440));
    expect(state.changed, isTrue);
  });

  test('a switch counts only when it sends fewer pixels and still fills', () {
    const before = NikoDisplayMode(3840, 2160);
    bool reduced(NikoDisplayMode after) => nikoFitReducedPixels(
        before: before, after: after, localLongEdge: 2560);
    expect(reduced(const NikoDisplayMode(2560, 1440)), isTrue);
    // The size was applied as a Retina mode: more pixels than before.
    expect(reduced(const NikoDisplayMode(5120, 2880)), isFalse);
    // The size was applied as a plain mode on a Retina display: too few.
    expect(reduced(const NikoDisplayMode(1280, 720)), isFalse);
    expect(reduced(before), isFalse);
  });

  test('the capture width follows the screen, the choice and its limits', () {
    expect(nikoCaptureWidth(NikoCaptureMode.fit, 3840), 3840);
    expect(nikoCaptureWidth(NikoCaptureMode.fit, 5120), 5120);
    expect(nikoCaptureWidth(NikoCaptureMode.fit, 2400), 2400);
    // The smaller picture is the remote's point size whatever this screen is.
    expect(nikoCaptureWidth(NikoCaptureMode.small, 3840),
        nikoSmallestCaptureWidth);
    expect(nikoCaptureWidth(NikoCaptureMode.small, 0), nikoSmallestCaptureWidth);
    expect(nikoCaptureWidth(NikoCaptureMode.native, 3840), nikoNativeCaptureWidth);
    // An unreadable or absurd local screen never shrinks a fitted picture.
    expect(nikoCaptureWidth(NikoCaptureMode.fit, 0), nikoNativeCaptureWidth);
    expect(nikoCaptureWidth(NikoCaptureMode.fit, 200), nikoSmallestCaptureWidth);
    expect(nikoCaptureWidth(NikoCaptureMode.fit, 1 << 20), nikoNativeCaptureWidth);
    expect(nikoCaptureModeFromName(null), NikoCaptureMode.fit);
    expect(nikoCaptureModeFromName(''), NikoCaptureMode.fit);
    expect(nikoCaptureModeFromName('small'), NikoCaptureMode.small);
    expect(nikoCaptureModeFromName('native'), NikoCaptureMode.native);
    expect(nikoCaptureModeFromName('unknown'), NikoCaptureMode.fit);
  });

  test('a confirmed mode change with identical capture pixels is restored', () {
    const before = NikoRemoteResolution(current: NikoDisplayMode(2560, 1440),
        original: NikoDisplayMode(2560, 1440), capturedPixels: NikoDisplayMode(3840, 2160),
        fit: NikoDisplayMode(1920, 1080), localLongEdge: 1920);
    const after = NikoRemoteResolution(current: NikoDisplayMode(1920, 1080),
        original: NikoDisplayMode(2560, 1440), capturedPixels: NikoDisplayMode(3840, 2160),
        fit: NikoDisplayMode(1920, 1080), localLongEdge: 1920);
    expect(nikoAutoFitShouldRestore(before: before, after: after, requested: before.fit!), isTrue);
  });

  test('rollback never overwrites a different mode or a different original', () {
    const before = NikoRemoteResolution(current: NikoDisplayMode(2560, 1440),
        original: NikoDisplayMode(2560, 1440), capturedPixels: NikoDisplayMode(5120, 2880),
        fit: NikoDisplayMode(1920, 1080), localLongEdge: 3840);
    NikoRemoteResolution after(NikoDisplayMode current, NikoDisplayMode original,
        NikoDisplayMode pixels) => NikoRemoteResolution(current: current,
            original: original, capturedPixels: pixels, fit: before.fit);
    expect(nikoAutoFitShouldRestore(before: before,
        after: after(const NikoDisplayMode(1600, 900), before.original, const NikoDisplayMode(6400, 3600)),
        requested: before.fit!), isFalse);
    expect(nikoAutoFitShouldRestore(before: before,
        after: after(before.fit!, const NikoDisplayMode(3840, 2160), const NikoDisplayMode(5120, 2880)),
        requested: before.fit!), isFalse);
    expect(nikoAutoFitShouldRestore(before: before,
        after: after(before.fit!, before.original, const NikoDisplayMode(3840, 2160)),
        requested: before.fit!), isFalse);
  });

  Widget panel(
          {NikoRemoteResolution? state,
          bool? auto,
          Future<void> Function(NikoDisplayMode)? change,
          Future<void> Function(bool)? setAuto}) =>
      MaterialApp(
          home: Scaffold(
              body: NikoSessionQuickActionsPanel(
        peerPlatform: 'Mac OS',
        keyboardAllowed: true,
        canvasAllowed: true,
        viewStyle: 'adaptive',
        onShortcut: (_) async {},
        onViewStyle: (_) async {},
        remoteResolution: state,
        autoFitResolution: auto,
        onRemoteResolution: change,
        onAutoFitResolution: setAuto,
        onClose: () {},
      )));

  const original = NikoDisplayMode(2560, 1440);
  const fit = NikoDisplayMode(1920, 1080);

  bool enabled(WidgetTester tester, String key) =>
      tester.widget<ButtonStyleButton>(find.byKey(Key(key))).onPressed != null;

  testWidgets('the section is absent when the session cannot offer it',
      (tester) async {
    await tester.pumpWidget(panel());
    expect(find.text('远端分辨率'), findsNothing);
  });

  testWidgets('match sends the fitting mode and restore stays disabled',
      (tester) async {
    final requested = <NikoDisplayMode>[];
    await tester.pumpWidget(panel(
        state: const NikoRemoteResolution(
            current: original,
            original: original,
            capturedPixels: NikoDisplayMode(5120, 2880),
            fit: fit),
        auto: false,
        change: (mode) async => requested.add(mode),
        setAuto: (_) async {}));
    expect(find.textContaining('传输 5120×2880 像素'), findsOneWidget);
    expect(enabled(tester, 'nikodesk-resolution-original'), isFalse);
    final match = find.byKey(const Key('nikodesk-resolution-fit'));
    await tester.ensureVisible(match);
    await tester.tap(match);
    await tester.pumpAndSettle();
    expect(requested, [fit]);
    expect(find.textContaining('已请求远端切换分辨率'), findsOneWidget);
  });

  testWidgets('a changed mode offers restore and no second match',
      (tester) async {
    final requested = <NikoDisplayMode>[];
    await tester.pumpWidget(panel(
        state: const NikoRemoteResolution(
            current: fit,
            original: original,
            capturedPixels: NikoDisplayMode(3840, 2160),
            fit: fit),
        auto: true,
        change: (mode) async => requested.add(mode),
        setAuto: (_) async {}));
    expect(enabled(tester, 'nikodesk-resolution-fit'), isFalse);
    final restore = find.byKey(const Key('nikodesk-resolution-original'));
    await tester.ensureVisible(restore);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(requested, [original]);
  });

  testWidgets('unknown display state disables both actions and explains why',
      (tester) async {
    await tester.pumpWidget(
        panel(auto: null, change: (_) async {}, setAuto: (_) async {}));
    expect(enabled(tester, 'nikodesk-resolution-fit'), isFalse);
    expect(enabled(tester, 'nikodesk-resolution-original'), isFalse);
    expect(find.textContaining('需要键鼠权限'), findsOneWidget);
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const Key('nikodesk-resolution-auto')))
            .onChanged,
        isNull);
  });

  testWidgets('an unreadable local screen is explained, not called a best fit',
      (tester) async {
    await tester.pumpWidget(panel(
        state: const NikoRemoteResolution(
            current: original,
            original: original,
            capturedPixels: NikoDisplayMode(5120, 2880),
            fit: null,
            localLongEdge: 0),
        auto: false,
        change: (_) async {},
        setAuto: (_) async {}));
    expect(find.textContaining('未能读取本机屏幕尺寸'), findsOneWidget);
    expect(find.textContaining('没有更小且仍能填满'), findsNothing);
    expect(enabled(tester, 'nikodesk-resolution-fit'), isFalse);
  });

  testWidgets('a failed request reports failure instead of success',
      (tester) async {
    await tester.pumpWidget(panel(
        state: const NikoRemoteResolution(
            current: original,
            original: original,
            capturedPixels: NikoDisplayMode(5120, 2880),
            fit: fit),
        auto: false,
        change: (_) async => throw StateError('Remote display unavailable'),
        setAuto: (_) async {}));
    final match = find.byKey(const Key('nikodesk-resolution-fit'));
    await tester.ensureVisible(match);
    await tester.tap(match);
    await tester.pumpAndSettle();
    expect(find.textContaining('未能确认分辨率请求'), findsOneWidget);
    expect(find.textContaining('已请求远端切换分辨率'), findsNothing);
  });

  testWidgets('choosing a picture size sends it and reports the result',
      (tester) async {
    final chosen = <NikoCaptureMode>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoSessionQuickActionsPanel(
      peerPlatform: 'Mac OS',
      keyboardAllowed: true,
      canvasAllowed: true,
      viewStyle: 'adaptive',
      onShortcut: (_) async {},
      onViewStyle: (_) async {},
      captureMode: NikoCaptureMode.fit,
      onCaptureMode: (mode) async => chosen.add(mode),
      onClose: () {},
    ))));
    final dropdown = find.byKey(const Key('nikodesk-capture-mode'));
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('更小').last);
    await tester.pumpAndSettle();
    expect(chosen, [NikoCaptureMode.small]);
    expect(find.textContaining('已请求并按设备保存'), findsOneWidget);
  });

  testWidgets('the picture size choice is absent without a desktop session',
      (tester) async {
    await tester.pumpWidget(panel());
    expect(find.byKey(const Key('nikodesk-capture-mode')), findsNothing);
  });

  testWidgets('the per-device switch saves the new value', (tester) async {
    final saved = <bool>[];
    await tester.pumpWidget(panel(
        state: const NikoRemoteResolution(
            current: original,
            original: original,
            capturedPixels: NikoDisplayMode(5120, 2880),
            fit: fit),
        auto: false,
        change: (_) async {},
        setAuto: (value) async => saved.add(value)));
    final toggle = find.byKey(const Key('nikodesk-resolution-auto'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(saved, [true]);
    expect(find.textContaining('下次连接这台设备时生效'), findsOneWidget);
  });
}
