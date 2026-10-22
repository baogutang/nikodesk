// Allows virtual displays and turns on the native VideoToolbox session.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile allows virtual displays, native encoder on',
      () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind
        .mainSetOption(key: 'nikodesk-allow-virtual-display', value: 'Y');
    await native.bind.mainSetOption(key: 'nikodesk-native-encoder', value: 'Y');
    expect((await native.options())['nikodesk-native-encoder'], 'Y');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
