// Fits the controlled display to a smaller controller on a real session, with
// the mode chosen by the production picker, and checks that the controlled
// side really sends fewer pixels and puts its display back once the
// controller leaves. Frame counts are printed, never asserted: they depend on
// how much the controlled screen changes.
//
// This changes the resolution of the display this test runs on for the
// duration of the session.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/remote_resolution_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

typedef _Display = ({int width, int height, int originalWidth, int originalHeight, double scale});

_Display _display(Map<String, dynamic> peerInfo) {
  final display = (jsonDecode(peerInfo['displays'] as String) as List).first
      as Map<String, dynamic>;
  final width = display['width'] as int;
  final scaled = int.tryParse('${display['scaled_width']}') ?? width;
  return (
    width: width,
    height: display['height'] as int,
    originalWidth: display['original_width'] as int,
    originalHeight: display['original_height'] as int,
    scale: scaled > 0 && width > scaled ? width / scaled : 1.0,
  );
}

void main() {
  test('fitting a smaller controller sends fewer pixels and is undone on exit',
      () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    // The controller's screen: a 4K monitor unless the run says otherwise.
    final localLongEdge =
        int.parse(Platform.environment['NIKODESK_E2E_LOCAL_EDGE'] ?? '3840');
    final seconds =
        int.parse(Platform.environment['NIKODESK_E2E_SECONDS'] ?? '8');
    final password = env('NIKODESK_E2E_HOST_PASSWORD');

    var session = await NikoSession.open(native, host, password: password);
    var closed = false;
    addTearDown(() async {
      if (!closed) await session.close();
    });
    final info = await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await session.until(() => session.frames > 0, 'first decoded frame');
    // The picture mode is saved per device; an earlier run may have left the
    // weak-network preset behind, which caps the stream at 15 frames a second.
    await native.bind
        .sessionSetImageQuality(sessionId: session.id, value: 'balanced');
    final before = _display(info);
    final modes = [
      for (final mode in jsonDecode(info['resolutions'] as String) as List)
        NikoDisplayMode(mode['width'] as int, mode['height'] as int)
    ];
    // The same state the control center builds from the reported display.
    final state = nikoResolutionState(
        width: before.width,
        height: before.height,
        originalWidth: before.originalWidth,
        originalHeight: before.originalHeight,
        scale: before.scale,
        supported: modes,
        localLongEdge: localLongEdge);
    final fit = state.fit;
    // ignore: avoid_print
    print('E2E-RESOLUTION original=${state.original.label} '
        'captured=${before.width}x${before.height} scale=${before.scale} '
        'modes=${modes.length} local_edge=$localLongEdge fit=${fit?.label}');
    expect(state.changed, isFalse,
        reason: 'the controlled display must start in its original mode');
    expect(fit, isNotNull,
        reason: 'this display offers no smaller mode for a $localLongEdge px '
            'controller; run on a display that does');

    Future<double> framesPerSecond(String label) async {
      await Future<void>.delayed(const Duration(seconds: 3));
      final start = session.frames;
      await Future<void>.delayed(Duration(seconds: seconds));
      final fps = (session.frames - start) / seconds;
      // ignore: avoid_print
      print('E2E-RESOLUTION $label decoded_fps=${fps.toStringAsFixed(1)} '
          'quality=${session.quality()}');
      return fps;
    }

    await framesPerSecond('original');
    final switches = session.named('switch_display').length;
    await native.bind.sessionChangeResolution(
        sessionId: session.id, display: 0, width: fit!.width, height: fit.height);
    await session.until(
        () => session.named('switch_display').length > switches,
        'the controlled side reporting its new display');
    final changed = session.named('switch_display').last;
    final width = int.parse('${changed['width']}');
    final height = int.parse('${changed['height']}');
    // ignore: avoid_print
    print('E2E-RESOLUTION fitted captured=${width}x$height');
    expect(width * height, lessThan(before.width * before.height),
        reason: 'the fitted mode must capture fewer pixels');
    expect(width, greaterThanOrEqualTo(localLongEdge),
        reason: 'the fitted mode must still fill the controller');
    expect(int.parse('${changed['original_width']}'), before.originalWidth,
        reason: 'the controlled side must still know its original mode');
    expect(
        nikoFitReducedPixels(
            before: state.capturedPixels,
            after: NikoDisplayMode(width, height),
            localLongEdge: localLongEdge),
        isTrue);
    expect(
        nikoResolutionState(
                width: width,
                height: height,
                originalWidth: before.originalWidth,
                originalHeight: before.originalHeight,
                scale: before.scale,
                supported: modes,
                localLongEdge: localLongEdge)
            .current,
        fit,
        reason: 'the control center must show the fitted mode as current');
    await framesPerSecond('fitted');

    await session.close();
    closed = true;
    // The controlled side restores its display when the last controller leaves.
    await Future<void>.delayed(const Duration(seconds: 4));
    session = await NikoSession.open(native, host, password: password);
    closed = false;
    final again = _display(await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after reconnect'));
    // ignore: avoid_print
    print('E2E-RESOLUTION after-reconnect captured=${again.width}x${again.height}');
    expect((again.width, again.height), (before.width, before.height),
        reason: 'the controlled display was not restored after disconnect');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
