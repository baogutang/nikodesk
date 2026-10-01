import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

class NikoVirtualDriverReply {
  final String namespace, jobId, phase, reason;
  final bool ok, elevated, osSupported, joined;
  NikoVirtualDriverReply(this.namespace, this.jobId, this.phase, this.reason,
      this.ok, this.elevated, this.osSupported, this.joined);
  static const phases = {
    'idle',
    'checking',
    'awaiting_confirmation',
    'installing',
    'probing',
    'ready',
    'failed',
    'restart_required'
  };
  static NikoVirtualDriverReply? parse(String raw) {
    try {
      if (raw.length > 8192) return null;
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.keys.toSet().difference({
            'ok',
            'namespace',
            'job_id',
            'phase',
            'reason',
            'elevated',
            'os_supported',
            'joined'
          }).isNotEmpty) return null;
      for (final key in ['namespace', 'job_id', 'phase', 'reason']) {
        if (value[key] is! String) return null;
      }
      for (final key in ['ok', 'elevated', 'os_supported', 'joined']) {
        if (value[key] is! bool) return null;
      }
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value['namespace']) ||
          value['namespace'] == '0' * 64 ||
          !phases.contains(value['phase']) ||
          !RegExp(r'^[a-z_]{0,96}$').hasMatch(value['reason'])) return null;
      final id = value['job_id'] as String;
      if (id.isEmpty
          ? value['phase'] != 'idle'
          : !RegExp(r'^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$')
              .hasMatch(id)) return null;
      if (value['ok'] == true &&
          (value['phase'] != 'ready' ||
              value['elevated'] != true ||
              value['os_supported'] != true)) return null;
      return NikoVirtualDriverReply(
          value['namespace'],
          id,
          value['phase'],
          value['reason'],
          value['ok'],
          value['elevated'],
          value['os_supported'],
          value['joined']);
    } catch (_) {
      return null;
    }
  }

  bool get confirmed => ok && phase == 'ready' && joined;
  bool get running => jobId.isNotEmpty && !joined;
}

/// A native timeout retains the original operation until Status observes its
/// result; it never enables a second installation based on elapsed time.
class NikoVirtualDriver extends ChangeNotifier {
  final Future<String> Function(String) command;
  final String? Function() currentNamespace;
  final Duration timeout;
  NikoVirtualDriverReply? reply;
  String? notice;
  bool busy = false, uncertain = false, _disposed = false;
  int _generation = 0;
  NikoVirtualDriver(
      {required this.command,
      required this.currentNamespace,
      this.timeout = const Duration(seconds: 5)});
  bool get pending =>
      busy ||
      uncertain ||
      reply?.running == true ||
      reply?.reason == 'another_scope_busy';
  bool get canBegin =>
      !pending &&
      reply?.elevated == true &&
      reply?.osSupported == true &&
      reply?.namespace == currentNamespace();
  bool get needsRefresh =>
      uncertain ||
      reply?.running == true ||
      reply?.reason == 'another_scope_busy';

  Future<void> refresh() => _call('status');
  Future<void> probe() async {
    if (canBegin) await _call('probe');
  }

  Future<void> install(String infPath) async {
    if (!canBegin) return;
    if (utf8.encode(infPath).length >= 260 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(infPath) ||
        !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(infPath) ||
        infPath.replaceAll('\\', '/').split('/').last !=
            'NikoDeskIddDriver.inf') {
      notice = 'invalid_request';
      notifyListeners();
      return;
    }
    await _call('install', infPath: infPath);
  }

  Future<void> _call(String action, {String infPath = ''}) async {
    if (_disposed || busy) return;
    final namespace = currentNamespace();
    if (namespace == null) {
      notice = 'scope_changed';
      notifyListeners();
      return;
    }
    final generation = ++_generation;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      final raw = await command(jsonEncode({
        'action': action,
        'namespace': namespace,
        if (infPath.isNotEmpty) 'inf_path': infPath
      })).timeout(timeout);
      if (_disposed ||
          generation != _generation ||
          namespace != currentNamespace()) return;
      final parsed = NikoVirtualDriverReply.parse(raw);
      if (parsed == null || parsed.namespace != namespace) {
        throw const FormatException();
      }
      reply = parsed;
      uncertain = false;
      notice = parsed.reason.isEmpty || parsed.reason == 'unchecked'
          ? null
          : parsed.reason;
    } catch (_) {
      if (!_disposed &&
          generation == _generation &&
          namespace == currentNamespace()) {
        uncertain = true;
        notice = 'unconfirmed';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        busy = false;
        if (namespace != currentNamespace()) {
          reply = null;
          uncertain = true;
          notice = 'scope_changed';
        }
        notifyListeners();
      }
    }
  }

  void scopeChanged() {
    ++_generation;
    reply = null;
    busy = false;
    uncertain = true;
    notice = 'scope_changed';
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}
