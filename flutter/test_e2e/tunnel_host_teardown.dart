// Returns the controlled profile to its default: no tunnel requests.
import 'package:flutter_hbb/nikodesk/capability_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';
import 'support/policy.dart';

void main() {
  test('disallow tunnel requests on the controlled profile', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await allowRequests(native, NikoCapability.tunnel, false);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
