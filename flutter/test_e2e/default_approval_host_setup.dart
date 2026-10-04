// Puts the running "host" profile on the product's defaults: no explicit
// acceptance rule and the one-time password as the only password. The
// one-time password is handed to the controller scenario through the private
// work directory; it is never printed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile uses the default acceptance rule', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind.mainSetOption(key: 'verification-method', value: '');
    await native.bind.mainSetOption(key: 'approve-mode', value: '');
    final options = await native.options();
    expect(options['verification-method'], 'use-temporary-password',
        reason: 'the default must be the one-time password only');
    // Whatever the build's default acceptance rule is; the session scenario
    // judges it.
    // ignore: avoid_print
    print('E2E-APPROVAL default approve-mode="${options['approve-mode'] ?? ''}" '
        'verification-method="${options['verification-method']}"');
    // This process is not the app: it learns the one-time password from the
    // app's status sync, which has to be started and takes a moment.
    await native.bind.mainCheckConnectStatus();
    var password = '';
    for (var i = 0; i < 40 && password.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      password = await native.bind.mainGetTemporaryPassword();
    }
    expect(password, isNotEmpty);
    final file =
        File('${env('NIKODESK_E2E_WORK')}/host/one-time-password');
    file.writeAsStringSync(password, flush: true);
    Process.runSync('chmod', ['600', file.path]);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
