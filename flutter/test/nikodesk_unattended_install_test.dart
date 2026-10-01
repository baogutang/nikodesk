import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/unattended_install.dart';
import 'package:flutter_test/flutter_test.dart';

const installJob = '11111111-1111-4111-8111-111111111111';
const otherInstallJob = '22222222-2222-4222-8222-222222222222';
final installNamespace = 'a' * 64;

String installReply(
        {String job = installJob,
        String? namespace,
        String phase = 'preparing',
        String reason = 'queued',
        bool ok = true,
        bool quiescent = false,
        bool processExited = false,
        bool taskJoined = false,
        String action = 'install',
        String? machineId}) =>
    jsonEncode({
      'action': action,
      'ok': ok,
      'job_id': job,
      'namespace': namespace ?? installNamespace,
      'phase': phase,
      'reason': reason,
      'quiescent': quiescent,
      'process_exited': processExited,
      'task_joined': taskJoined,
      'machine_id':
          machineId ?? (phase == 'complete' && quiescent ? '1234567890' : '')
    });

String installIdle() =>
    installReply(job: '', namespace: '', phase: 'idle', reason: 'idle');
String installComplete() => installReply(
    phase: 'complete',
    reason: 'complete',
    quiescent: true,
    processExited: true,
    taskJoined: true);

String installNoDispatch() => installReply(
    phase: 'launch_not_started',
    reason: 'launch_not_started',
    quiescent: true,
    processExited: true,
    taskJoined: true);

// Explicit transport substitute. No installer, credentials, native library,
// Windows services, permission prompt or system configuration is accessed.
class InstallTransportDouble implements NikoUnattendedInstallTransport {
  final calls = <String>[];
  final requests = <Map<String, dynamic>>[];
  Future<String> Function()? onCurrent;
  Future<String> Function(String)? onStatus, onCancel, onBegin;
  @override
  Future<String> current() async {
    calls.add('current');
    return onCurrent == null ? installIdle() : await onCurrent!();
  }

  @override
  Future<String> status(String jobId) async {
    calls.add('status:$jobId');
    return onStatus == null ? installReply() : await onStatus!(jobId);
  }

  @override
  Future<String> cancel(String jobId) async {
    calls.add('cancel:$jobId');
    return onCancel == null
        ? installReply(reason: 'cancel_requested')
        : await onCancel!(jobId);
  }

  @override
  Future<String> begin(String json) async {
    calls.add('begin');
    requests.add(jsonDecode(json));
    return onBegin == null ? installReply() : await onBegin!(json);
  }
}

NikoUnattendedInstall installModel(InstallTransportDouble transport,
        {Future<String?> Function()? readNamespace,
        String? Function()? currentNamespace,
        bool supported = true,
        Duration timeout = const Duration(seconds: 5)}) =>
    NikoUnattendedInstall(
        transport: transport,
        readNamespace: readNamespace ?? () async => installNamespace,
        currentNamespace: currentNamespace ?? () => installNamespace,
        supported: supported,
        timeout: timeout);

void main() {
  test(
      'password rotation preserves identity and requires its own completed task',
      () async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installComplete();
    transport.onBegin = (_) async =>
        installReply(job: otherInstallJob, action: 'change_password');
    final model = installModel(transport);
    addTearDown(model.dispose);
    await model.refresh();
    for (final password in ['', '   ', 'x' * 129]) {
      await model.begin(
          selectedSetup: r'C:\setup.exe',
          password: password,
          action: 'change_password');
    }
    await model.begin(
        selectedSetup: r'C:\setup.exe',
        password: 'synthetic-new-password',
        action: 'change_password',
        allowPrivacy: true);
    expect(transport.requests, isEmpty);
    await model.begin(
        selectedSetup: r'C:\setup.exe',
        password: 'synthetic-new-password',
        action: 'change_password',
        startAfterCommit: true);
    expect(transport.requests.single['action'], 'change_password');
    expect(transport.requests.single['password'], 'synthetic-new-password');
    expect(transport.requests.single['start_after_commit'], true);
    expect(transport.requests.single['allow_privacy'], false);
    expect(transport.requests.single['allow_virtual_display'], false);
    expect(transport.requests.single['lock_on_disconnect'], false);
    expect(transport.requests.single['allow_remote_restart'], false);
    expect(model.operationConfirmed, false);
    transport.onStatus = (_) async => installComplete();
    await model.refresh();
    expect(model.operationConfirmed, false);
    expect(model.reply!.action, 'change_password');
    transport.onStatus = (_) async => installReply(
        job: otherInstallJob,
        action: 'change_password',
        phase: 'complete',
        reason: 'complete',
        quiescent: true,
        processExited: true,
        taskJoined: true);
    await model.refresh();
    expect(model.operationConfirmed, true);
    expect(model.reply!.machineId, '1234567890');
  });
  test(
      'machine permission changes carry explicit choices and cannot carry credentials',
      () async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installComplete();
    transport.onBegin =
        (_) async => installReply(job: otherInstallJob, action: 'configure');
    final model = installModel(transport);
    addTearDown(model.dispose);
    await model.refresh();
    await model.begin(
        selectedSetup: r'C:\setup.exe',
        password: 'unexpected',
        action: 'configure');
    expect(transport.requests, isEmpty);
    await model.begin(
        selectedSetup: r'C:\setup.exe',
        password: '',
        action: 'configure',
        allowPrivacy: true,
        allowVirtualDisplay: true,
        lockOnDisconnect: false,
        allowRemoteRestart: true);
    expect(transport.requests.single['action'], 'configure');
    expect(transport.requests.single['password'], '');
    expect(transport.requests.single['allow_privacy'], true);
    expect(transport.requests.single['allow_virtual_display'], true);
    expect(transport.requests.single['lock_on_disconnect'], false);
    expect(transport.requests.single['allow_remote_restart'], true);
    expect(transport.requests.single['start_after_commit'], false);
    expect(model.operationConfirmed, false);
    expect(model.reply!.action, 'configure');
  });
  test(
      'incomplete install cleanup needs the original task and actual exit before a fresh install',
      () async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installReply(
          action: 'recover_install',
          phase: 'install_recovered',
          reason: 'install_recovered',
          quiescent: true,
          processExited: true,
          taskJoined: true);
    final model = installModel(transport);
    addTearDown(model.dispose);
    await model.refresh();
    expect(model.reply!.installRecovered, true);
    expect(model.installConfirmed, false);
    expect(model.canBegin, true);
    expect(model.cancellable, false);
    transport.onCurrent = () async => installReply(
        action: 'recover_install',
        phase: 'install_recovered',
        reason: 'install_recovered',
        quiescent: true,
        processExited: false,
        taskJoined: true);
    transport.onStatus = (_) => transport.onCurrent!();
    await model.refresh();
    expect(model.reply!.installRecovered, false);
    expect(model.canBegin, false);
    final forged = jsonDecode(installReply(
        action: 'remove',
        phase: 'install_recovered',
        reason: 'install_recovered',
        quiescent: true,
        processExited: true,
        taskJoined: true));
    expect(NikoUnattendedInstallReply.parse(jsonEncode(forged)), isNull);
  });
  test(
      'maintenance dispatch carries no credential, rejects policy mixing and never adopts a stale completed task',
      () async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installComplete();
    final model =
        installModel(transport, timeout: const Duration(milliseconds: 10));
    addTearDown(model.dispose);
    await model.refresh();
    expect(model.canManage, true);
    await model.begin(
        selectedSetup: r'C:\setup.exe',
        password: 'unexpected',
        action: 'remove');
    expect(transport.requests, isEmpty);
    await model.begin(
        selectedSetup: r'C:\setup.exe',
        password: '',
        action: 'stop',
        allowPrivacy: true);
    expect(transport.requests, isEmpty);
    final pending = Completer<String>();
    transport.onBegin = (_) => pending.future;
    await model.begin(
        selectedSetup: r'C:\setup.exe', password: '', action: 'remove');
    expect(transport.requests.single['password'], '');
    expect(transport.requests.single['action'], 'remove');
    expect(transport.requests.single['allow_privacy'], false);
    expect(model.canManage, false);
    await model.refresh();
    expect(model.uncertain, true);
    transport.onCurrent = () async => installReply(
        job: otherInstallJob,
        action: 'remove',
        phase: 'complete',
        reason: 'complete',
        quiescent: true,
        processExited: true,
        taskJoined: true);
    await model.refresh();
    expect(model.operationConfirmed, true);
    expect(model.installConfirmed, false);
    expect(model.cancellable, false);
    expect(model.canReinstall, true);
    expect(model.canBegin, true);
    pending.complete(installReply(job: otherInstallJob, action: 'remove'));
  });
  test(
      'maintenance replies are bound to the original action and require fresh matching private server',
      () async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installReply(action: 'stop');
    final model = installModel(transport);
    addTearDown(model.dispose);
    await model.refresh();
    transport.onStatus = (_) async => installComplete();
    await model.refresh();
    expect(model.uncertain, true);
    expect(model.reply!.action, 'stop');
    expect(model.operationConfirmed, false);
    final mismatched = installModel(InstallTransportDouble(),
        currentNamespace: () => 'b' * 64);
    addTearDown(mismatched.dispose);
    await mismatched.refresh();
    expect(mismatched.canManage, false);
    final value = jsonDecode(installComplete()) as Map<String, dynamic>;
    value['action'] = 'arbitrary';
    expect(NikoUnattendedInstallReply.parse(jsonEncode(value)), isNull);
  });
  test(
      'finished recovery permits explicit repair while unknown resource exit keeps maintenance disabled',
      () async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installReply(
          action: 'upgrade',
          phase: 'recovery_disabled',
          reason: 'recovery_required',
          quiescent: true,
          processExited: true,
          taskJoined: true);
    final model = installModel(transport);
    addTearDown(model.dispose);
    await model.refresh();
    expect(model.operationConfirmed, false);
    expect(model.canManage, true);
    expect(model.cancellable, false);
    transport.onBegin =
        (_) async => installReply(job: otherInstallJob, action: 'repair');
    await model.begin(
        selectedSetup: r'C:\setup.exe', password: '', action: 'repair');
    expect(transport.requests.single['action'], 'repair');
    transport.onStatus = (_) async => installReply(
        job: otherInstallJob,
        action: 'repair',
        phase: 'recovery',
        reason: 'recovery_required');
    await model.refresh();
    expect(model.canManage, false);
    expect(model.cancellable, true);
  });
  test(
      'actual production Rust eight-reply serializer fixture cross-parses without system access',
      () async {
    final fixtures = jsonDecode(File(
            '../../artifacts/m7-feature-implementation/latest-install-status-fixture.json')
        .readAsStringSync()) as List;
    expect(fixtures, hasLength(8));
    final parsed = fixtures
        .map((value) => NikoUnattendedInstallReply.parse(jsonEncode(value)))
        .toList();
    expect(parsed.every((value) => value != null), true);
    expect(parsed.where((value) => value!.confirmed), hasLength(1));
    expect(parsed[3]!.confirmed, false);
    expect(parsed[4]!.confirmed, true);
    expect(parsed[7]!.notDispatched, true);
    final transport = InstallTransportDouble()
      ..onCurrent = () async => jsonEncode(fixtures[2]);
    final model = installModel(transport);
    addTearDown(model.dispose);
    await model.refresh();
    for (final patch in [
      {'job_id': otherInstallJob},
      {'namespace': 'b' * 64}
    ]) {
      transport.onStatus = (_) async => jsonEncode({...fixtures[4], ...patch});
      await model.refresh();
      expect(model.installConfirmed, false);
      expect(model.reply!.jobId, parsed[2]!.jobId);
    }
    transport.onStatus = (_) async => jsonEncode(fixtures[3]);
    await model.refresh();
    expect(model.installConfirmed, false);
    transport.onStatus = (_) async => jsonEncode(fixtures[4]);
    await model.refresh();
    expect(model.installConfirmed, true);
  });
  test(
      'only verified no-dispatch terminal proof permits explicit installer retry with a new UUID',
      () async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installNoDispatch();
    var reads = 0;
    final model = installModel(transport, readNamespace: () async {
      reads++;
      return installNamespace;
    });
    addTearDown(model.dispose);
    await model.refresh();
    expect(model.canBegin, true);
    expect(model.canRetryWithoutLaunch, true);
    expect(model.cancellable, false);
    final pending = Completer<String>();
    transport.onBegin = (_) => pending.future;
    final retry = model.begin(
        selectedSetup: r'C:\different-setup.exe',
        password: 'synthetic',
        startAfterCommit: true);
    await Future<void>.delayed(Duration.zero);
    expect(model.reply!.jobId, installJob);
    expect(model.canBegin, false);
    pending.complete(installReply(job: otherInstallJob));
    await retry;
    expect(model.reply!.jobId, otherInstallJob);
    expect(reads, 2);
    expect(transport.requests.single['start_after_commit'], true);
  });
  test(
      'complete, recovery, missing no-dispatch proof and failed namespace read cannot restart',
      () async {
    for (final raw in [
      installComplete(),
      installReply(
          phase: 'recovery_disabled',
          reason: 'recovery_required',
          quiescent: true,
          processExited: true,
          taskJoined: true),
      installReply(
          phase: 'launch_not_started',
          reason: 'launch_not_started',
          quiescent: true,
          processExited: true)
    ]) {
      final transport = InstallTransportDouble()..onCurrent = () async => raw;
      final model = installModel(transport);
      await model.refresh();
      expect(model.canBegin, false);
      model.dispose();
    }
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installNoDispatch();
    final model = installModel(transport, readNamespace: () async => null);
    addTearDown(model.dispose);
    await model.refresh();
    expect(model.canBegin, false);
    expect(model.reply!.jobId, installJob);
  });
  test(
      'unknown retry retains old metadata; stale old UUID cannot unlock, actual Current recovers new attempt',
      () async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installNoDispatch();
    final pending = Completer<String>();
    transport.onBegin = (_) => pending.future;
    final model =
        installModel(transport, timeout: const Duration(milliseconds: 10));
    addTearDown(model.dispose);
    await model.refresh();
    await model.begin(selectedSetup: r'C:\new.exe', password: 'synthetic');
    expect(model.reply!.jobId, installJob);
    expect(model.canBegin, false);
    await model.refresh();
    expect(model.canBegin, false);
    expect(transport.calls.last, 'current');
    pending.complete(installReply(job: otherInstallJob));
    await Future<void>.delayed(Duration.zero);
    expect(model.reply!.jobId, installJob);
    expect(model.uncertain, true);
    transport.onCurrent = () async => installReply(job: otherInstallJob);
    await model.refresh();
    expect(model.reply!.jobId, otherInstallJob);
    expect(model.uncertain, false);
    expect(model.canBegin, false);
  });
  test(
      'strict eight-key parser rejects unknown phase/reason and secret error text',
      () {
    final valid = jsonDecode(installReply()) as Map<String, dynamic>;
    for (final patch in [
      {'unexpected': true},
      {'phase': 'Running'},
      {'reason': 'an arbitrary private error'},
      {'ok': 1},
      {'job_id': installJob.toUpperCase().replaceFirst('1111', 'ABCD')},
      {'namespace': 'A' * 64},
      {'namespace': '0' * 64},
      {'task_joined': 'true'}
    ]) {
      expect(NikoUnattendedInstallReply.parse(jsonEncode({...valid, ...patch})),
          isNull);
    }
    expect(NikoUnattendedInstallReply.parse('x' * 2049), isNull);
    expect(NikoUnattendedInstallReply.parse(installReply()), isNotNull);
  });
  test('empty Current is process-only idle and cannot carry resource proof',
      () {
    final idle = NikoUnattendedInstallReply.parse(installIdle())!;
    expect(idle.hasJob, false);
    expect(idle.confirmed, false);
    expect(
        NikoUnattendedInstallReply.parse(installReply(
            job: '',
            namespace: '',
            phase: 'idle',
            reason: 'idle',
            quiescent: true)),
        isNull);
    expect(
        NikoUnattendedInstallReply.parse(installReply(job: '', phase: 'idle')),
        isNull);
  });
  test(
      'complete needs real job plus all three resource proofs and query success',
      () {
    expect(
        NikoUnattendedInstallReply.parse(installComplete())!.confirmed, true);
    for (final flag in ['ok', 'quiescent', 'process_exited', 'task_joined']) {
      final map = jsonDecode(installComplete()) as Map<String, dynamic>;
      map[flag] = false;
      expect(
          NikoUnattendedInstallReply.parse(jsonEncode(map))?.confirmed ?? false,
          false);
    }
    expect(
        NikoUnattendedInstallReply.parse(installReply(
                phase: 'recovery',
                quiescent: true,
                processExited: true,
                taskJoined: true))!
            .confirmed,
        false);
  });
  test('setup must be explicit absolute Windows executable path', () {
    expect(nikoSelectedWindowsSetup(r'C:\downloads\NikoDesk-setup.exe'), true);
    expect(nikoSelectedWindowsSetup(r'\\machine\share\setup.exe'), true);
    for (final path in [
      'setup.exe',
      '/tmp/setup.exe',
      r'C:setup.exe',
      r'C:\downloads\setup.zip',
      'C:\\a\u0000.exe'
    ]) {
      expect(nikoSelectedWindowsSetup(path), false);
    }
  });
  test('unsupported platform never invokes transport or server configuration',
      () async {
    final transport = InstallTransportDouble();
    final model = installModel(transport,
        supported: false,
        readNamespace: () => throw StateError('must not read'));
    addTearDown(model.dispose);
    await model.refresh();
    await model.begin(selectedSetup: r'C:\setup.exe', password: 'synthetic');
    expect(transport.calls, isEmpty);
    expect(model.canBegin, false);
  });
  test(
      'explicit begin re-reads verified namespace and dispatches only known fields with permissions off by default',
      () async {
    final transport = InstallTransportDouble();
    var reads = 0;
    final model = installModel(transport, readNamespace: () async {
      reads++;
      return installNamespace;
    });
    addTearDown(model.dispose);
    expect(transport.calls, isEmpty);
    await model.refresh();
    expect(model.canBegin, true);
    await model.begin(selectedSetup: r'C:\setup.exe', password: 'synthetic');
    expect(reads, 2);
    expect(transport.requests.single.keys.toSet(), {
      'action',
      'expected_namespace',
      'selected_setup',
      'password',
      'start_after_commit',
      'allow_virtual_display',
      'lock_on_disconnect',
      'allow_privacy',
      'allow_remote_restart'
    });
    expect(transport.requests.single['start_after_commit'], false);
    expect(transport.requests.single['allow_remote_restart'], false);
    expect(model.hasJob, true);
    expect(model.installConfirmed, false);
    await model.begin(selectedSetup: r'C:\setup.exe', password: 'another');
    expect(transport.requests, hasLength(1));
    transport.onStatus = (_) async => installComplete();
    await model.refresh();
    expect(model.installConfirmed, true);
  });
  test('Begin complete-looking reply is not an anchored completed installation',
      () async {
    final transport = InstallTransportDouble()
      ..onBegin = (_) async => installComplete();
    final model = installModel(transport);
    addTearDown(model.dispose);
    await model.refresh();
    await model.begin(selectedSetup: r'C:\setup.exe', password: 'synthetic');
    expect(model.hasJob, false);
    expect(model.installConfirmed, false);
    expect(model.canBegin, false);
  });
  test('server changed before dispatch blocks Begin and requires a fresh read',
      () async {
    final transport = InstallTransportDouble();
    var ns = installNamespace;
    final model = installModel(transport,
        readNamespace: () async => ns, currentNamespace: () => ns);
    addTearDown(model.dispose);
    await model.refresh();
    ns = 'b' * 64;
    await model.begin(selectedSetup: r'C:\setup.exe', password: 'synthetic');
    expect(transport.requests, isEmpty);
    expect(model.feedback, 'private_server_changed');
    await model.refresh();
    expect(model.canBegin, true);
  });
  test('late configuration read cannot dispatch across current scope change',
      () async {
    final transport = InstallTransportDouble();
    var ns = installNamespace;
    final read = Completer<String?>();
    var reads = 0;
    final model = installModel(transport,
        readNamespace: () {
          return ++reads == 1 ? Future.value(ns) : read.future;
        },
        currentNamespace: () => ns);
    addTearDown(model.dispose);
    await model.refresh();
    final operation =
        model.begin(selectedSetup: r'C:\setup.exe', password: 'synthetic');
    ns = 'b' * 64;
    read.complete(installNamespace);
    await operation;
    expect(transport.requests, isEmpty);
    expect(model.canBegin, false);
  });
  test('busy reply cannot adopt another job; authoritative Current restores it',
      () async {
    final transport = InstallTransportDouble()
      ..onBegin = (_) async => installReply(
          job: otherInstallJob, namespace: 'b' * 64, ok: false, reason: 'busy');
    final model = installModel(transport);
    addTearDown(model.dispose);
    await model.refresh();
    await model.begin(selectedSetup: r'C:\setup.exe', password: 'synthetic');
    expect(model.hasJob, false);
    expect(model.feedback, 'busy');
    expect(model.canBegin, false);
    transport.onCurrent =
        () async => installReply(job: otherInstallJob, namespace: 'b' * 64);
    await model.refresh();
    expect(model.reply!.jobId, otherInstallJob);
    expect(model.differentServer, true);
    await model.cancel();
    expect(transport.calls.last, 'cancel:$otherInstallJob');
  });
  test(
      'restored original task remains queryable and cancellable after server changes',
      () async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installReply();
    final model = installModel(transport, currentNamespace: () => 'b' * 64);
    addTearDown(model.dispose);
    await model.refresh();
    expect(model.differentServer, true);
    expect(model.canBegin, false);
    await model.cancel();
    expect(model.cancelRequested, true);
    expect(model.installConfirmed, false);
    await model.refresh();
    expect(transport.calls.last, 'status:$installJob');
    expect(model.reply!.namespace, installNamespace);
  });
  test('mismatched job, changed namespace, unknown phase keep previous owner',
      () async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installReply();
    final model = installModel(transport);
    addTearDown(model.dispose);
    await model.refresh();
    for (final raw in [
      installReply(job: otherInstallJob),
      installReply(namespace: 'b' * 64),
      '{}'
    ]) {
      transport.onStatus = (_) async => raw;
      await model.refresh();
      expect(model.reply!.jobId, installJob);
      expect(model.reply!.namespace, installNamespace);
      expect(model.uncertain, true);
      expect(model.installConfirmed, false);
    }
  });
  test(
      'timeout and late Begin never mint an owner; Current can recover actual task',
      () async {
    final pending = Completer<String>();
    final transport = InstallTransportDouble()..onBegin = (_) => pending.future;
    final model =
        installModel(transport, timeout: const Duration(milliseconds: 10));
    addTearDown(model.dispose);
    await model.refresh();
    await model.begin(selectedSetup: r'C:\setup.exe', password: 'synthetic');
    expect(model.uncertain, true);
    expect(model.hasJob, false);
    expect(model.canBegin, false);
    await model.refresh();
    expect(model.uncertain, true);
    expect(model.canBegin, false);
    pending.complete(installComplete());
    await Future<void>.delayed(Duration.zero);
    expect(model.installConfirmed, false);
    expect(model.hasJob, false);
    transport.onCurrent = () async => installReply();
    await model.refresh();
    expect(model.hasJob, true);
  });
  test(
      'cancel timeout preserves original task; late receipt cannot confirm or clear it',
      () async {
    final pending = Completer<String>();
    final transport = InstallTransportDouble();
    transport.onCurrent = () async => installReply();
    transport.onCancel = (_) => pending.future;
    final model =
        installModel(transport, timeout: const Duration(milliseconds: 10));
    addTearDown(model.dispose);
    await model.refresh();
    await model.cancel();
    expect(model.hasJob, true);
    expect(model.uncertain, true);
    pending.complete(installComplete());
    await Future<void>.delayed(Duration.zero);
    expect(model.installConfirmed, false);
    expect(model.reply!.phase, 'preparing');
    transport.onStatus = (_) async => installComplete();
    await model.refresh();
    expect(model.installConfirmed, true);
  });
  test('cancel rejection is not reported as cancellation sent', () async {
    final transport = InstallTransportDouble();
    transport.onCurrent = () async => installReply();
    transport.onCancel =
        (_) async => installReply(ok: false, reason: 'unknown_job');
    final model = installModel(transport);
    addTearDown(model.dispose);
    await model.refresh();
    await model.cancel();
    expect(model.cancelRequested, false);
    expect(model.feedback, 'unknown_job');
    expect(model.hasJob, true);
  });
  test(
      'Current timeout/malformed disables duplicate Begin, overlaps bounded and disposal drops late read',
      () async {
    final pending = Completer<String>();
    final transport = InstallTransportDouble()
      ..onCurrent = () => pending.future;
    final model =
        installModel(transport, timeout: const Duration(milliseconds: 10));
    final first = model.refresh();
    await model.refresh();
    expect(transport.calls, ['current']);
    await first;
    expect(model.canBegin, false);
    expect(model.uncertain, true);
    pending.complete(installReply());
    await Future<void>.delayed(Duration.zero);
    expect(model.hasJob, false);
    final late = Completer<String>();
    transport.onCurrent = () => late.future;
    final second = model.refresh();
    model.dispose();
    late.complete(installComplete());
    await second;
    expect(model.hasJob, false);
    expect(model.installConfirmed, false);
  });
}
