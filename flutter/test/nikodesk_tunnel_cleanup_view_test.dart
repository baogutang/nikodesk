import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/tunnel_cleanup.dart';
import 'package:flutter_hbb/nikodesk/tunnel_cleanup_view.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_tunnel_cleanup_test.dart' as fixtures;

void main() {
  for (final english in [false, true]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
          'cleanup panel 320px 200% $english $brightness keeps exact old owner without grant',
          (tester) async {
        NikoLanguage.english = english;
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        NikoTunnelOwnerIdentity? queried;
        final model = NikoTunnelCleanupModel(
            readRetired: () async => fixtures.roster(),
            query: (owner) async {
              queried = owner;
              return '{"ok":false,"reason":"busy","owners":[]}';
            });
        addTearDown(model.dispose);
        await model.refresh();
        await tester.pumpWidget(MaterialApp(
            theme: nikoTheme(brightness),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(2)),
                child: child!),
            home: Scaffold(
                body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: NikoTunnelCleanupPanel(model: model)))));
        final query =
            find.byKey(Key('niko-tunnel-cleanup-${fixtures.owner.key}'));
        await tester.ensureVisible(query);
        await tester.pump();
        expect(tester.getSize(query).height, greaterThanOrEqualTo(48));
        await tester.tap(query);
        await tester.pump();
        expect(queried!.same(fixtures.owner), true);
        expect(model.entries.length, 1);
        expect(find.text('Approve'), findsNothing);
        expect(find.text('批准'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  testWidgets(
      'empty native list has no homepage placeholder; dispose stops polling',
      (tester) async {
    var reads = 0;
    final model = NikoTunnelCleanupModel(
        readRetired: () async {
          reads++;
          return '{"ok":true,"reason":"closed","owners":[]}';
        },
        query: (_) async => '');
    addTearDown(model.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoTunnelCleanupEntryPoint(
                model: model, interval: const Duration(milliseconds: 10)))));
    await tester.pump();
    expect(find.byKey(const Key('niko-tunnel-cleanup-open')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    final previous = reads;
    await tester.pump(const Duration(milliseconds: 100));
    expect(reads, previous);
  });
}
