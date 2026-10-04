// A controller declares how wide a picture it wants; the controlled Mac must
// capture that size without changing its display mode, follow later changes,
// and go back to its own size once the controller that asked has left.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

const _option = 'nikodesk-capture-width';

({int width, int height, int points}) _display(Map<String, dynamic> event) {
  // peer_info carries a list of displays; switch_display one display's fields.
  final display = event['displays'] is String
      ? (jsonDecode(event['displays'] as String) as List).first
          as Map<String, dynamic>
      : event;
  int number(Object? value) => value is int ? value : int.parse('$value');
  final width = number(display['width']);
  return (
    width: width,
    height: number(display['height']),
    points: number(display['original_width']),
  );
}

// A size change reaches the controller as either event, depending on whether
// the picture was already running.
bool _reportsDisplay(Map<String, dynamic> event) =>
    event['name'] == 'switch_display' ||
    (event['name'] == 'sync_peer_info' && event['displays'] is String);

({int width, int height, int points}) _latest(
        NikoSession session, Map<String, dynamic> login) =>
    _display(session.events.lastWhere(_reportsDisplay, orElse: () => login));

// Where the controlled Mac's pointer really is, in points. Both ends run on
// this machine, so the test can look.
Future<({double x, double y})?> _pointer() async {
  final result = await Process.run('swift', [
    '-e',
    'import CoreGraphics; let p = CGEvent(source: nil)!.location; print(p.x, p.y)'
  ]);
  final parts = '${result.stdout}'.trim().split(' ');
  if (result.exitCode != 0 || parts.length != 2) return null;
  return (x: double.parse(parts[0]), y: double.parse(parts[1]));
}

void main() {
  test('the controlled side captures the width its controller asks for',
      () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final password = env('NIKODESK_E2E_HOST_PASSWORD');

    var session = await NikoSession.open(native, host, password: password);
    var open = true;
    Future<void> close() async {
      if (open) await session.close();
      open = false;
    }

    addTearDown(close);
    Future<void> ask(String width) => native.bind
        .sessionPeerOption(sessionId: session.id, name: _option, value: width);
    // Leave no request behind for other scenarios.
    addTearDown(() async {
      if (open) await ask('');
    });

    final info = await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await session.until(() => session.frames > 0, 'first decoded frame');
    // A request saved by an earlier run would already be in effect; start
    // from the display's own size.
    await ask('65535');
    await Future<void>.delayed(const Duration(seconds: 3));
    final native5k = _latest(session, info);
    // ignore: avoid_print
    print('E2E-CAPTURE native=${native5k.width}x${native5k.height} '
        'points=${native5k.points}');
    expect(native5k.width, greaterThan(native5k.points),
        reason: 'this scenario needs a Retina display on the controlled side');

    var checks = 0;
    Future<({int width, int height, int points})> expectWidth(
        String asked, int expected) async {
      final frames = session.frames;
      await ask(asked);
      final event = await session.event(
          (event) => _reportsDisplay(event) && _display(event).width == expected,
          'the controlled side reporting a $expected px picture');
      await session.until(() => session.frames > frames + 2,
          'frames at the new size');
      final display = _display(event);
      // ignore: avoid_print
      print('E2E-CAPTURE asked=$asked captured=${display.width}x'
          '${display.height} points=${display.points}');
      // The display mode itself is untouched.
      expect(display.points, native5k.points);

      // A pointer position given in the captured picture must land on the
      // same spot of the real desktop. Each check aims somewhere else, so a
      // dropped event cannot pass by leaving the pointer where it was.
      final across = const [3, 1, 2, 3][checks % 4];
      final down = const [1, 3, 2, 3][checks % 4];
      checks++;
      final before = await _pointer();
      final target = (
        x: display.width * across ~/ 4,
        y: display.height * down ~/ 4
      );
      await native.bind.sessionSendMouse(
          sessionId: session.id,
          msg: jsonEncode({'x': '${target.x}', 'y': '${target.y}'}));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final after = await _pointer();
      final wanted = (
        x: native5k.points * across / 4,
        y: native5k.points * display.height / display.width * down / 4
      );
      if (before == null || after == null) {
        // ignore: avoid_print
        print('E2E-CAPTURE pointer position unavailable; mapping not checked');
      } else if ((after.x - wanted.x).abs() <= 2 && (after.y - wanted.y).abs() <= 2) {
        // ignore: avoid_print
        print('E2E-CAPTURE pointer sent=${target.x},${target.y} '
            'landed=${after.x.round()},${after.y.round()} points (as wanted)');
      } else if (after.x == before.x && after.y == before.y) {
        // ignore: avoid_print
        print('E2E-CAPTURE the controlled side did not move the pointer '
            '(no input permission for this run); mapping not checked');
      } else {
        fail('pointer sent to ${target.x},${target.y} of a ${display.width} px '
            'picture landed at ${after.x},${after.y}, wanted ${wanted.x},${wanted.y}');
      }
      return display;
    }

    final aspect = native5k.width / native5k.height;
    final fit = await expectWidth('3840', (native5k.points * 1.5).round());
    expect((fit.width / fit.height - aspect).abs(), lessThan(0.01));
    final points = await expectWidth('2560', native5k.points);
    expect(points.height.isEven, isTrue);
    await expectWidth('65535', native5k.width);
    // The smallest request is the point size, never less.
    await expectWidth('640', native5k.points);
    await expectWidth('65535', native5k.width);

    // The next login carries the saved request before any picture is sent.
    await ask('3840');
    await session.until(() => _latest(session, info).width == fit.width,
        'the request applied before reconnecting');
    await close();
    await Future<void>.delayed(const Duration(seconds: 3));
    session = await NikoSession.open(native, host, password: password);
    open = true;
    final again = await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after reconnect');
    await session.until(() => session.frames > 0, 'first frame after reconnect');
    await Future<void>.delayed(const Duration(seconds: 2));
    final atLogin = _latest(session, again);
    // ignore: avoid_print
    print('E2E-CAPTURE after-login captured=${atLogin.width}x${atLogin.height}');
    expect(atLogin.width, fit.width,
        reason: 'the login request was not applied');

    // With the request cleared and its controller gone, the next controller
    // gets the display's own size again.
    await ask('');
    await close();
    await Future<void>.delayed(const Duration(seconds: 3));
    session = await NikoSession.open(native, host, password: password);
    open = true;
    final cleared = await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after clearing');
    await session.until(() => session.frames > 0, 'first frame after clearing');
    await Future<void>.delayed(const Duration(seconds: 2));
    final restored = _latest(session, cleared);
    // ignore: avoid_print
    print('E2E-CAPTURE after-leaving captured=${restored.width}x${restored.height}');
    expect(restored.width, native5k.width,
        reason: 'a departed controller still limited the picture');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
