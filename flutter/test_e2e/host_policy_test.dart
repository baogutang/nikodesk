// Gives the running "host" profile a password-only policy, so a run needs no
// click on the controlled side. Password changes go through the host app's
// own IPC, exactly as its settings page does, so the app must be running.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile accepts its permanent password only', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    final password = env('NIKODESK_E2E_HOST_PASSWORD');
    expect(password.length, greaterThanOrEqualTo(16));
    expect(
        await native.bind
            .mainSetPermanentPasswordWithResult(password: password),
        isTrue,
        reason: 'the host app did not confirm the password change');
    await native.bind.mainSetOption(
        key: 'verification-method', value: 'use-permanent-password');
    await native.bind.mainSetOption(key: 'approve-mode', value: 'password');
    final options = await native.options();
    expect(options['verification-method'], 'use-permanent-password');
    expect(options['approve-mode'], 'password');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
