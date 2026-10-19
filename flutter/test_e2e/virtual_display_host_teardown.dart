// Puts the "host" profile back on its default: no virtual displays.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile no longer allows virtual displays', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind
        .mainSetOption(key: 'nikodesk-allow-virtual-display', value: 'N');
    expect((await native.options())['nikodesk-allow-virtual-display'], 'N');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
