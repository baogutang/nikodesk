// Restores the password-only policy the other scenarios expect.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile is back on its password-only policy', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind.mainSetOption(
        key: 'verification-method', value: 'use-permanent-password');
    await native.bind.mainSetOption(key: 'approve-mode', value: 'password');
    final options = await native.options();
    expect(options['approve-mode'], 'password');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
