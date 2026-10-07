// Lets controllers use the privacy screen of the running "host" profile.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile allows the privacy screen', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind.mainSetOption(key: 'enable-privacy-mode', value: 'Y');
    expect((await native.options())['enable-privacy-mode'], 'Y');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
