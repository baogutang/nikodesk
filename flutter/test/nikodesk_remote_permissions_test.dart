import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/remote_permissions.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => NikoLanguage.english = false);

  test('only a reported missing permission produces a notice', () {
    expect(nikoRemoteMissingPermissions({}), isNull);
    expect(
        nikoRemoteMissingPermissions({
          'nikodesk_permissions': {
            'screen_recording': true,
            'accessibility': true
          }
        }),
        isNull);
    expect(
        nikoRemoteMissingPermissions({'nikodesk_permissions': 'yes'}), isNull);
    final missing = nikoRemoteMissingPermissions({
      'nikodesk_permissions': {'screen_recording': false, 'accessibility': true}
    })!;
    expect((missing.screen, missing.input), (true, false));
    // A field the controlled side did not report is not assumed missing.
    final input = nikoRemoteMissingPermissions({
      'nikodesk_permissions': {'accessibility': false}
    })!;
    expect((input.screen, input.input), (false, true));
  });

  testWidgets('the notice names each missing permission and how to grant it',
      (tester) async {
    NikoLanguage.english = true;
    var dismissed = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 320,
                child: NikoRemotePermissionView(
                    screen: true,
                    input: true,
                    onDismiss: () => dismissed = true)))));
    expect(
        find.textContaining('Screen Recording is not allowed'), findsOneWidget);
    expect(find.textContaining('Accessibility is not allowed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('remote-permission-dismiss')));
    expect(dismissed, isTrue);
  });
}
