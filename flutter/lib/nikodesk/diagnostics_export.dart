import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Android's document picker reads an app-owned file. Keep the file until the
/// native copy or cancellation completes; never treat a content URI as a path.
Future<bool> exportNikoAndroidDiagnostics(
  String contents, {
  required Future<bool> Function(String path) exportFile,
  Future<Directory> Function()? supportDirectory,
}) async {
  final support = await (supportDirectory ?? getApplicationSupportDirectory)();
  final staging = await support.createTemp('niko-diagnostics-');
  final source = File('${staging.path}/NikoDesk-diagnostics.json');
  try {
    await source.writeAsString(contents, flush: true);
    return await exportFile(source.path);
  } finally {
    try {
      if (await source.exists()) await source.delete();
      await staging.delete();
    } catch (_) {
      // A cleanup failure must not turn a confirmed export into a false result.
    }
  }
}
