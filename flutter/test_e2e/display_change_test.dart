// Times how quickly the controlled side follows display changes: switching
// the streamed display, and changing a virtual display's resolution (this
// Mac's own screen keeps its mode). Adds a display to this Mac for about a
// minute. Nothing here is a pass threshold; the printed times are the
// result. Run with NIKODESK_E2E_DISPLAY_EVENTS=N (read by the host setup) for
// the periodic display check alone, to compare.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';
import 'virtual_display_test.dart' show latestDisplays, nikoVirtualDisplayModes;

DateTime? _firstFrameAfter(NikoSession session, int display, DateTime after) {
  for (final mark in session.frameLog) {
    if (mark.display == display && mark.at.isAfter(after)) return mark.at;
  }
  return null;
}

/// When the controller was told display [display] is [width] wide, counting
/// only events after [from].
DateTime? _noticeAfter(NikoSession session, int from, int display, int width) {
  for (var i = from; i < session.events.length; i++) {
    final event = session.events[i];
    if (event['name'] == 'switch_display' &&
        '${event['display']}' == '$display' &&
        '${event['width']}' == '$width') {
      return session.eventTimes[i];
    }
  }
  return null;
}

void main() {
  test('display switches and resolution changes are followed', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    expect(await nikoVirtualDisplayModes(), isEmpty,
        reason: 'a NikoDesk virtual display already exists');
    final events = Platform.environment['NIKODESK_E2E_DISPLAY_EVENTS'] ?? 'Y';
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'));
    addTearDown(session.close);
    await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await session.until(() => session.frames > 0, 'first decoded frame');
    final displaysBefore = latestDisplays(session).length;

    // Without a screen description the display gets the fixed modes
    // 1920x1080, 2560x1440 and 3840x2160, all at 1x.
    await native.bind
        .sessionToggleVirtualDisplay(sessionId: session.id, index: 1, on: true);
    addTearDown(() => native.bind.sessionToggleVirtualDisplay(
        sessionId: session.id, index: -1, on: false));
    await session.until(() => latestDisplays(session).length > displaysBefore,
        'the virtual display in the display list');
    final index = latestDisplays(session).length - 1;

    Future<int> switchTo(int display) async {
      final start = DateTime.now();
      await native.bind.sessionSwitchDisplay(
          isDesktop: true,
          sessionId: session.id,
          value: Int32List.fromList([display]));
      await session.until(
          () => _firstFrameAfter(session, display, start) != null,
          'a frame from display $display');
      return _firstFrameAfter(session, display, start)!
          .difference(start)
          .inMilliseconds;
    }

    await switchTo(index);
    final switches = <String>[];
    for (var round = 0; round < 3; round++) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      switches.add('to0=${await switchTo(0)}');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      switches.add('to$index=${await switchTo(index)}');
    }
    // ignore: avoid_print
    print('E2E-DISPLAY-SWITCH events=$events ms ${switches.join(' ')}');

    // The display starts in one of its modes; alternate between the two
    // smaller ones, beginning with the one it is not in.
    final current = '${latestDisplays(session)[index]['width']}';
    final sizes = current == '1920'
        ? const [
            [2560, 1440],
            [1920, 1080],
            [2560, 1440],
            [1920, 1080],
          ]
        : const [
            [1920, 1080],
            [2560, 1440],
            [1920, 1080],
            [2560, 1440],
          ];
    for (final size in sizes) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final from = session.events.length;
      final start = DateTime.now();
      await native.bind.sessionChangeResolution(
          sessionId: session.id,
          display: index,
          width: size[0],
          height: size[1]);
      await session.until(
          () => _noticeAfter(session, from, index, size[0]) != null,
          'the new size of display $index',
          timeout: const Duration(seconds: 15));
      final notice = _noticeAfter(session, from, index, size[0])!;
      await session.until(
          () => _firstFrameAfter(session, index, notice) != null,
          'a frame after the change');
      final frame = _firstFrameAfter(session, index, notice)!;
      // ignore: avoid_print
      print('E2E-DISPLAY-RESOLUTION events=$events ${size[0]}x${size[1]} '
          'notice_ms=${notice.difference(start).inMilliseconds} '
          'first_frame_ms=${frame.difference(start).inMilliseconds}');
    }

    await native.bind.sessionToggleVirtualDisplay(
        sessionId: session.id, index: 1, on: false);
    await session.until(() => latestDisplays(session).length == displaysBefore,
        'the virtual display removed');
    expect(await nikoVirtualDisplayModes(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
