import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';

// The connection-manager window and other hosted upstream pages resolve
// ColorThemeExtension / TabbarTheme from the ambient theme with non-null
// assertions. A NikoDesk theme without those extensions rendered as a grey
// window in release builds; this locks the regression.
void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
        'nikoTheme(${brightness.name}) provides the upstream extensions',
        (tester) async {
      Color? borderColor;
      await tester.pumpWidget(MaterialApp(
          theme: nikoTheme(brightness),
          home: Builder(builder: (context) {
            borderColor = MyTheme.color(context).border;
            MyTheme.tabbar(context);
            return const SizedBox();
          })));
      expect(tester.takeException(), isNull);
      expect(borderColor, isNotNull);
    });
  }
}
