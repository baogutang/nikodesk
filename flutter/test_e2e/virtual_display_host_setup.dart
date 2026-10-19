// Lets controllers create virtual displays on the running "host" profile.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile allows virtual displays', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind
        .mainSetOption(key: 'nikodesk-allow-virtual-display', value: 'Y');
    expect((await native.options())['nikodesk-allow-virtual-display'], 'Y');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
