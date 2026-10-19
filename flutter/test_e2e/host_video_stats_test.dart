// The controlled side's own video measurements reach the controller about
// once a second, with plausible values. Prints every report so a run with a
// moving picture (scripts/e2e-motion.swift) doubles as a stage-time baseline.
// Frame counts depend on how much the controlled screen changes; nothing here
// is a frame-rate threshold.
import 'dart:io';

import 'package:flutter_hbb/nikodesk/metrics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('controlled-side video stats arrive once a second', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final seconds =
        int.parse(Platform.environment['NIKODESK_E2E_SECONDS'] ?? '12');
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'));
    addTearDown(session.close);
    await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await session.until(() => session.frames > 0, 'first decoded frame');
    // Optional baseline settings: NIKODESK_E2E_FPS and NIKODESK_E2E_CAPTURE_WIDTH.
    final fps = Platform.environment['NIKODESK_E2E_FPS'] ?? '';
    if (fps.isNotEmpty) {
      await native.bind
          .sessionSetCustomFps(sessionId: session.id, fps: int.parse(fps));
    }
    final width = Platform.environment['NIKODESK_E2E_CAPTURE_WIDTH'] ?? '';
    if (width.isNotEmpty) {
      await native.bind.sessionPeerOption(
          sessionId: session.id, name: 'nikodesk-capture-width', value: width);
      addTearDown(() => native.bind.sessionPeerOption(
          sessionId: session.id, name: 'nikodesk-capture-width', value: ''));
    }
    if (fps.isNotEmpty || width.isNotEmpty) {
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    final start = session.events.length;
    await Future<void>.delayed(Duration(seconds: seconds));

    final reports = session.events
        .skip(start)
        .where((event) => event['name'] == 'niko_host_video')
        .map((event) => NikoHostVideo.parse(event['stats']))
        .toList();
    for (final report in reports) {
      // ignore: avoid_print
      print('E2E-HOST-VIDEO ${report == null ? 'invalid' : [
          '${report.width}x${report.height}',
          '${report.encoder} ${report.hardware ? 'hw' : 'sw'}',
          'fps=${report.fps}',
          'limit=${report.limit}',
          'refresh=${report.refreshHz}',
          'capture=${report.captureMs}',
          'convert=${report.convertMs}',
          'encode=${report.encodeMs}',
          'wait=${report.captureIncludesWait}',
          'processingMax=${report.processingMaxFps?.round()}',
        ].join(' ')}');
    }
    // ignore: avoid_print
    print('E2E-HOST-VIDEO-DEBUG ${session.summary()}');
    expect(reports, isNotEmpty, reason: 'no controlled-side report arrived');
    expect(reports, everyElement(isNotNull));
    // About one report a second, allowing for start-up and a capture restart.
    expect(reports.length, greaterThanOrEqualTo(seconds ~/ 2));
    final last = reports.last!;
    expect(last.width, greaterThan(0));
    expect(last.limit, isNotNull);
    if (Platform.isMacOS) {
      expect(last.captureIncludesWait, isFalse);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
