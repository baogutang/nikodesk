import 'dart:async';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/diagnostics_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() async =>
      root = await Directory.systemTemp.createTemp('niko-export-test-'));
  tearDown(() async => root.delete(recursive: true));

  test(
      'Android staging remains readable until the real document operation completes',
      () async {
    final entered = Completer<String>();
    final completed = Completer<bool>();
    final export = exportNikoAndroidDiagnostics('{"redacted":true}',
        supportDirectory: () async => root,
        exportFile: (path) {
          entered.complete(path);
          return completed.future;
        });
    final path = await entered.future;
    expect(await File(path).readAsString(), '{"redacted":true}');
    completed.complete(true);
    expect(await export, true);
    expect(await File(path).exists(), false);
    expect(await root.list().toList(), isEmpty);
  });

  test('cancelling the document picker cannot report a saved file', () async {
    expect(
        await exportNikoAndroidDiagnostics('{}',
            supportDirectory: () async => root, exportFile: (_) async => false),
        false);
    expect(await root.list().toList(), isEmpty);
  });

  test('a failed native copy cleans staging and preserves the error', () async {
    await expectLater(
        exportNikoAndroidDiagnostics('{}',
            supportDirectory: () async => root,
            exportFile: (_) async =>
                throw StateError('synthetic copy failure')),
        throwsStateError);
    expect(await root.list().toList(), isEmpty);
  });
}
