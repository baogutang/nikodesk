import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'cm_capabilities.dart';

bool _fields(Map raw, Set<String> fields) =>
    raw.length == fields.length && raw.keys.toSet().containsAll(fields);
bool _decimal(dynamic value) =>
    value is String && NikoCapabilityIdentity.validEpoch(value);
bool _reason(dynamic value) =>
    value is String && RegExp(r'^[a-z][a-z0-9_]{0,95}$').hasMatch(value);

bool _allowedIp(InternetAddress ip) {
  final bytes = ip.rawAddress;
  return !bytes.every((b) => b == 0) &&
      (ip.type == InternetAddressType.IPv4
          ? !(bytes[0] >= 224 && bytes[0] <= 239) &&
              !bytes.every((b) => b == 255)
          : bytes[0] != 255 &&
              !(bytes.take(10).every((b) => b == 0) &&
                  bytes[10] == 255 &&
                  bytes[11] == 255));
}

String _canonicalIp(InternetAddress ip) {
  final bytes = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) return bytes.join('.');
  final words = List.generate(8, (i) => bytes[i * 2] * 256 + bytes[i * 2 + 1]);
  var start = -1, length = 1;
  for (var i = 0; i < words.length; i++) {
    if (words[i] != 0) continue;
    var end = i;
    while (end < words.length && words[end] == 0) {
      end++;
    }
    if (end - i > length) {
      start = i;
      length = end - i;
    }
    i = end - 1;
  }
  final text = words.map((w) => w.toRadixString(16)).toList();
  return start < 0
      ? text.join(':')
      : '${text.take(start).join(':')}::${text.skip(start + length).join(':')}';
}

class NikoTunnelAddress {
  final String value;
  final InternetAddress ip;
  final int port;
  const NikoTunnelAddress._(this.value, this.ip, this.port);
  bool get loopback => ip.isLoopback;

  static NikoTunnelAddress? parse(dynamic raw) {
    if (raw is! String || raw.length > 64) return null;
    final match = RegExp(r'^(?:\[([0-9a-f:.]+)\]|([0-9.]+)):([1-9][0-9]{0,4})$')
        .firstMatch(raw);
    if (match == null) return null;
    final host = match[1] ?? match[2]!;
    final ip = InternetAddress.tryParse(host);
    final port = int.tryParse(match[3]!);
    if (ip == null ||
        port == null ||
        port > 65535 ||
        (match[1] != null) != (ip.type == InternetAddressType.IPv6)) {
      return null;
    }
    if (!_allowedIp(ip) || _canonicalIp(ip) != host) return null;
    return NikoTunnelAddress._(raw, ip, port);
  }
}

class NikoTunnelTarget {
  final String host;
  final int port;
  const NikoTunnelTarget._(this.host, this.port);
  static NikoTunnelTarget? parse(dynamic raw) {
    if (raw is! Map ||
        !_fields(raw, {'host', 'port'}) ||
        raw['host'] is! String ||
        raw['host'].isEmpty ||
        raw['host'].length > 253 ||
        raw['port'] is! int ||
        raw['port'] < 1 ||
        raw['port'] > 65535) return null;
    final String host = raw['host'];
    if (!RegExp(r'^[a-z0-9.:-]+$').hasMatch(host)) return null;
    final ip = InternetAddress.tryParse(host);
    if (ip != null && (!_allowedIp(ip) || _canonicalIp(ip) != host)) {
      return null;
    }
    if (ip == null &&
        host.split('.').any((label) =>
            label.isEmpty ||
            label.length > 63 ||
            label.startsWith('-') ||
            label.endsWith('-') ||
            !RegExp(r'^[a-z0-9-]+$').hasMatch(label))) {
      return null;
    }
    return NikoTunnelTarget._(host, raw['port']);
  }

  String get label => host.contains(':') ? '[$host]:$port' : '$host:$port';
  bool same(NikoTunnelTarget other) => host == other.host && port == other.port;
}

class NikoTunnelStatus {
  final NikoCapabilityIdentity identity;
  final String phase, reason, revision, resourceEpoch;
  final NikoTunnelTarget target;
  final List<NikoTunnelAddress> addresses;
  final String? selectedAddress;
  final bool cleanupOnly;
  const NikoTunnelStatus._(
      this.identity,
      this.phase,
      this.reason,
      this.revision,
      this.resourceEpoch,
      this.target,
      this.addresses,
      this.selectedAddress,
      this.cleanupOnly);

  static NikoTunnelStatus? parse(String json) {
    if (json.length > 8192 || utf8.encode(json).length > 8192) return null;
    try {
      final raw = jsonDecode(json);
      if (raw is! Map ||
          !_fields(raw, {
            'identity',
            'kind',
            'phase',
            'reason',
            'revision',
            'resource_epoch',
            'target',
            'addresses',
            'selected_address',
            'cleanup_only'
          }) ||
          raw['kind'] != 'tunnel') return null;
      final identity = NikoCapabilityIdentity.parse(raw['identity']);
      final target = NikoTunnelTarget.parse(raw['target']);
      if (identity == null ||
          identity.connectionId > 2147483647 ||
          target == null ||
          !_decimal(raw['revision']) ||
          !_decimal(raw['resource_epoch']) ||
          !_reason(raw['reason']) ||
          !{
            'Pending',
            'Starting',
            'Running',
            'Revoking',
            'RecoveryRequired',
            'Stopped'
          }.contains(raw['phase']) ||
          raw['cleanup_only'] is! bool ||
          raw['addresses'] is! List ||
          raw['addresses'].length > 8) return null;
      final addresses = <NikoTunnelAddress>[];
      for (final value in raw['addresses']) {
        final address = NikoTunnelAddress.parse(value);
        if (address == null ||
            address.port != target.port ||
            addresses.any((a) => a.value == address.value)) return null;
        addresses.add(address);
      }
      final selected = raw['selected_address'];
      if ((selected != null &&
              (selected is! String ||
                  !addresses.any((a) => a.value == selected))) ||
          (raw['phase'] == 'Pending' && selected != null) ||
          ({'Starting', 'Running'}.contains(raw['phase']) &&
              selected == null)) {
        return null;
      }
      return NikoTunnelStatus._(
          identity,
          raw['phase'],
          raw['reason'],
          raw['revision'],
          raw['resource_epoch'],
          target,
          List.unmodifiable(addresses),
          selected,
          raw['cleanup_only']);
    } catch (_) {
      return null;
    }
  }

  bool sameSnapshot(NikoTunnelStatus other) =>
      identity.sameRequest(other.identity) &&
      phase == other.phase &&
      reason == other.reason &&
      revision == other.revision &&
      resourceEpoch == other.resourceEpoch &&
      target.same(other.target) &&
      selectedAddress == other.selectedAddress &&
      cleanupOnly == other.cleanupOnly &&
      listEquals(addresses.map((a) => a.value).toList(),
          other.addresses.map((a) => a.value).toList());
}

class NikoTunnelCommand {
  final NikoTunnelStatus captured;
  final String op;
  final NikoTunnelAddress? address;
  const NikoTunnelCommand._(this.captured, this.op, this.address);

  static NikoTunnelCommand? create(NikoTunnelStatus captured, String op,
      {String? address, bool allowNonLoopback = false}) {
    if (!{'resolve', 'approve', 'deny', 'revoke', 'query', 'retry_cleanup'}
        .contains(op)) return null;
    NikoTunnelAddress? selected;
    if (op == 'approve') {
      for (final candidate in captured.addresses) {
        if (candidate.value == address) selected = candidate;
      }
      if (selected == null || (!selected.loopback && !allowNonLoopback)) {
        return null;
      }
    } else if (address != null || allowNonLoopback) {
      return null;
    }
    final command = NikoTunnelCommand._(captured, op, selected);
    return utf8.encode(command.json).length <= 4096 ? command : null;
  }

  Map<String, dynamic> toJson() => {
        'identity': captured.identity.toJson(),
        'revision': captured.revision,
        'op': op,
        if (address != null) 'address': address!.value,
        if (address != null)
          'access': address!.loopback ? 'loopback' : 'non_loopback',
      };
  String get json => jsonEncode(toJson());
}

/// Actual Rust Reply has no status field. Queued is never a resource fact.
class NikoTunnelReply {
  final bool queued;
  final String reason;
  const NikoTunnelReply._(this.queued, this.reason);
  static NikoTunnelReply? parse(String json, NikoTunnelCommand command) {
    if (json.length > 4096 || utf8.encode(json).length > 4096) return null;
    try {
      final raw = jsonDecode(json);
      if (raw is! Map ||
          !_fields(raw, {'ok', 'reason', 'identity', 'revision'}) ||
          raw['ok'] is! bool ||
          !_reason(raw['reason']) ||
          raw['revision'] != command.captured.revision) return null;
      final identity = NikoCapabilityIdentity.parse(raw['identity']);
      if (identity == null ||
          !command.captured.identity.sameRequest(identity) ||
          raw['ok'] != (raw['reason'] == 'queued')) return null;
      return NikoTunnelReply._(raw['ok'], raw['reason']);
    } catch (_) {
      return null;
    }
  }
}

/// Supplied only by the CM producer after its native caller/context was verified.
/// Do not construct this context from an ordinary status event or current settings.
class NikoTunnelCmContext {
  final NikoCapabilityIdentity identity;
  final bool active, cleanupOnly;
  const NikoTunnelCmContext.verifiedNative(
      {required this.identity, this.active = true, this.cleanupOnly = false});
}

typedef NikoTunnelTransport = Future<String> Function(
    NikoTunnelCommand command);

class NikoCmTunnelModel extends ChangeNotifier {
  NikoTunnelStatus _status;
  final NikoTunnelTransport _transport;
  final Duration commandTimeout;
  bool _cleanupOnly, _active;
  bool _busy = false, _disposed = false;
  bool _cleanupUnconfirmed = false, _approvalUnconfirmed = false;
  bool _resolveUnconfirmed = false, _expired = false;
  int _serial = 0;
  String? _operationMessage, _approvedAddress;

  NikoCmTunnelModel.fromVerifiedContext(
      {required NikoTunnelCmContext context,
      required NikoTunnelStatus initialStatus,
      required NikoTunnelTransport transport,
      this.commandTimeout = const Duration(seconds: 5)})
      : _status = initialStatus,
        _transport = transport,
        _active = context.active,
        _cleanupOnly = context.cleanupOnly || !context.active,
        _approvedAddress = initialStatus.selectedAddress {
    if (NikoCapabilityIdentity.parse(context.identity.toJson()) == null ||
        !context.identity.sameRequest(initialStatus.identity) ||
        (initialStatus.cleanupOnly && !_cleanupOnly) ||
        commandTimeout <= Duration.zero ||
        commandTimeout > const Duration(seconds: 5)) {
      throw ArgumentError('A matching verified native CM context is required');
    }
    _cleanupUnconfirmed = _cleanupOnly && initialStatus.phase != 'Stopped';
  }

  NikoTunnelStatus get status => _status;
  bool get busy => _busy;
  bool get cleanupOnly => _cleanupOnly;
  bool get cleanupUnconfirmed => _cleanupUnconfirmed;
  bool get approvalUnconfirmed => _approvalUnconfirmed;
  bool get resolveUnconfirmed => _resolveUnconfirmed;
  String? get operationMessage => _operationMessage;
  bool get mayResolve =>
      !_disposed &&
      _active &&
      !_cleanupOnly &&
      !_busy &&
      !_cleanupUnconfirmed &&
      !_approvalUnconfirmed &&
      !_resolveUnconfirmed &&
      !_expired &&
      _status.phase == 'Pending' &&
      {
        'local_approval_required',
        'select_exact_address',
        'tunnel_resolution_failed'
      }.contains(_status.reason);
  bool mayApprove(String? address, {bool allowNonLoopback = false}) =>
      mayResolve &&
      _status.reason == 'select_exact_address' &&
      NikoTunnelCommand.create(_status, 'approve',
              address: address, allowNonLoopback: allowNonLoopback) !=
          null;
  bool isCurrent(NikoTunnelStatus captured) =>
      !_disposed && _status.sameSnapshot(captured);

  /// Only a trusted CM lifecycle update can retire a row, never event JSON.
  bool updateContext(NikoTunnelCmContext context) {
    if (_disposed || !_status.identity.sameRequest(context.identity)) {
      return false;
    }
    final retire = context.cleanupOnly || !context.active;
    if (!retire || _cleanupOnly) return true;
    _active = false;
    _cleanupOnly = true;
    _cleanupUnconfirmed = _status.phase != 'Stopped';
    ++_serial;
    _busy = false;
    _operationMessage = null;
    notifyListeners();
    return true;
  }

  bool applyStatus(NikoTunnelStatus value) {
    if (_disposed ||
        !_status.identity.sameRequest(value.identity) ||
        !_status.target.same(value.target) ||
        BigInt.parse(value.revision) < BigInt.parse(_status.revision) ||
        BigInt.parse(value.resourceEpoch) <
            BigInt.parse(_status.resourceEpoch) ||
        (value.revision == _status.revision && !_status.sameSnapshot(value)) ||
        (value.cleanupOnly && !_cleanupOnly) ||
        !_mayTransition(value.phase) ||
        (value.selectedAddress != null &&
            _approvedAddress != null &&
            value.selectedAddress != _approvedAddress)) return false;
    if (_status.sameSnapshot(value)) return true;
    _status = value;
    ++_serial;
    _busy = false;
    _operationMessage = null;
    _expired = value.reason == 'tunnel_request_expired';
    _resolveUnconfirmed =
        value.phase == 'Pending' && value.reason == 'resolving';
    _approvalUnconfirmed = false;
    if (value.phase == 'Pending') _approvedAddress = null;
    _approvedAddress ??= value.selectedAddress;
    if (value.phase == 'Stopped') _cleanupUnconfirmed = false;
    notifyListeners();
    return true;
  }

  bool _mayTransition(String after) => switch (_status.phase) {
        'Pending' => true,
        'Starting' => after != 'Pending',
        'Running' => !{'Pending', 'Starting'}.contains(after),
        'Revoking' ||
        'RecoveryRequired' =>
          {'Revoking', 'RecoveryRequired', 'Stopped'}.contains(after),
        'Stopped' => after == 'Stopped',
        _ => false,
      };
  bool maySend(String op) {
    if (_disposed || _busy) return false;
    if (op == 'query') return true;
    if (_cleanupOnly || _expired) {
      return op == 'retry_cleanup' &&
          (_cleanupUnconfirmed || _status.phase != 'Stopped');
    }
    return switch (op) {
      'resolve' => mayResolve,
      'deny' => _status.phase == 'Pending',
      'revoke' => {'Starting', 'Running', 'Revoking'}.contains(_status.phase),
      'retry_cleanup' => _cleanupUnconfirmed ||
          {'Revoking', 'RecoveryRequired'}.contains(_status.phase),
      _ => false,
    };
  }

  Future<bool> send(String op,
      {String? address,
      bool allowNonLoopback = false,
      NikoTunnelStatus? captured}) async {
    if (captured != null && !isCurrent(captured)) return false;
    if (op == 'approve'
        ? !mayApprove(address, allowNonLoopback: allowNonLoopback)
        : !maySend(op)) return false;
    final before = _status;
    final command = NikoTunnelCommand.create(before, op,
        address: address, allowNonLoopback: allowNonLoopback);
    if (command == null) return false;
    final serial = ++_serial;
    _busy = true;
    _operationMessage = null;
    if (op == 'resolve') _resolveUnconfirmed = true;
    if (op == 'approve') {
      _approvalUnconfirmed = true;
      _approvedAddress = address;
    }
    if ({'deny', 'revoke', 'retry_cleanup'}.contains(op)) {
      _cleanupUnconfirmed = true;
    }
    notifyListeners();
    try {
      final raw = await _transport(command).timeout(commandTimeout);
      if (_disposed || serial != _serial || !isCurrent(before)) return false;
      final reply = NikoTunnelReply.parse(raw, command);
      _operationMessage =
          reply == null ? 'operation_unconfirmed' : reply.reason;
      if (reply?.reason == 'tunnel_request_expired') _expired = true;
      return reply?.queued == true;
    } on TimeoutException {
      if (!_disposed && serial == _serial) {
        _operationMessage = 'operation_unconfirmed';
      }
      return false;
    } catch (_) {
      if (!_disposed && serial == _serial) {
        _operationMessage = 'channel_unavailable';
      }
      return false;
    } finally {
      if (!_disposed && serial == _serial) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_serial;
    super.dispose();
  }
}
