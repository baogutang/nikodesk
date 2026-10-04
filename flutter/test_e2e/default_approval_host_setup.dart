// Puts the running "host" profile on the product's default acceptance rule:
// no explicit approve-mode, with its permanent password available.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile uses the default acceptance rule', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind.mainSetOption(
        key: 'verification-method', value: 'use-both-passwords');
    await native.bind.mainSetOption(key: 'approve-mode', value: '');
    final options = await native.options();
    expect(options['verification-method'], 'use-both-passwords');
    // Whatever the build's default is; the session scenario judges it.
    // ignore: avoid_print
    print('E2E-APPROVAL default approve-mode="${options['approve-mode'] ?? ''}"');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
