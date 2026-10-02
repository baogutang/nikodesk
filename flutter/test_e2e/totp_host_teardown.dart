// Removes two-factor authentication from the "host" profile again.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';
import 'support/totp.dart';

void main() {
  test('remove two-factor authentication from the controlled profile',
      () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind.mainSetOption(key: '2fa', value: '');
    expect(native.bind.mainHasValid2FaSync(), isFalse);
    Totp.forget();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
