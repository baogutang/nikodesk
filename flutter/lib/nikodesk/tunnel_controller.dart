import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum NikoTunnelPhase {
  connecting,
  waitingApproval,
  starting,
  listening,
  stopping,
  closed,
  failed,
  recoveryRequired
}

final _u64Max = BigInt.parse('18446744073709551615');
BigInt? _counter(dynamic value) {
  if (value is! String || !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(value)) {
    return null;
  }
  final parsed = BigInt.tryParse(value);
  return parsed != null && parsed <= _u64Max ? parsed : null;
}

bool _keys(Map<dynamic, dynamic> value, Set<String> expected) =>
    value.length == expected.length && value.keys.every(expected.contains);
bool _port(dynamic value) => value is int && value > 0 && value <= 65535;
bool _namespace(dynamic value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
bool _peer(dynamic value) =>
    value is String && RegExp(r'^[0-9]{6,16}$').hasMatch(value);
bool _reason(dynamic value) =>
    value is String && RegExp(r'^[a-z0-9_]{1,96}$').hasMatch(value);

/// A host is a DNS name or IP literal, never a URL, command, or host:port pair.
String? nikoTunnelHost(String value) {
  var host = value.trim();
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  final ip = InternetAddress.tryParse(host);
  if (ip != null) return ip.address.toLowerCase();
  host = host.toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (host.isEmpty ||
      host.length > 253 ||
      !RegExp(r'^[a-z0-9.-]+$').hasMatch(host)) return null;
  if (host.split('.').any((part) =>
      part.isEmpty ||
      part.length > 63 ||
      part.startsWith('-') ||
      part.endsWith('-'))) return null;
  return host;
}

class NikoTunnelTarget {
  final String host;
  final int port;
  const NikoTunnelTarget(this.host, this.port);
  String get label => '${host.contains(':') ? '[$host]' : host}:$port';
  bool same(NikoTunnelTarget other) => host == other.host && port == other.port;
}

/// Facts from this FFI's original native stream. No command reply creates one.
class NikoTunnelStatus {
  final String namespace, peerId, generation, revision, reason;
  final int localPort;
  final NikoTunnelTarget target;
  final NikoTunnelPhase phase;
  final String? remotePhase;
  final bool localResourcesClosed;
  const NikoTunnelStatus(
      {required this.namespace,
      required this.peerId,
      required this.localPort,
      required this.target,
      required this.generation,
      required this.revision,
      required this.phase,
      required this.reason,
      required this.remotePhase,
      required this.localResourcesClosed});

  static NikoTunnelStatus? parse(String raw) {
    if (raw.length > 8192 || utf8.encode(raw).length > 8192) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map ||
          !_keys(map, {
            'namespace',
            'peer_id',
            'local_port',
            'target',
            'generation',
            'revision',
            'phase',
            'reason',
            'remote_phase',
            'local_resources_closed'
          })) return null;
      final target = map['target'];
      if (!_namespace(map['namespace']) ||
          !_peer(map['peer_id']) ||
          !_port(map['local_port']) ||
          _counter(map['generation']) == null ||
          _counter(map['revision']) == null ||
          !_reason(map['reason']) ||
          map['local_resources_closed'] is! bool ||
          target is! Map ||
          !_keys(target, {'host', 'port'}) ||
          target['host'] is! String ||
          !_port(target['port'])) return null;
      final host = nikoTunnelHost(target['host']);
      if (host == null || host != target['host']) return null;
      final phases = NikoTunnelPhase.values.where((phase) =>
          '${phase.name[0].toUpperCase()}${phase.name.substring(1)}' ==
          map['phase']);
      if (phases.length != 1) return null;
      final remote = map['remote_phase'];
      if (remote != null &&
          !{
            'Pending',
            'Starting',
            'Running',
            'Revoking',
            'RecoveryRequired',
            'Stopped'
          }.contains(remote)) return null;
      final phase = phases.single;
      final closed = map['local_resources_closed'] as bool;
      if (closed &&
          phase != NikoTunnelPhase.closed &&
          phase != NikoTunnelPhase.failed) return null;
      return NikoTunnelStatus(
          namespace: map['namespace'],
          peerId: map['peer_id'],
          localPort: map['local_port'],
          target: NikoTunnelTarget(host, target['port']),
          generation: map['generation'],
          revision: map['revision'],
          phase: phase,
          reason: map['reason'],
          remotePhase: remote,
          localResourcesClosed: closed);
    } catch (_) {
      return null;
    }
  }

  bool same(NikoTunnelStatus other) =>
      namespace == other.namespace &&
      peerId == other.peerId &&
      localPort == other.localPort &&
      target.same(other.target) &&
      generation == other.generation &&
      revision == other.revision &&
      phase == other.phase &&
      reason == other.reason &&
      remotePhase == other.remotePhase &&
      localResourcesClosed == other.localResourcesClosed;
  bool get reusable =>
      localResourcesClosed &&
      (phase == NikoTunnelPhase.closed || phase == NikoTunnelPhase.failed);
}

class NikoTunnelCommand {
  final String namespace, peerId, op;
  final int localPort;
  final NikoTunnelTarget? target;
  NikoTunnelCommand._(
      this.namespace, this.peerId, this.op, this.localPort, this.target);
  static NikoTunnelCommand? add(String namespace, String peerId, int localPort,
      String host, int remotePort) {
    final normalized = nikoTunnelHost(host);
    if (!_namespace(namespace) ||
        !_peer(peerId) ||
        !_port(localPort) ||
        !_port(remotePort) ||
        normalized == null) return null;
    return NikoTunnelCommand._(namespace, peerId, 'add', localPort,
        NikoTunnelTarget(normalized, remotePort));
  }

  static NikoTunnelCommand? remove(
          String namespace, String peerId, int localPort) =>
      _namespace(namespace) && _peer(peerId) && _port(localPort)
          ? NikoTunnelCommand._(namespace, peerId, 'remove', localPort, null)
          : null;
  String get json => jsonEncode({
        'namespace': namespace,
        'peer_id': peerId,
        'op': op,
        'local_port': localPort,
        if (target != null) 'host': target!.host,
        if (target != null) 'remote_port': target!.port
      });
}

enum NikoTunnelRequestState { sending, queued, unconfirmed, rejected }

class NikoTunnelRequest {
  final NikoTunnelCommand command;
  final String? previousGeneration;
  final NikoTunnelTarget? target;
  final NikoTunnelRequestState state;
  final String reason;
  const NikoTunnelRequest(this.command, this.previousGeneration, this.state,
      this.reason, this.target);
  NikoTunnelRequest result(NikoTunnelRequestState state, String reason) =>
      NikoTunnelRequest(command, previousGeneration, state, reason, target);
}

class NikoTunnelController extends ChangeNotifier {
  final String contextKey, namespace, peerId;
  final bool Function() isCurrent;
  final Duration commandTimeout;
  final Map<int, NikoTunnelStatus> _statuses = {};
  final Map<int, NikoTunnelRequest> _requests = {};
  bool _disposed = false;
  bool _invalid = false;
  int _serial = 0;
  bool _busy = false;
  NikoTunnelController(
      {required this.contextKey,
      required this.namespace,
      required this.peerId,
      required this.isCurrent,
      this.commandTimeout = const Duration(seconds: 5)});
  bool get active => !_disposed && !_invalid && isCurrent();
  bool get busy => _busy;
  Map<int, NikoTunnelStatus> get statuses => Map.unmodifiable(_statuses);
  Map<int, NikoTunnelRequest> get requests => Map.unmodifiable(_requests);
  bool canAdd(int port) =>
      active &&
      !_busy &&
      (_statuses[port] == null || _statuses[port]!.reusable) &&
      (_requests[port] == null ||
          _requests[port]!.state == NikoTunnelRequestState.rejected) &&
      (_statuses.containsKey(port) || _statuses.length + _requests.length < 64);

  void invalidate() {
    if (_disposed || _invalid) return;
    _invalid = true;
    _serial++;
    _busy = false;
    notifyListeners();
  }

  bool handleEvent(Map<String, dynamic> event) {
    if (!active ||
        event['name'] != 'nikodesk_tunnel_controller' ||
        event['status'] is! String) return false;
    final status = NikoTunnelStatus.parse(event['status']);
    if (status == null ||
        status.namespace != namespace ||
        status.peerId != peerId) return false;
    final previous = _statuses[status.localPort];
    if (previous != null) {
      final generation = _counter(status.generation)!
          .compareTo(_counter(previous.generation)!);
      if (generation < 0 ||
          (generation == 0 && !status.target.same(previous.target))) {
        return false;
      }
      if (generation == 0) {
        final revision =
            _counter(status.revision)!.compareTo(_counter(previous.revision)!);
        if (revision < 0 || (revision == 0 && !status.same(previous))) {
          return false;
        }
        if (revision == 0) return true;
        if (previous.reusable && !status.reusable) return false;
        const forward = [
          NikoTunnelPhase.connecting,
          NikoTunnelPhase.waitingApproval,
          NikoTunnelPhase.starting,
          NikoTunnelPhase.listening,
          NikoTunnelPhase.stopping
        ];
        if (forward.contains(previous.phase) &&
            forward.contains(status.phase) &&
            forward.indexOf(status.phase) < forward.indexOf(previous.phase)) {
          return false;
        }
        if ((previous.phase == NikoTunnelPhase.stopping ||
                previous.phase == NikoTunnelPhase.recoveryRequired) &&
            {
              NikoTunnelPhase.connecting,
              NikoTunnelPhase.waitingApproval,
              NikoTunnelPhase.starting,
              NikoTunnelPhase.listening
            }.contains(status.phase)) return false;
      } else if (!previous.reusable) {
        // A native new generation is authoritative about the new attempt;
        // it cannot certify the old attempt's cleanup. Native forbids overlap.
        return false;
      }
    } else if (_statuses.length >= 64) {
      return false;
    }
    _statuses[status.localPort] = status;
    final request = _requests[status.localPort];
    if (request != null) {
      final isNew = request.previousGeneration == null ||
          _counter(status.generation)! > _counter(request.previousGeneration)!;
      if ((request.command.op == 'add' &&
              isNew &&
              request.command.target!.same(status.target)) ||
          (request.command.op == 'remove' && status.reusable)) {
        _requests.remove(status.localPort);
      }
    }
    notifyListeners();
    return true;
  }

  /// This tracks request feedback only. Native events remain the resource facts.
  Future<void> send(NikoTunnelCommand command,
      Future<String> Function(NikoTunnelCommand) transport) async {
    if (!active ||
        _busy ||
        command.namespace != namespace ||
        command.peerId != peerId ||
        (command.op == 'add' && !canAdd(command.localPort))) return;
    if (command.op == 'remove' &&
        !_statuses.containsKey(command.localPort) &&
        !_requests.containsKey(command.localPort)) return;
    final ticket = ++_serial;
    final request = NikoTunnelRequest(
        command,
        _statuses[command.localPort]?.generation,
        NikoTunnelRequestState.sending,
        'sending',
        command.target ??
            _statuses[command.localPort]?.target ??
            _requests[command.localPort]?.target);
    _requests[command.localPort] = request;
    _busy = true;
    notifyListeners();
    var state = NikoTunnelRequestState.unconfirmed;
    var reason = 'unconfirmed';
    try {
      final raw = await transport(command).timeout(commandTimeout);
      if (utf8.encode(raw).length <= 1024) {
        final reply = jsonDecode(raw);
        if (reply is Map &&
            _keys(reply, {'ok', 'reason'}) &&
            reply['ok'] is bool &&
            _reason(reply['reason'])) {
          if (reply['ok'] == true && reply['reason'] == 'queued') {
            state = NikoTunnelRequestState.queued;
            reason = 'queued';
          } else if (reply['ok'] == false && reply['reason'] != 'queued') {
            state = NikoTunnelRequestState.rejected;
            reason = reply['reason'];
          }
        }
      }
    } catch (_) {
      /* No raw transport errors or target data enter UI messages. */
    }
    if (!active || ticket != _serial) return;
    _busy = false;
    if (identical(_requests[command.localPort], request)) {
      _requests[command.localPort] = request.result(state, reason);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _serial++;
    super.dispose();
  }
}
