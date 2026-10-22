// Lets controllers create virtual displays on the running "host" profile and
// sets the display-event path from NIKODESK_E2E_DISPLAY_EVENTS (Y, default,
// or N for the periodic display check only).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile allows virtual displays', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    final events = Platform.environment['NIKODESK_E2E_DISPLAY_EVENTS'] ?? 'Y';
    await native.bind
        .mainSetOption(key: 'nikodesk-allow-virtual-display', value: 'Y');
    await native.bind.mainSetOption(
        key: 'nikodesk-display-events', value: events == 'N' ? 'N' : '');
    expect((await native.options())['nikodesk-allow-virtual-display'], 'Y');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
