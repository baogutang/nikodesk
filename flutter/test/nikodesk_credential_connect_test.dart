import 'dart:convert';
import 'dart:async';
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
  Future<void> ask(WidgetTester tester, Future<String> Function() loader,
      void Function(NikoConnectAuth?) received,
      {bool autoUseSaved = true}) async {
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      received(await nikoAskCredentialConnect(
                          context, '123456789', '',
                          namespace: 'a' * 64,
                          autoUseSaved: autoUseSaved,
                          statusLoader: loader));
                    },
                    child: const Text('ask'))))));
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'normal remembered connection automatically uses only a reference',
      (tester) async {
    NikoConnectAuth? result;
    var reads = 0;
    await ask(tester, () async {
      reads++;
      return 'present';
    }, (value) => result = value);
    expect(result!.useSaved, true);
    expect(result!.password, isEmpty);
    expect(result!.token('a' * 64), isNull);
    expect(find.byType(NikoCredentialConnectDialog), findsNothing);
    expect(reads, 1);
  });

  testWidgets('external link opt-out still requires explicit saved choice',
      (tester) async {
    NikoConnectAuth? result;
    await ask(tester, () async => 'present', (value) => result = value,
        autoUseSaved: false);
    expect(result, isNull);
    expect(find.byType(NikoCredentialConnectDialog), findsOneWidget);
    await tester.tap(find.byKey(const Key('connect-saved-credential')));
    await tester.pumpAndSettle();
    expect(result!.useSaved, true);
  });

  testWidgets('secure storage read failure permits unremembered manual entry',
      (tester) async {
    NikoConnectAuth? result;
    await ask(tester, () async => throw StateError('synthetic unavailable'),
        (value) => result = value);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('remember-secure-password')))
            .value,
        false);
    await tester.enterText(find.byKey(const Key('nikodesk-connect-password')),
        'synthetic-password');
    await tester.tap(find.byKey(const Key('nikodesk-connect-submit')));
    await tester.pumpAndSettle();
    expect(result!.remember, false);
    expect(result!.useSaved, false);
  });

  testWidgets(
      'disposed caller does not show a late dialog or dispatch reference',
      (tester) async {
    final status = Completer<String>();
    NikoConnectAuth? result;
    await ask(tester, () => status.future, (value) => result = value);
    await tester.pumpWidget(const SizedBox());
    status.complete('present');
    await tester.pump();
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });
  test('explicit quick-entry choices serialize only scope and consent', () {
    for (final remember in [false, true]) {
      final auth = NikoConnectAuth('synthetic-password', remember: remember);
      final token = auth.token('a' * 64)!;
      expect(jsonDecode(token), {
        'nikodesk_credentials': {
          'schema': 1,
          'namespace': 'a' * 64,
          'remember': remember
        }
      });
      expect(token.contains(auth.password), false);
    }
  });

  testWidgets('retry after preflight failure re-reads secure storage',
      (tester) async {
    var reads = 0;
    await ask(
        tester, () async => ++reads == 1 ? 'unavailable' : 'present', (_) {});
    expect(reads, 1);
    await tester.tap(find.text('重试读取'));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.byKey(const Key('connect-saved-credential')), findsOneWidget);
  });
  testWidgets(
      'a stalled secure lookup falls back to manual entry without a late auto-connect',
      (tester) async {
    final status = Completer<String>();
    NikoConnectAuth? result;
    await ask(tester, () => status.future, (value) => result = value);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nikodesk-connect-password')), findsOneWidget);
    status.complete('present');
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
