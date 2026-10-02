// Binds two-factor authentication on the running "host" profile the same way
// its settings page does: generate a secret, then confirm it with a code.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';
import 'support/totp.dart';

void main() {
  test('bind two-factor authentication on the controlled profile', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    final url = await native.bind.mainGenerate2Fa();
    expect(url, startsWith('otpauth://totp/'));
    final totp = Totp.fromUrl(url);
    expect(await native.bind.mainVerify2Fa(code: totp.code()), isTrue,
        reason: 'the host did not accept a current code for its new secret');
    expect(native.bind.mainHasValid2FaSync(), isTrue);
    totp.save();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
