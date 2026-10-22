// Puts the host back on its defaults.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile is back on its defaults', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind
        .mainSetOption(key: 'nikodesk-allow-virtual-display', value: 'N');
    await native.bind.mainSetOption(key: 'nikodesk-native-encoder', value: '');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
