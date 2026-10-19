import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/diagnostics_bundle.dart';
import 'package:flutter_hbb/nikodesk/product_build_info.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => NikoLanguage.english = false);

  test('the bundle carries the product version and the native report', () {
    final bundle = jsonDecode(nikoDiagnosticsBundle(
        nativeJson: '{"core":"1.5.0","logs":{"a.log":"<ip> ok"}}',
        build: const ProductBuildInfo(
            version: '1.1.0', buildNumber: '23', nativeVersion: '1.5.0'),
        now: DateTime.utc(2026, 10, 19))) as Map<String, dynamic>;
    expect(bundle['product']['version'], '1.1.0');
    expect(bundle['native']['logs']['a.log'], '<ip> ok');
    expect(bundle['exportedAt'], '2026-10-19T00:00:00.000Z');
    final broken = jsonDecode(nikoDiagnosticsBundle(
        nativeJson: 'not json', build: ProductBuildInfo.unknown));
    expect(broken['native'], isNull);
  });

  test('a crash marker becomes one line; nothing or junk becomes none', () {
    NikoLanguage.english = true;
    expect(nikoCrashNotice(''), isNull);
    expect(nikoCrashNotice('not json'), isNull);
    expect(nikoCrashNotice('[1]'), isNull);
    final text = nikoCrashNotice(
        jsonEncode({'time': 1792390000, 'thread': 'video-0', 'message': 'x'}))!;
    expect(text, contains('internal error last time'));
    expect(text, contains('video-0'));
  });

  testWidgets('the export button reports success and failure', (tester) async {
    NikoLanguage.english = true;
    var fail = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoDiagnosticsExportButton(
                export: () async =>
                    fail ? throw StateError('no') : '/tmp/x.json'))));
    await tester.tap(find.byKey(const Key('nikodesk-export-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Diagnostics saved'), findsOneWidget);
    fail = true;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nikodesk-export-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Export failed'), findsOneWidget);
  });
}
