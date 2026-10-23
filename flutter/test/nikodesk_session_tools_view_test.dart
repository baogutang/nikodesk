import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/metrics.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/session_sheet.dart';
import 'package:flutter_hbb/nikodesk/session_tools_view.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

void main() {
  tearDown(() => NikoLanguage.english = false);

  // Layout and callback fixtures only; no session or native call starts.
  Widget host(Widget panel, {double textScale = 1}) => MaterialApp(
      theme: nikoTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: Scaffold(body: NikoSessionSheet(onCancel: () {}, child: panel)));

  Widget picture(
          {PictureMode mode = PictureMode.smooth,
          bool loading = false,
          bool saving = false,
          bool supportsFps = true,
          ValueChanged<PictureMode>? onMode,
          ValueChanged<double>? onFps,
          VoidCallback? onApply,
          VoidCallback? onClose}) =>
      NikoPictureModePanel(
          loading: loading,
          saving: saving,
          mode: mode,
          onMode: onMode ?? (_) {},
          smoothFps: 120,
          quality: 50,
          onQuality: (_) {},
          fps: 30,
          onFps: onFps ?? (_) {},
          supportsFps: supportsFps,
          currentQuality: 'custom',
          currentFps: '120',
          onApply: onApply ?? () {},
          onClose: onClose ?? () {});

  testWidgets('picture modes pick, apply and close', (tester) async {
    NikoLanguage.english = true;
    final semantics = tester.ensureSemantics();
    final calls = <String>[];
    await tester.pumpWidget(host(picture(
        onMode: (mode) => calls.add(mode.name),
        onApply: () => calls.add('apply'),
        onClose: () => calls.add('close'))));
    await tester.pumpAndSettle();
    // The dark session theme applies in a light app.
    expect(
        NlColors.of(tester.element(find.text('Picture mode'))).isDark, isTrue);
    final smooth = find.byKey(const ValueKey('nikodesk-picture-smooth'));
    expect(
        tester
            .getSemantics(smooth)
            .getSemanticsData()
            .hasFlag(SemanticsFlag.isSelected),
        isTrue);
    expect(find.textContaining('120 here'), findsOneWidget);
    expect(find.byKey(const Key('nikodesk-picture-quality')), findsNothing);
    expect(find.text('custom · 120 FPS'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nikodesk-picture-office')));
    await tester.tap(find.byKey(const Key('nikodesk-picture-apply')));
    await tester.tap(find.byKey(const Key('nikodesk-picture-close')));
    expect(calls, ['office', 'apply', 'close']);
    semantics.dispose();
  });

  testWidgets('custom mode shows its sliders; FPS waits for peer support',
      (tester) async {
    NikoLanguage.english = true;
    final fps = <double>[];
    await tester.pumpWidget(host(
        picture(mode: PictureMode.custom, supportsFps: false, onFps: fps.add)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nikodesk-picture-quality')), findsOneWidget);
    final slider = find.byKey(const Key('nikodesk-picture-fps'));
    await tester.ensureVisible(slider);
    expect(tester.widget<Slider>(slider).onChanged, isNull);
    expect(find.textContaining('custom FPS will not be sent'), findsOneWidget);
    expect(fps, isEmpty);
  });

  testWidgets('loading and saving hold the controls', (tester) async {
    NikoLanguage.english = true;
    final calls = <String>[];
    await tester.pumpWidget(host(picture(
        loading: true,
        onApply: () => calls.add('apply'),
        onClose: () => calls.add('close'))));
    await tester.pump();
    expect(find.byType(NlSpinner), findsWidgets);
    expect(find.byKey(const ValueKey('nikodesk-picture-office')), findsNothing);
    await tester.tap(find.byKey(const Key('nikodesk-picture-apply')));
    await tester.tap(find.byKey(const Key('nikodesk-picture-close')));
    expect(calls, ['close']);

    await tester.pumpWidget(host(picture(
        saving: true,
        onMode: (mode) => calls.add(mode.name),
        onApply: () => calls.add('apply'),
        onClose: () => calls.add('close'))));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nikodesk-picture-office')));
    await tester.tap(find.byKey(const Key('nikodesk-picture-apply')));
    await tester.tap(find.byKey(const Key('nikodesk-picture-close')));
    expect(calls, ['close']);
  });

  Widget diagnostics(SessionMetrics metrics,
          {bool? sampling = true,
          List<String>? calls,
          String? feedback,
          NlTone tone = NlTone.accent}) =>
      NikoDiagnosticsPanel(
          metrics: metrics,
          sampling: sampling,
          onSampling: (value) => calls?.add('sampling $value'),
          onReloadSampling: () => calls?.add('reload'),
          resolutions: const [(2560, 1440)],
          scale: 1,
          feedback: feedback,
          feedbackTone: tone,
          onExport: () => calls?.add('export'),
          onClose: () => calls?.add('close'));

  testWidgets('diagnostics show measured values with their limits',
      (tester) async {
    NikoLanguage.english = true;
    final metrics = SessionMetrics()
      ..connection(secure: true, direct: false, transport: 'TCP')
      ..update({'delay': '24', 'codec_format': 'h265', 'fps': '{"0":59}'})
      ..hostVideo(jsonEncode({
        'display': 0,
        'width': 2560,
        'height': 1440,
        'encoder': 'H265',
        'hardware': true,
        'fps': 59.6,
        'captureMs': 4.12,
        'convertMs': 1.2,
        'encodeMs': 3.4,
      }));
    await tester.pumpWidget(host(diagnostics(metrics)));
    await tester.pumpAndSettle();
    expect(find.text('Relay · TCP'), findsOneWidget);
    expect(find.text('Encrypted per core event'), findsOneWidget);
    expect(find.text('24 ms'), findsOneWidget);
    expect(find.text('Display 1: 59 fps'), findsOneWidget);
    expect(find.text('H265'), findsOneWidget);
    // Never "Instance of", nor a unit after an unknown value.
    expect(
        find.text('Display 1: 2560×1440 · H265 hardware · 60/s · '
            'capture 4.1 · convert 1.2 · encode 3.4 ms'),
        findsOneWidget);
    expect(find.textContaining('Instance of'), findsNothing);
    expect(find.text('Unknown KiB/s'), findsNothing);
    expect(find.text('Unknown'), findsWidgets);
  });

  testWidgets('diagnostics sampling, reload, export and close', (tester) async {
    NikoLanguage.english = true;
    final calls = <String>[];
    await tester.pumpWidget(host(diagnostics(SessionMetrics(),
        calls: calls,
        feedback: 'Export failed. Choose a writable location and retry.',
        tone: NlTone.danger)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nikodesk-diagnostics-sampling')));
    expect(find.text('Sampling state unknown.'), findsNothing);
    await tester.tap(find.byKey(const Key('nikodesk-diagnostics-export')));
    await tester.tap(find.byKey(const Key('nikodesk-diagnostics-close')));
    expect(calls, ['sampling false', 'export', 'close']);
    expect(find.text('Export failed. Choose a writable location and retry.'),
        findsOneWidget);

    calls.clear();
    await tester.pumpWidget(
        host(diagnostics(SessionMetrics(), sampling: null, calls: calls)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nikodesk-diagnostics-sampling')));
    await tester.tap(find.text('Reload'));
    expect(calls, ['reload']);
  });

  testWidgets('ended session offers only closing', (tester) async {
    var closed = false;
    await tester.pumpWidget(host(
        NikoSessionToolEnded(title: '画面模式', onClose: () => closed = true)));
    await tester.pumpAndSettle();
    expect(find.text('此会话已结束，请关闭面板。'), findsOneWidget);
    await tester.tap(find.byType(NlIconButton));
    expect(closed, isTrue);
  });

  // A phone, where the panel is a bottom sheet, and a small window, where
  // it floats.
  for (final size in const [Size(320, 640), Size(640, 400)]) {
    for (final english in [false, true]) {
      testWidgets(
          'panels fit ${size.width.toInt()}x${size.height.toInt()} '
          'at 200% text ($english)', (tester) async {
        NikoLanguage.english = english;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        for (final panel in [
          picture(mode: PictureMode.custom, supportsFps: false),
          diagnostics(
              SessionMetrics()
                ..connection(
                    secure: true, direct: false, transport: 'WebSocket'),
              feedback: 'Export failed. Choose a writable location and retry.',
              tone: NlTone.danger),
        ]) {
          await tester.pumpWidget(host(panel, textScale: 2));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
