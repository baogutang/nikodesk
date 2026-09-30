import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/mobile_session_guide.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final dark in [false, true]) {
    for (final touch in [false, true]) {
      testWidgets('small screen 200% guide dark=$dark touch=$touch',
          (tester) async {
        NikoLanguage.english = true;
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
            theme: nikoTheme(dark ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!),
            home: NikoMobileSessionGuide(touchMode: touch)));
        expect(find.text('Control the remote computer'), findsOneWidget);
        expect(find.text('Got it'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Keyboard and exit'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
