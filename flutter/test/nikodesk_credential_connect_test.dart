import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/credential_connect_dialog.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => NikoLanguage.english = false);
  Future<void> open(WidgetTester tester, String status,
      void Function(NikoConnectAuth?) received) async {
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      received(await showDialog<NikoConnectAuth>(
                          context: context,
                          builder: (_) => NikoCredentialConnectDialog(
                              id: '123456789',
                              alias: 'Test device',
                              statusLoader: () async => status)));
                    },
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'manual input is not remembered by default; opt-in carries no password in metadata',
      (tester) async {
    NikoConnectAuth? result;
    await open(tester, 'missing', (value) => result = value);
    final checkbox = find.byKey(const Key('remember-secure-password'));
    expect(tester.widget<CheckboxListTile>(checkbox).value, false);
    await tester.enterText(find.byKey(const Key('nikodesk-connect-password')),
        'synthetic test password');
    await tester.tap(checkbox);
    await tester.tap(find.byKey(const Key('nikodesk-connect-submit')));
    await tester.pumpAndSettle();
    expect(result!.remember, true);
    final token = result!.token('a' * 64)!;
    expect(jsonDecode(token)['nikodesk_credentials']['namespace'], 'a' * 64);
    expect(token.contains('synthetic test password'), false);
  });
  testWidgets(
      'saved choice returns a reference and never exposes the password to Flutter',
      (tester) async {
    NikoConnectAuth? result;
    await open(tester, 'present', (value) => result = value);
    await tester.tap(find.byKey(const Key('connect-saved-credential')));
    await tester.pumpAndSettle();
    expect(result!.useSaved, true);
    expect(result!.password, isEmpty);
    expect(result!.remember, isNull);
  });
  testWidgets('unknown storage does not offer a saved-password action',
      (tester) async {
    await open(tester, 'unavailable', (_) {});
    expect(find.byKey(const Key('connect-saved-credential')), findsNothing);
    await tester.tap(find.byKey(const Key('nikodesk-connect-submit')));
    await tester.pumpAndSettle();
    expect(find.byType(NikoCredentialConnectDialog), findsOneWidget);
  });
}
