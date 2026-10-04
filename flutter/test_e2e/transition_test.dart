// Observes how evenly frames arrive while the controlled screen goes through
// repeated whole-picture transitions (a moving-picture source run on the
// controlled side; it lives in the development workspace, not here). Nothing here is a pass threshold; the printed numbers are
// the result. Settings come from the environment:
//   NIKODESK_E2E_QUALITY   balanced (default) | best | custom:<percent>:<fps>
//   NIKODESK_E2E_FIT       1 to match the controlled display to a controller
//                          NIKODESK_E2E_LOCAL_EDGE pixels wide first
//   NIKODESK_E2E_SECONDS   observation length, default 20
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/remote_resolution_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

int _percentile(List<int> sorted, double p) =>
    sorted.isEmpty ? -1 : sorted[((sorted.length - 1) * p).round()];

void main() {
  test('observe frame pacing through screen transitions', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final seconds =
        int.parse(Platform.environment['NIKODESK_E2E_SECONDS'] ?? '20');
    final quality = Platform.environment['NIKODESK_E2E_QUALITY'] ?? 'balanced';
    final fit = Platform.environment['NIKODESK_E2E_FIT'] == '1';
    final localEdge =
        int.parse(Platform.environment['NIKODESK_E2E_LOCAL_EDGE'] ?? '3840');

    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'));
    addTearDown(session.close);
    // The picture mode is saved per device; always leave the default behind.
    addTearDown(() => native.bind
        .sessionSetImageQuality(sessionId: session.id, value: 'balanced'));
    final info = await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await session.until(() => session.frames > 0, 'first decoded frame');

    if (quality.startsWith('custom:')) {
      final parts = quality.split(':');
      await native.bind
          .sessionSetImageQuality(sessionId: session.id, value: 'custom');
      await native.bind.sessionSetCustomImageQuality(
          sessionId: session.id, value: int.parse(parts[1]));
      await native.bind
          .sessionSetCustomFps(sessionId: session.id, fps: int.parse(parts[2]));
    } else {
      await native.bind
          .sessionSetImageQuality(sessionId: session.id, value: quality);
    }

    final display = (jsonDecode(info['displays'] as String) as List).first
        as Map<String, dynamic>;
    var captured = '${display['width']}x${display['height']}';
    // NIKODESK_E2E_CAPTURE_WIDTH scales the capture without a mode change.
    final captureWidth = Platform.environment['NIKODESK_E2E_CAPTURE_WIDTH'] ?? '';
    await native.bind.sessionPeerOption(
        sessionId: session.id,
        name: 'nikodesk-capture-width',
        value: captureWidth.isEmpty ? '65535' : captureWidth);
    addTearDown(() => native.bind.sessionPeerOption(
        sessionId: session.id, name: 'nikodesk-capture-width', value: ''));
    if (captureWidth.isNotEmpty) {
      await Future<void>.delayed(const Duration(seconds: 3));
      final reported = session.events.lastWhere(
          (event) =>
              event['name'] == 'switch_display' ||
              (event['name'] == 'sync_peer_info' && event['displays'] is String),
          orElse: () => info);
      final now = reported['displays'] is String
          ? (jsonDecode(reported['displays'] as String) as List).first
          : reported;
      captured = '${now['width']}x${now['height']}';
    }
    if (fit) {
      final width = display['width'] as int;
      final scaled = int.tryParse('${display['scaled_width']}') ?? width;
      final state = nikoResolutionState(
          width: width,
          height: display['height'] as int,
          originalWidth: display['original_width'] as int,
          originalHeight: display['original_height'] as int,
          scale: scaled > 0 && width > scaled ? width / scaled : 1.0,
          supported: [
            for (final mode
                in jsonDecode(info['resolutions'] as String) as List)
              NikoDisplayMode(mode['width'] as int, mode['height'] as int)
          ],
          localLongEdge: localEdge);
      final mode = state.fit;
      expect(mode, isNotNull, reason: 'no smaller mode fits this controller');
      final switches = session.named('switch_display').length;
      await native.bind.sessionChangeResolution(
          sessionId: session.id,
          display: 0,
          width: mode!.width,
          height: mode.height);
      await session.until(
          () => session.named('switch_display').length > switches,
          'the controlled side reporting its new display');
      final changed = session.named('switch_display').last;
      captured = '${changed['width']}x${changed['height']}';
    }
    // Let the stream settle and the frame rate ramp up before sampling.
    await Future<void>.delayed(const Duration(seconds: 6));

    final arrivals = <int>[];
    final clock = Stopwatch()..start();
    var last = session.frames;
    final firstStatus = session.named('update_quality_status').length;
    while (clock.elapsed < Duration(seconds: seconds)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      if (session.frames != last) {
        arrivals.add(clock.elapsedMicroseconds);
        last = session.frames;
      }
    }
    final intervals = [
      for (var i = 1; i < arrivals.length; i++)
        (arrivals[i] - arrivals[i - 1]) ~/ 1000
    ]..sort();
    final delays = session
        .named('update_quality_status')
        .skip(firstStatus)
        .map((event) => int.tryParse('${event['delay']}'))
        .whereType<int>()
        .toList()
      ..sort();
    int over(int ms) => intervals.where((gap) => gap > ms).length;
    expect(arrivals, isNotEmpty, reason: 'no frames during the observation');
    // ignore: avoid_print
    print('E2E-TRANSITION quality=$quality fit=$fit captured=$captured '
        'seconds=$seconds decoded_fps=${(arrivals.length / seconds).toStringAsFixed(1)} '
        'interval_ms p50=${_percentile(intervals, 0.5)} p95=${_percentile(intervals, 0.95)} '
        'p99=${_percentile(intervals, 0.99)} max=${intervals.isEmpty ? -1 : intervals.last} '
        'gaps >100ms=${over(100)} >250ms=${over(250)} >500ms=${over(500)} '
        'delay_ms p50=${_percentile(delays, 0.5)} max=${delays.isEmpty ? -1 : delays.last} '
        'last=${session.quality()}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
