// Pins the host's encoder to ffmpeg's VideoToolbox session.
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile uses ffmpeg\'s encoder session', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    await native.bind.mainSetOption(key: 'nikodesk-native-encoder', value: 'N');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
