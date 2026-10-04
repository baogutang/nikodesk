// Puts the running "host" profile on an explicit click-only rule while its
// permanent password stays valid.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile accepts sessions by click only', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind.mainSetOption(
        key: 'verification-method', value: 'use-permanent-password');
    await native.bind.mainSetOption(key: 'approve-mode', value: 'click');
    final options = await native.options();
    expect(options['approve-mode'], 'click',
        reason: 'an explicit click-only choice must be stored');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
