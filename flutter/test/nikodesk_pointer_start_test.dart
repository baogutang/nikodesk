import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/pointer_start.dart';

void main() {
  test('a session starts the remote pointer in the middle, off the hot corners',
      () {
    final start = nikoPointerStart(const Rect.fromLTWH(-1920, 0, 1920, 1080));
    if (const bool.fromEnvironment('NIKODESK')) {
      expect(start, const Offset(-960, 540));
    } else {
      expect(start, isNull);
    }
    expect(nikoPointerStart(null), isNull);
  });
}
