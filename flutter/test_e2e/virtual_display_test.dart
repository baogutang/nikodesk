// A virtual display requested with the controller's screen is created at that
// screen's pixels, scale and refresh rate, streams at that size, and is gone
// after removal. This adds a display to this Mac for about half a minute.
// NIKODESK_E2E_SCREEN="width height scaleMilli refreshMilliHz" sets the
// simulated controller; the default is a 14-inch MacBook Pro.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_hbb/nikodesk/metrics.dart';
import 'package:flutter_hbb/nikodesk/virtual_display.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

/// The current mode of each NikoDesk virtual display:
/// "width height pixelWidth pixelHeight refresh".
Future<List<String>> nikoVirtualDisplayModes() async {
  final result = await Process.run('swift', [
    '-e',
    'import CoreGraphics; '
        'var ids = [CGDirectDisplayID](repeating: 0, count: 32); var n: UInt32 = 0; '
        'CGGetOnlineDisplayList(32, &ids, &n); '
        'for id in ids.prefix(Int(n)) where CGDisplayVendorNumber(id) == 0x4e49 { '
        'guard let m = CGDisplayCopyDisplayMode(id) else { continue }; '
        'print(m.width, m.height, m.pixelWidth, m.pixelHeight, Int(m.refreshRate.rounded())) }'
  ]);
  if (result.exitCode != 0) throw StateError('display list: ${result.stderr}');
  return const LineSplitter()
      .convert('${result.stdout}')
      .where((line) => line.isNotEmpty)
      .toList();
}

NikoVirtualDisplays? latestScreens(NikoSession session) {
  for (final event in session.events.reversed) {
    final raw = event['platform_additions'];
    if (raw is! String || raw.isEmpty) continue;
    final additions = jsonDecode(raw) as Map<String, dynamic>;
    if (additions.containsKey('nikodesk_virtual_display')) {
      return NikoVirtualDisplays.parse(additions['nikodesk_virtual_display']);
    }
  }
  return null;
}

List<dynamic> latestDisplays(NikoSession session) {
  for (final event in session.events.reversed) {
    if (event['name'] == 'sync_peer_info' && event['displays'] != null) {
      return jsonDecode('${event['displays']}') as List<dynamic>;
    }
    if (event['name'] == 'peer_info') {
      return jsonDecode('${event['displays']}') as List<dynamic>;
    }
  }
  return const [];
}

void main() {
  test('a virtual display is made to the controller screen', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final screen =
        (Platform.environment['NIKODESK_E2E_SCREEN'] ?? '3024 1964 2000 120000')
            .split(' ')
            .map(int.parse)
            .toList();
    expect(await nikoVirtualDisplayModes(), isEmpty,
        reason: 'a NikoDesk virtual display already exists');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'));
    addTearDown(session.close);
    await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await session.until(() => session.frames > 0, 'first decoded frame');
    final before = latestScreens(session);
    expect(before, isNotNull, reason: 'the host reports no virtual displays');
    expect(before!.supported, isTrue);
    expect(before.allowed, isTrue, reason: 'the host setup allows them');
    final displaysBefore = latestDisplays(session).length;

    await native.bind.sessionToggleNikodeskVirtualDisplay(
        sessionId: session.id,
        index: 1,
        on: true,
        width: screen[0],
        height: screen[1],
        scaleMilli: screen[2],
        refreshMilliHz: screen[3]);
    addTearDown(() => native.bind.sessionToggleNikodeskVirtualDisplay(
        sessionId: session.id,
        index: -1,
        on: false,
        width: 0,
        height: 0,
        scaleMilli: 0,
        refreshMilliHz: 0));
    await session.until(
        () => latestScreens(session)?.active.contains(1) ?? false,
        'virtual display 1 active');
    final modes = await nikoVirtualDisplayModes();
    await session.until(() => latestDisplays(session).length > displaysBefore,
        'the new display in the display list');
    final displays = latestDisplays(session);
    // ignore: avoid_print
    print('E2E-VIRTUAL-DISPLAY requested=${screen.join(' ')} modes=$modes '
        'displays=${displays.map((d) => '${d['width']}x${d['height']}').toList()}');
    expect(modes, hasLength(1));
    final hidpi = screen[2] >= 1500 &&
        (screen[0] < screen[1] ? screen[0] : screen[1]) ~/ 2 >= 720;
    final refresh = ((screen[3] + 500) ~/ 1000).clamp(30, 120);
    final pixels = '${screen[0] & ~1} ${screen[1] & ~1}';
    final logical =
        hidpi ? '${(screen[0] & ~1) ~/ 2} ${(screen[1] & ~1) ~/ 2}' : pixels;
    expect(modes.single, '$logical $pixels $refresh');

    // Stream the new display with a moving picture on it.
    final index = displays.length - 1;
    await native.bind.sessionSetCustomFps(sessionId: session.id, fps: 120);
    await native.bind.sessionSwitchDisplay(
        isDesktop: true,
        sessionId: session.id,
        value: Int32List.fromList([index]));
    final seconds =
        int.parse(Platform.environment['NIKODESK_E2E_SECONDS'] ?? '20');
    final motion = await Process.start('swift', [
      '${Directory.current.path}/../../scripts/e2e-motion.swift',
      '${seconds + 4}',
      '1400',
      '860'
    ], environment: {
      'NIKODESK_MOTION_SCREEN': 'NikoDesk Virtual'
    });
    addTearDown(motion.kill);
    final motionOutput = StringBuffer();
    motion.stdout.transform(utf8.decoder).listen(motionOutput.write);
    motion.stderr.transform(utf8.decoder).listen(motionOutput.write);
    // The script compiles before it draws.
    await Future<void>.delayed(const Duration(seconds: 4));
    final start = session.events.length;
    await Future<void>.delayed(Duration(seconds: seconds));
    await motion.exitCode
        .timeout(const Duration(seconds: 10), onTimeout: () => -1);
    // ignore: avoid_print
    print('E2E-VIRTUAL-MOTION ${motionOutput.toString().trim()}');
    final reports = session.events
        .skip(start)
        .where((event) => event['name'] == 'niko_host_video')
        .map((event) => NikoHostVideo.parse(event['stats']))
        .whereType<NikoHostVideo>()
        .where((report) => report.width == screen[0] & ~1)
        .toList();
    for (final report in reports) {
      // ignore: avoid_print
      print('E2E-VIRTUAL-VIDEO ${report.width}x${report.height} '
          '${report.encoder} ${report.hardware ? 'hw' : 'sw'} fps=${report.fps} '
          'limit=${report.limit} refresh=${report.refreshHz} '
          'capture=${report.captureMs} convert=${report.convertMs} '
          'encode=${report.encodeMs}');
    }
    // ignore: avoid_print
    print('E2E-VIRTUAL-DEBUG ${session.summary()}');
    expect(reports, isNotEmpty, reason: 'the new display was not streamed');
    expect(reports.last.refreshHz?.round(), refresh);
    // The moving picture must come through, not a few repeated frames.
    final best = reports
        .map((report) => report.fps ?? 0)
        .reduce((a, b) => a > b ? a : b);
    expect(best, greaterThan(20), reason: 'the virtual display looks frozen');

    await native.bind.sessionToggleNikodeskVirtualDisplay(
        sessionId: session.id,
        index: 1,
        on: false,
        width: 0,
        height: 0,
        scaleMilli: 0,
        refreshMilliHz: 0);
    await session.until(
        () => !(latestScreens(session)?.active.contains(1) ?? true),
        'virtual display 1 removed');
    expect(await nikoVirtualDisplayModes(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
