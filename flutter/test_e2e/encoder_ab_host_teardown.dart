// Puts the host's native encoder option back on its default.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile is back on the default encoder', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind.mainSetOption(key: 'nikodesk-native-encoder', value: '');
    await native.bind.mainSetOption(key: 'nikodesk-sck-capture', value: '');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
