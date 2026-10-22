// Sets the host's native encoder option from NIKODESK_E2E_NATIVE: "all" (also
// above 4K), "N" (ffmpeg's session) or empty (the default, up to 4K), and the
// capture from NIKODESK_E2E_SCK.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile uses the requested encoder session', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    final value = Platform.environment['NIKODESK_E2E_NATIVE'] ?? '';
    await native.bind
        .mainSetOption(key: 'nikodesk-native-encoder', value: value);
    expect((await native.options())['nikodesk-native-encoder'] ?? '', value);
    // NIKODESK_E2E_SCK=Y captures with ScreenCaptureKit.
    await native.bind.mainSetOption(
        key: 'nikodesk-sck-capture',
        value: Platform.environment['NIKODESK_E2E_SCK'] == 'Y' ? 'Y' : '');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
