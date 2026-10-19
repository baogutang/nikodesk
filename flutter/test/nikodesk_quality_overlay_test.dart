import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/connection_progress.dart';
import 'package:flutter_hbb/nikodesk/metrics.dart';
import 'package:flutter_hbb/nikodesk/quality_overlay.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'nikodesk_native_metrics_test.dart' as native_fixture;

void main() {
  setUp(() => NikoLanguage.english = true);

  testWidgets('zero decoded callback FPS retains an independent measured RTT',
      (tester) async {
    final metrics = SessionMetrics()
      ..update({
        'fps': '{"0":0}',
        'delay': '63',
        'target_bitrate': '1280',
      });
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: NikoQualityOverlay(metrics: metrics, display: 0))));
    expect(find.text('0 fps'), findsOneWidget);
    expect(find.text('63 ms'), findsOneWidget);
    expect(find.text('1280 kbps'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stale and disconnected samples cannot appear current',
      (tester) async {
    var tick = Duration.zero;
    final metrics = SessionMetrics(tick: () => tick)..update({'delay': '37'});
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NikoQualityOverlay(metrics: metrics))));
    expect(find.text('37 ms'), findsOneWidget);
    tick = const Duration(seconds: 11);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('37 ms'), findsNothing);
    expect(find.text('Expired'), findsOneWidget);
    metrics.clear();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Expired'), findsNothing);
    // 13 live samples, 4 connection rows and 5 controlled-side rows.
    expect(find.text('Unknown'), findsNWidgets(22));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('connection route and step timings are shown once known',
      (tester) async {
    final metrics = SessionMetrics()
      ..connection(secure: true, direct: false, transport: 'TCP')
      ..setup = const NikoConnectionTimings(
          transport: Duration(milliseconds: 180),
          authentication: Duration(milliseconds: 95),
          userWait: Duration(seconds: 4),
          firstFrame: Duration(milliseconds: 240));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NikoQualityOverlay(metrics: metrics))));
    expect(find.text('Relay · TCP'), findsOneWidget);
    expect(find.text('180 ms'), findsOneWidget);
    expect(find.text('95 ms (+4000 ms waiting for input/approval)'),
        findsOneWidget);
    expect(find.text('240 ms'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the controlled side section shows its numbers and the ceiling',
      (tester) async {
    final metrics = SessionMetrics()
      ..hostVideo(jsonEncode({
        'display': 0,
        'width': 3200,
        'height': 1800,
        'encoder': 'H265',
        'hardware': true,
        'fps': 54.2,
        'limit': 120.0,
        'refreshHz': 75.0,
        'captureMs': 3.1,
        'convertMs': 2.6,
        'encodeMs': 0.8,
        'captureIncludesWait': false,
      }));
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: NikoQualityOverlay(metrics: metrics, display: 0))));
    expect(find.text('3200×1800 · H265 hardware'), findsOneWidget);
    expect(find.text('54.2/s'), findsOneWidget);
    expect(find.text('75 Hz'), findsOneWidget);
    expect(
        find.text('capture 3.1 · convert 2.6 · encode 0.8 ms'), findsOneWidget);
    expect(find.text('75/s (controlled display refresh rate)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a display without a sample stays unknown at large text size',
      (tester) async {
    final metrics = SessionMetrics()..update({'fps': '{"1":60}'});
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: Scaffold(body: NikoQualityOverlay(metrics: metrics, display: 0)),
    )));
    expect(find.text('60 fps'), findsNothing);
    // 13 live samples, 4 connection rows and 5 controlled-side rows.
    expect(find.text('Unknown'), findsNWidgets(22));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('bounded native values stay readable at 320px and 200% text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final metrics = native_fixture.ready();
    expect(
        metrics.updateNative(jsonEncode(native_fixture.snapshot()),
            jsonEncode(native_fixture.authority()), native_fixture.scope),
        isTrue);
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: const MediaQueryData(
          size: Size(320, 640), textScaler: TextScaler.linear(2)),
      child: Scaffold(body: NikoQualityOverlay(metrics: metrics, display: 0)),
    )));
    expect(find.text('Decoded callback FPS'), findsOneWidget);
    expect(find.text('vpx-vp9'), findsOneWidget);
    expect(find.text('No'), findsOneWidget);
    expect(find.text('1.20 ms'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -500));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
