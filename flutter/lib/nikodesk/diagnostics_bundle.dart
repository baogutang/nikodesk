import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/platform_model.dart';
import 'product_build_info.dart';
import 'ui.dart';

/// The redacted local diagnostics bundle: product version plus what the
/// native side collected (recent logs, crash records). Nothing is uploaded;
/// the user decides where the file goes.
String nikoDiagnosticsBundle(
    {required String nativeJson,
    required ProductBuildInfo build,
    DateTime? now}) {
  Object? native;
  try {
    native = nativeJson.isEmpty ? null : jsonDecode(nativeJson);
  } catch (_) {
    native = null;
  }
  return const JsonEncoder.withIndent('  ').convert({
    'schemaVersion': 1,
    'application': 'NikoDesk',
    'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'product': {
      'version': build.version,
      'build': build.buildNumber,
      'core': build.nativeVersion,
      'platform': Platform.operatingSystem,
    },
    'native': native,
  });
}

/// A one-line explanation of a crash marker, or null for none or a malformed
/// one.
String? nikoCrashNotice(String marker, {DateTime Function()? now}) {
  if (marker.isEmpty || marker.length > 4096) return null;
  try {
    final json = jsonDecode(marker);
    if (json is! Map<String, dynamic>) return null;
    final seconds = json['time'];
    final thread = json['thread'];
    final when = seconds is int && seconds > 0
        ? DateTime.fromMillisecondsSinceEpoch(seconds * 1000)
        : null;
    final at = when == null
        ? ''
        : '${when.month}/${when.day} ${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
    final where = thread is String && thread.length <= 64 ? thread : '';
    return nikoText(
        'NikoDesk 上次运行时发生内部错误${at.isEmpty ? '' : '（$at${where.isEmpty ? '' : '，$where'}）'}，已记录在本机日志。可导出诊断包查看。',
        'NikoDesk hit an internal error last time${at.isEmpty ? '' : ' ($at${where.isEmpty ? '' : ', $where'})'}. It is recorded in the local log; export a diagnostics bundle to look into it.');
  } catch (_) {
    return null;
  }
}

/// Asks where to save the bundle and writes it. Null when cancelled.
Future<String?> nikoExportDiagnostics() async {
  final contents = nikoDiagnosticsBundle(
      nativeJson: await bind.mainGetNikodeskDiagnostics(),
      build: await ProductBuildInfo.read(
          nativeVersionLoader: bind.mainGetVersion));
  final path = await FilePicker.platform.saveFile(
      dialogTitle: nikoText('保存脱敏诊断包', 'Save redacted diagnostics'),
      fileName: 'NikoDesk-diagnostics.json',
      type: FileType.custom,
      allowedExtensions: ['json']);
  if (path == null) return null;
  await File(path).writeAsString(contents, flush: true);
  return path;
}

/// Shows, once, that the last run recorded a crash.
void nikoShowCrashNotice(BuildContext context) {
  if (!Platform.isMacOS && !Platform.isWindows) return;
  final text = nikoCrashNotice(bind.mainTakeNikodeskCrashMarker());
  if (text == null) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 12),
      content: Text(text),
      action: SnackBarAction(
          label: nikoText('导出诊断包', 'Export diagnostics'),
          onPressed: () => nikoExportDiagnostics().catchError((_) => null))));
}

/// Settings entry for saving the diagnostics bundle.
class NikoDiagnosticsExportButton extends StatefulWidget {
  final Future<String?> Function()? export;
  const NikoDiagnosticsExportButton({super.key, this.export});
  @override
  State<NikoDiagnosticsExportButton> createState() => _ExportState();
}

class _ExportState extends State<NikoDiagnosticsExportButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    String message;
    try {
      final path = await (widget.export ?? nikoExportDiagnostics)();
      if (path == null) return;
      message = nikoText('已保存诊断包。IP 地址、设备 ID 和会话编号已替换，不含密码、密钥、剪贴板或画面。',
          'Diagnostics saved. IP addresses, device IDs and session IDs are replaced; no password, key, clipboard or screen content is included.');
    } catch (_) {
      message = nikoText('导出失败，请选择可写的位置后重试。',
          'Export failed. Choose a writable location and retry.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) nikoNotice(context, message);
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
      key: const Key('nikodesk-export-diagnostics'),
      onPressed: _busy ? null : _run,
      icon: const Icon(Icons.description_outlined, size: 18),
      label: Text(nikoText('导出诊断包', 'Export diagnostics')));
}
