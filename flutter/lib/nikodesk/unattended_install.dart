import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

abstract class NikoUnattendedInstallTransport {
  Future<String> begin(String json);
  Future<String> status(String jobId);
  Future<String> cancel(String jobId);
  Future<String> current();
}

class NikoUnattendedInstallReply {
  static const actions = {
    'install',
    'stop',
    'resume',
    'remove',
    'upgrade',
    'repair',
    'recover_install',
    'configure',
    'change_password'
  };
  static const phases = {
    'idle',
    'preparing',
    'awaiting_native_confirmation',
    'preflight',
    'roots',
    'journal',
    'payload',
    'disabled_service',
    'profile',
    'verify',
    'consent',
    'auto_start',
    'started',
    'complete',
    'recovery',
    'recovery_disabled',
    'install_recovered',
    'recovery_unconfirmed',
    'launch_not_started'
  };
  static const reasons = {
    'idle',
    'queued',
    'unknown_job',
    'busy',
    'invalid_request',
    'unsupported',
    'private_server_unavailable',
    'private_server_changed',
    'cancel_requested',
    'in_progress',
    'complete',
    'install_recovered',
    'launch_not_started',
    'recovery_required',
    'unconfirmed'
  };
  final bool ok, quiescent, processExited, taskJoined;
  final String jobId, namespace, phase, reason, machineId, action;
  const NikoUnattendedInstallReply._(
      this.ok,
      this.jobId,
      this.namespace,
      this.phase,
      this.reason,
      this.quiescent,
      this.processExited,
      this.taskJoined,
      this.machineId,
      this.action);

  bool get hasJob => jobId.isNotEmpty;
  bool get confirmed =>
      hasJob &&
      ok &&
      phase == 'complete' &&
      quiescent &&
      processExited &&
      taskJoined &&
      RegExp(r'^[1-9][0-9]{9}$').hasMatch(machineId);
  bool get notDispatched =>
      ok &&
      hasJob &&
      phase == 'launch_not_started' &&
      {
        'launch_not_started',
        'private_server_unavailable',
        'private_server_changed',
        'invalid_request'
      }.contains(reason) &&
      quiescent &&
      processExited &&
      taskJoined;
  bool sameJob(NikoUnattendedInstallReply other) =>
      // Action is part of task identity; a late installation acknowledgement
      // cannot complete an uninstall or update.
      hasJob &&
      jobId == other.jobId &&
      namespace == other.namespace &&
      action == other.action;
  bool get recoveryFinished =>
      hasJob &&
      ok &&
      phase == 'recovery_disabled' &&
      quiescent &&
      processExited &&
      taskJoined;
  bool get installRecovered =>
      hasJob &&
      ok &&
      phase == 'install_recovered' &&
      {'install', 'recover_install'}.contains(action) &&
      machineId.isEmpty &&
      quiescent &&
      processExited &&
      taskJoined;

  static String? validNamespace(Object? value) => value is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(value) &&
          value != '0' * 64
      ? value
      : null;

  static NikoUnattendedInstallReply? parse(String raw) {
    if (raw.length > 2048 || utf8.encode(raw).length > 2048) return null;
    try {
      final value = jsonDecode(raw);
      const keys = {
        'ok',
        'job_id',
        'namespace',
        'phase',
        'reason',
        'quiescent',
        'process_exited',
        'task_joined',
        'machine_id',
        'action'
      };
      if (value is! Map ||
          value.length < keys.length - 2 ||
          value.length > keys.length ||
          !value.keys.every(keys.contains) ||
          value['ok'] is! bool ||
          value['quiescent'] is! bool ||
          value['process_exited'] is! bool ||
          value['task_joined'] is! bool ||
          !phases.contains(value['phase']) ||
          !reasons.contains(value['reason'])) return null;
      final id = value['job_id'], namespace = value['namespace'];
      final machineId = value['machine_id'] ?? '';
      final action = value['action'] ?? 'install';
      if (!actions.contains(action)) return null;
      if (value['phase'] == 'install_recovered' &&
          !{'install', 'recover_install'}.contains(action)) return null;
      if (machineId is! String ||
          (machineId.isNotEmpty &&
              (value['phase'] != 'complete' ||
                  value['quiescent'] != true ||
                  !RegExp(r'^[1-9][0-9]{9}$').hasMatch(machineId)))) {
        return null;
      }
      if (id is! String || namespace is! String) return null;
      if (id.isEmpty) {
        if (namespace.isNotEmpty ||
            value['phase'] != 'idle' ||
            value['quiescent'] ||
            value['process_exited'] ||
            value['task_joined']) {
          return null;
        }
      } else if (!RegExp(
                  r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')
              .hasMatch(id) ||
          id == '00000000-0000-0000-0000-000000000000' ||
          validNamespace(namespace) == null ||
          value['phase'] == 'idle') {
        return null;
      }
      return NikoUnattendedInstallReply._(
          value['ok'],
          id,
          namespace,
          value['phase'],
          value['reason'],
          value['quiescent'],
          value['process_exited'],
          value['task_joined'],
          machineId,
          action);
    } catch (_) {
      return null;
    }
  }
}

bool nikoSelectedWindowsSetup(String path) =>
    path.length <= 4096 &&
    utf8.encode(path).length <= 4096 &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(path) &&
    RegExp(r'^(?:[a-zA-Z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+[\\/])')
        .hasMatch(path) &&
    path.toLowerCase().endsWith('.exe');

/// Native owns installation and its resources. This model never persists an
/// installer password or treats an empty Current response as a system audit.
class NikoUnattendedInstall extends ChangeNotifier {
  final NikoUnattendedInstallTransport transport;
  final Future<String?> Function() readNamespace;
  final String? Function() currentNamespace;
  final bool supported;
  final Duration timeout;
  NikoUnattendedInstallReply? _reply;
  String? _namespace;
  String _feedback = 'idle';
  bool _busy = false,
      _readConfirmed = false,
      _beginUnconfirmed = false,
      _uncertain = false,
      _cancelRequested = false,
      _recoverBusy = false,
      _disposed = false;
  String? _retryFromJob, _requestedAction;
  int _operation = 0;

  NikoUnattendedInstall(
      {required this.transport,
      required this.readNamespace,
      required this.currentNamespace,
      this.supported = true,
      this.timeout = const Duration(seconds: 5)});

  NikoUnattendedInstallReply? get reply => _reply;
  String? get namespace => _namespace;
  String get feedback => supported ? _feedback : 'unsupported';
  bool get busy => _busy;
  bool get uncertain => _uncertain;
  bool get cancelRequested => _cancelRequested;
  bool get hasJob => _reply?.hasJob == true;
  bool get operationConfirmed => _reply?.confirmed == true;
  bool get installConfirmed =>
      operationConfirmed && _reply?.action == 'install';
  bool get canReinstall =>
      (operationConfirmed && _reply?.action == 'remove') ||
      _reply?.installRecovered == true;
  bool get canRetryWithoutLaunch =>
      _reply?.notDispatched == true && !_beginUnconfirmed;
  bool get cancellable =>
      hasJob &&
      !operationConfirmed &&
      _reply?.recoveryFinished != true &&
      _reply?.installRecovered != true &&
      _reply?.notDispatched != true;
  bool get differentServer => hasJob && currentNamespace() != _reply!.namespace;
  bool get canBegin =>
      supported &&
      !_busy &&
      _readConfirmed &&
      !_uncertain &&
      (!hasJob || canRetryWithoutLaunch || canReinstall) &&
      _namespace != null &&
      ((_feedback == 'idle' && !hasJob) ||
          canRetryWithoutLaunch ||
          canReinstall);
  bool get canManage =>
      supported &&
      !_busy &&
      _readConfirmed &&
      !_uncertain &&
      !_beginUnconfirmed &&
      _namespace != null &&
      currentNamespace() == _namespace &&
      (!hasJob ||
          operationConfirmed ||
          _reply?.recoveryFinished == true ||
          _reply?.installRecovered == true ||
          canRetryWithoutLaunch);

  bool _valid(int operation) => !_disposed && _operation == operation;
  int _start() {
    _busy = true;
    final serial = ++_operation;
    notifyListeners();
    return serial;
  }

  void _finish(int serial) {
    if (!_valid(serial)) return;
    _busy = false;
    notifyListeners();
  }

  void _unconfirmed() {
    _uncertain = true;
    _feedback = 'unconfirmed';
  }

  void _accept(NikoUnattendedInstallReply reply) {
    _reply = reply;
    _beginUnconfirmed = false;
    _retryFromJob = null;
    _requestedAction = null;
    _recoverBusy = false;
    _uncertain = !reply.ok ||
        reply.reason == 'unconfirmed' ||
        (reply.phase == 'complete' && !reply.confirmed);
    _feedback = reply.phase == 'complete' && !reply.confirmed
        ? 'unconfirmed'
        : reply.reason;
  }

  Future<void> refresh() async {
    if (_disposed || _busy || !supported) return;
    final serial = _start(), original = _reply;
    try {
      final recoveringRetry = _beginUnconfirmed && _retryFromJob != null;
      final raw =
          await (!recoveringRetry && !_recoverBusy && original?.hasJob == true
                  ? transport.status(original!.jobId)
                  : transport.current())
              .timeout(timeout);
      if (!_valid(serial)) return;
      final reply = NikoUnattendedInstallReply.parse(raw);
      if (_recoverBusy) {
        if (reply != null && reply.ok && reply.hasJob) {
          _readConfirmed = true;
          _accept(reply);
        } else {
          _unconfirmed();
        }
        return;
      }
      if (_beginUnconfirmed) {
        if (reply != null &&
            reply.hasJob &&
            reply.jobId != _retryFromJob &&
            reply.namespace == _namespace &&
            reply.action == _requestedAction) {
          _readConfirmed = true;
          _accept(reply);
        } else {
          _unconfirmed();
        }
        return;
      }
      if (reply == null ||
          (original?.hasJob == true && !original!.sameJob(reply))) {
        _unconfirmed();
      } else if (reply.hasJob) {
        _readConfirmed = true;
        _accept(reply);
        if (reply.notDispatched ||
            reply.confirmed ||
            reply.recoveryFinished ||
            reply.installRecovered) {
          final namespace = NikoUnattendedInstallReply.validNamespace(
              await readNamespace().timeout(timeout));
          if (!_valid(serial)) return;
          _namespace = namespace;
        }
      } else if (reply.ok && reply.reason == 'idle') {
        if (_beginUnconfirmed) {
          _unconfirmed();
          return;
        }
        _reply = reply;
        _readConfirmed = true;
        _uncertain = false;
        _feedback = 'idle';
        // Begin performs another reliable read immediately before dispatch.
        final namespace = NikoUnattendedInstallReply.validNamespace(
            await readNamespace().timeout(timeout));
        if (!_valid(serial)) return;
        _namespace = namespace;
      } else {
        _readConfirmed = false;
        _feedback = reply.reason;
        if (!reply.ok && reply.reason == 'busy') {
          _beginUnconfirmed = false;
          _recoverBusy = true;
        }
        _uncertain = reply.reason != 'unsupported';
      }
    } catch (_) {
      if (_valid(serial)) _unconfirmed();
    } finally {
      _finish(serial);
    }
  }

  Future<void> begin(
      {required String selectedSetup,
      required String password,
      bool startAfterCommit = false,
      bool allowVirtualDisplay = false,
      bool lockOnDisconnect = false,
      bool allowPrivacy = false,
      bool allowRemoteRestart = false,
      String action = 'install'}) async {
    if (!(action == 'install' ? canBegin : canManage)) return;
    if (!nikoSelectedWindowsSetup(selectedSetup) ||
        !NikoUnattendedInstallReply.actions.contains(action) ||
        ({'install', 'change_password'}.contains(action) &&
            password.trim().isEmpty) ||
        (!{'install', 'change_password'}.contains(action) &&
            password.isNotEmpty) ||
        (!{'install', 'configure', 'change_password'}.contains(action) &&
            startAfterCommit) ||
        (!{'install', 'configure'}.contains(action) &&
            (allowVirtualDisplay ||
                lockOnDisconnect ||
                allowPrivacy ||
                allowRemoteRestart)) ||
        password.runes.length > 128) {
      _feedback = 'invalid_request';
      notifyListeners();
      return;
    }
    final serial = _start(), expected = _namespace, original = _reply;
    try {
      final verified = NikoUnattendedInstallReply.validNamespace(
          await readNamespace().timeout(timeout));
      if (!_valid(serial)) return;
      if (verified == null ||
          verified != expected ||
          currentNamespace() != verified) {
        _namespace = verified;
        _feedback = verified == null
            ? 'private_server_unavailable'
            : 'private_server_changed';
        _readConfirmed = false;
        return;
      }
      _readConfirmed = false;
      _uncertain = true;
      _beginUnconfirmed = true;
      _cancelRequested = false;
      _retryFromJob = original?.hasJob == true ? original!.jobId : null;
      _requestedAction = action;
      final raw = await transport
          .begin(jsonEncode({
            'action': action,
            'expected_namespace': verified,
            'selected_setup': selectedSetup,
            'password': password,
            'start_after_commit': startAfterCommit,
            'allow_virtual_display': allowVirtualDisplay,
            'lock_on_disconnect': lockOnDisconnect,
            'allow_privacy': allowPrivacy,
            'allow_remote_restart': allowRemoteRestart
          }))
          .timeout(timeout);
      if (!_valid(serial)) return;
      final reply = NikoUnattendedInstallReply.parse(raw);
      if (reply == null) {
        _unconfirmed();
      } else if (reply.ok &&
          reply.hasJob &&
          reply.action == action &&
          reply.namespace == verified &&
          reply.jobId != _retryFromJob &&
          reply.phase == 'preparing' &&
          reply.reason == 'queued') {
        _accept(reply);
      } else {
        // Busy may describe a pre-existing task on another server. Only
        // authoritative Current can restore that original task as our owner.
        _feedback = reply.reason;
        if (!reply.ok && reply.reason == 'busy') {
          _beginUnconfirmed = false;
          _recoverBusy = true;
        }
        if (!reply.hasJob &&
            !reply.ok &&
            {
              'invalid_request',
              'private_server_unavailable',
              'private_server_changed',
              'unsupported'
            }.contains(reply.reason)) {
          _beginUnconfirmed = false;
        }
      }
    } catch (_) {
      if (_valid(serial)) _unconfirmed();
    } finally {
      _finish(serial);
    }
  }

  Future<void> cancel() async {
    final original = _reply;
    if (_disposed || _busy || !cancellable) return;
    final serial = _start();
    try {
      final reply = NikoUnattendedInstallReply.parse(
          await transport.cancel(original!.jobId).timeout(timeout));
      if (!_valid(serial)) return;
      if (reply == null || !original.sameJob(reply)) {
        _unconfirmed();
      } else {
        _accept(reply);
        if (reply.ok &&
            reply.reason == 'cancel_requested' &&
            !reply.confirmed) {
          _cancelRequested = true;
          _feedback = 'cancel_requested';
        }
      }
    } catch (_) {
      if (_valid(serial)) _unconfirmed();
    } finally {
      _finish(serial);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _operation++;
    super.dispose();
  }
}
