// The controlled profile allows tunnel requests. Each tunnel still needs the
// connection manager to resolve and approve its exact target, which the
// runner's development hook does in place of a click.
import 'package:flutter_hbb/nikodesk/capability_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';
import 'support/policy.dart';

void main() {
  test('allow tunnel requests on the controlled profile', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await allowRequests(native, NikoCapability.tunnel, true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
