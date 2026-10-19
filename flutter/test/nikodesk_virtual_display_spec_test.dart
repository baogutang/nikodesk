import 'dart:ui' as ui;

import 'package:flutter_hbb/nikodesk/virtual_display.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a retina screen is reported in physical pixels with its scale', () {
    expect(
        nikoScreenSpecOf(const ui.Size(3024, 1964), 2, 120, landscape: false),
        (width: 3024, height: 1964, scaleMilli: 2000, refreshMilliHz: 120000));
  });

  test('a phone held upright is reported in landscape', () {
    const upright = ui.Size(1080, 2400);
    expect(nikoScreenSpecOf(upright, 2.75, 59.94, landscape: true),
        (width: 2400, height: 1080, scaleMilli: 2750, refreshMilliHz: 59940));
    expect(
        nikoScreenSpecOf(upright, 2.75, 59.94, landscape: false).width, 1080);
  });

  test('an unknown screen sends nothing to build a display from', () {
    const unknown = (width: 0, height: 0, scaleMilli: 0, refreshMilliHz: 0);
    expect(nikoScreenSpec(null, landscape: false), unknown);
    expect(nikoScreenSpecOf(ui.Size.zero, 2, 60, landscape: false), unknown);
    expect(
        nikoScreenSpecOf(const ui.Size(double.nan, 1080), 1, 60,
            landscape: false),
        unknown);
    expect(
        nikoScreenSpecOf(const ui.Size(1920, 1080), double.nan, 0,
            landscape: false),
        (width: 1920, height: 1080, scaleMilli: 0, refreshMilliHz: 0));
  });
}
