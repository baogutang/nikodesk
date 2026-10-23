// The Mac controller's texture watchdog (plan A3-1) in a real session. This
// controller is headless and never creates a texture, which is the failure the
// watchdog is for: with texture rendering left at its default, frames find no
// texture for 8 s, then the core records the failure, turns texture rendering
// off for its sessions and the same session goes on with the soft renderer.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  late NikoNative native;
  late String host;
  late String password;

  setUpAll(() async {
    native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    password = env('NIKODESK_E2E_HOST_PASSWORD');
  });

  test('frames that never reach a texture move the session to soft rendering',
      () async {
    await native.bind
        .mainSetLocalOption(key: 'texture-render-health', value: '');
    await native.bind.mainSetLocalOption(key: 'use-texture-render', value: '');
    addTearDown(() async {
      await native.bind
          .mainSetLocalOption(key: 'use-texture-render', value: 'N');
      await native.bind
          .mainSetLocalOption(key: 'texture-render-health', value: '');
    });
    expect(native.bind.mainGetUseTextureRender(), isTrue);

    final started = DateTime.now();
    final session = await NikoSession.open(native, host, password: password);
    addTearDown(session.close);
    await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    final off = await session.event(
        (event) => event['name'] == 'use_texture_render',
        'the switch to the soft renderer',
        timeout: const Duration(seconds: 60));
    final switched = session.eventTimes[session.events.indexOf(off)];
    expect(off['v'], 'N');
    expect(session.frameLog.where((frame) => frame.at.isBefore(switched)),
        isEmpty,
        reason: 'frames went to textures until the switch');
    await session.until(
        () => session.frames >= 10, '10 frames from the soft renderer');
    expect(native.bind.mainGetLocalOption(key: 'texture-render-health'),
        'failed-no-frames');
    expect(native.bind.mainGetUseTextureRender(), isFalse);
    // ignore: avoid_print
    print('E2E texture_fallback '
        'switched=${switched.difference(started).inMilliseconds}ms '
        'first_soft_frame=${session.firstFrame!.difference(started).inMilliseconds}ms '
        'quality=${session.quality()}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
