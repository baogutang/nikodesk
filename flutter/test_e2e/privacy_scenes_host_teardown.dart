// Puts the "host" profile back on its default: no privacy screen for
// controllers.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile no longer allows the privacy screen', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind.mainSetOption(key: 'enable-privacy-mode', value: 'N');
    expect((await native.options())['enable-privacy-mode'], 'N');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
