import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/peer_event_scope.dart';
import 'package:flutter_hbb/nikodesk/peer_load_notice.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

void main() {
  final scope = 'a' * 64;
  Map<String, dynamic> event(Object? peers, {String status = 'ready'}) => {
        'nikodesk-server-namespace': scope,
        'nikodesk-load-status': status,
        'peers': peers,
      };

  test('current read failure is distinct from stale data and confirmed empty',
      () {
    final failed = nikoClassifyPeerEvent(event(null, status: 'error'), scope)!;
    expect(failed.failure, NikoPeerLoadFailure.readFailed);
    expect(failed.ready, isNull);
    expect(
        nikoClassifyPeerEvent(event(null, status: 'error'), 'b' * 64), isNull);
    final empty = nikoClassifyPeerEvent(event('[]'), scope)!;
    expect(empty.failure, isNull);
    expect(empty.ready!.peers, isEmpty);
  });

  test('malformed metadata cannot replace a last known list or throw', () {
    for (final malformed in [
      event('not json'),
      event('[{"id":"123456789","alias":17}]'),
      event('[{"id":"123456789","tags":{}}]'),
      event('[{"id":"123456789","same_server":"true"}]'),
      event('[{"id":"123456789"},{"id":"123456789"}]'),
      event('[]', status: 'unexpected'),
    ]) {
      final result = nikoClassifyPeerEvent(malformed, scope)!;
      expect(result.failure, NikoPeerLoadFailure.invalidData);
      expect(result.ready, isNull);
    }
    final valid = nikoClassifyPeerEvent(
        event(jsonEncode([
          {'id': '123456789', 'alias': 'Work'}
        ])),
        scope)!;
    expect(valid.ready!.peers.single['alias'], 'Work');
  });

  for (final english in [false, true]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('read error / previous rows at 320/200% $english $brightness',
          (tester) async {
        NikoLanguage.english = english;
        addTearDown(() => NikoLanguage.english = false);
        await tester.binding.setSurfaceSize(const Size(320, 350));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var retries = 0;
        await tester.pumpWidget(MaterialApp(
          theme: nikoTheme(brightness),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: child!),
          home: Scaffold(
            body: Column(children: [
              SizedBox(
                height: 157,
                child: NikoPeerLoadNotice(
                    configured: true,
                    hasPreviousRows: true,
                    failure: NikoPeerLoadFailure.readFailed,
                    onRetry: () => retries++),
              ),
              const Expanded(child: Center(child: Text('last known row'))),
            ]),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining(english ? 'unconfirmed' : '尚未确认'),
            findsOneWidget);
        expect(find.text('last known row'), findsOneWidget);
        final retry =
            find.byWidgetPredicate((widget) => widget is OutlinedButton);
        await tester.ensureVisible(retry);
        await tester.pumpAndSettle();
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(retries, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('unconfigured notice has no invalid retry action',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: NikoPeerLoadNotice(
                configured: false, hasPreviousRows: false))));
    expect(find.byWidgetPredicate((widget) => widget is OutlinedButton),
        findsNothing);
  });
}
