// The controlled profile allows terminal requests. Each request still needs
// the connection manager's approval, which the runner's development hook
// gives in place of a click.
import 'package:flutter_hbb/nikodesk/capability_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';
import 'support/policy.dart';

void main() {
  test('allow terminal requests on the controlled profile', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await allowRequests(native, NikoCapability.terminal, true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
