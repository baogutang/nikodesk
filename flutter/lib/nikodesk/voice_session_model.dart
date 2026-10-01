import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'cm_capabilities.dart';

bool _fields(Map raw, Set<String> allowed) =>
    raw.keys.toSet().difference(allowed).isEmpty;
bool _decimal(dynamic value) =>
    value is String && NikoCapabilityIdentity.validEpoch(value);
bool _token(dynamic value) =>
    value is String && NikoCapabilityIdentity.validNonce(value);
bool _reason(dynamic value) =>
    value is String && RegExp(r'^[a-z0-9_]{0,96}$').hasMatch(value);
bool _text(dynamic value, int limit, {bool empty = false}) =>
    value is String &&
    (empty || value.isNotEmpty) &&
    value.length <= limit &&
    utf8.encode(value).length <= limit &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
const _permissions = {
  'Unknown',
  'Authorized',
  'NotDetermined',
  'Denied',
  'Restricted',
  'Unavailable'
};

class NikoVoiceFormat {
  final String token, schema;
  final int channels;
  const NikoVoiceFormat._(this.token, this.schema, this.channels);
  static NikoVoiceFormat? parse(dynamic raw) {
    if (raw is! Map ||
        !_fields(raw, {
          'format_token',
          'sample_rate',
          'sample_format',
          'channels',
          'format_schema'
        }) ||
        !_token(raw['format_token']) ||
        raw['sample_rate'] is! int ||
        raw['sample_rate'] != 48000 ||
        raw['sample_format'] != 'f32' ||
        raw['channels'] is! int ||
        !{1, 2}.contains(raw['channels']) ||
        !{
          'coreaudio-client-v1',
          'wasapi-shared-client-v1',
          'android_client_pcm_f32_48k_mono_v1'
        }.contains(raw['format_schema']) ||
        (raw['format_schema'] == 'android_client_pcm_f32_48k_mono_v1' &&
            raw['channels'] != 1)) return null;
    return NikoVoiceFormat._(
        raw['format_token'], raw['format_schema'], raw['channels']);
  }
}

class NikoVoiceDevice {
  final String token, uid, label, direction;
  final List<NikoVoiceFormat> formats;
  const NikoVoiceDevice._(
      this.token, this.uid, this.label, this.direction, this.formats);
  static NikoVoiceDevice? parse(dynamic raw) {
    if (raw is! Map ||
        !_fields(
            raw, {'device_token', 'uid', 'label', 'direction', 'formats'}) ||
        !_token(raw['device_token']) ||
        !_text(raw['uid'], 8192) ||
        !_text(raw['label'], 1024, empty: true) ||
        !{'capture', 'playback'}.contains(raw['direction']) ||
        raw['formats'] is! List ||
        raw['formats'].length > 2) return null;
    final formats = <NikoVoiceFormat>[];
    for (final value in raw['formats']) {
      final format = NikoVoiceFormat.parse(value);
      if (format == null || formats.any((f) => f.token == format.token)) {
        return null;
      }
      formats.add(format);
    }
    return NikoVoiceDevice._(raw['device_token'], raw['uid'], raw['label'],
        raw['direction'], List.unmodifiable(formats));
  }
}

class NikoVoiceSelection {
  final String rosterRevision;
  final String captureToken, captureFormatToken;
  final String playbackToken, playbackFormatToken;
  const NikoVoiceSelection._(this.rosterRevision, this.captureToken,
      this.captureFormatToken, this.playbackToken, this.playbackFormatToken);
  static NikoVoiceSelection? parse(dynamic raw) {
    if (raw is! Map ||
        !_fields(raw, {
          'roster_revision',
          'capture_token',
          'capture_format_token',
          'playback_token',
          'playback_format_token'
        }) ||
        !_decimal(raw['roster_revision']) ||
        !_token(raw['capture_token']) ||
        !_token(raw['capture_format_token']) ||
        !_token(raw['playback_token']) ||
        !_token(raw['playback_format_token']) ||
        raw['capture_token'] == raw['playback_token']) return null;
    return NikoVoiceSelection._(
        raw['roster_revision'],
        raw['capture_token'],
        raw['capture_format_token'],
        raw['playback_token'],
        raw['playback_format_token']);
  }

  Map<String, dynamic> toJson() => {
        'roster_revision': rosterRevision,
        'capture_token': captureToken,
        'capture_format_token': captureFormatToken,
        'playback_token': playbackToken,
        'playback_format_token': playbackFormatToken,
      };
  bool same(NikoVoiceSelection? other) =>
      other != null &&
      rosterRevision == other.rosterRevision &&
      captureToken == other.captureToken &&
      captureFormatToken == other.captureFormatToken &&
      playbackToken == other.playbackToken &&
      playbackFormatToken == other.playbackFormatToken;
}

class NikoVoiceStatus {
  final NikoCapabilityIdentity identity;
  final String revision, resourceEpoch, phase, reason, microphonePermission;
  final String callNonce, callEpoch;
  final bool muted, localReady, peerAccepted, callRunning, cleanupOnly;
  final NikoVoiceSelection? selection;
  const NikoVoiceStatus._(
      this.identity,
      this.revision,
      this.resourceEpoch,
      this.phase,
      this.reason,
      this.microphonePermission,
      this.callNonce,
      this.callEpoch,
      this.muted,
      this.localReady,
      this.peerAccepted,
      this.callRunning,
      this.cleanupOnly,
      this.selection);
  static NikoVoiceStatus? parse(String json) {
    if (json.length > 8192 || utf8.encode(json).length > 8192) return null;
    try {
      final raw = jsonDecode(json);
      if (raw is! Map ||
          !_fields(raw, {
            'identity',
            'kind',
            'revision',
            'resource_epoch',
            'phase',
            'reason',
            'microphone_permission',
            'muted',
            'local_ready',
            'peer_accepted',
            'call_running',
            'wire',
            'selection',
            'cleanup_only'
          }) ||
          raw['kind'] != 'voice' ||
          !raw.containsKey('selection')) return null;
      final identity = NikoCapabilityIdentity.parse(raw['identity']);
      final wire = raw['wire'];
      final selection = raw['selection'] == null
          ? null
          : NikoVoiceSelection.parse(raw['selection']);
      if (identity == null ||
          identity.connectionId > 2147483647 ||
          !_decimal(raw['revision']) ||
          !_decimal(raw['resource_epoch']) ||
          !{
            'Pending',
            'Starting',
            'Running',
            'Revoking',
            'RecoveryRequired',
            'Stopped'
          }.contains(raw['phase']) ||
          !_reason(raw['reason']) ||
          !_permissions.contains(raw['microphone_permission']) ||
          raw['muted'] is! bool ||
          raw['local_ready'] is! bool ||
          raw['peer_accepted'] is! bool ||
          raw['call_running'] is! bool ||
          raw['cleanup_only'] is! bool ||
          wire is! Map ||
          !_fields(wire, {'call_nonce', 'call_epoch'}) ||
          wire['call_nonce'] is! String ||
          !NikoCapabilityIdentity.validNonce(wire['call_nonce']) ||
          !_decimal(wire['call_epoch']) ||
          (raw['selection'] != null && selection == null) ||
          (raw['phase'] == 'Running' &&
              (selection == null || raw['local_ready'] != true)) ||
          raw['call_running'] !=
              (raw['phase'] == 'Running' &&
                  raw['local_ready'] == true &&
                  raw['peer_accepted'] == true) ||
          (raw['phase'] == 'Stopped' && raw['local_ready'] == true)) {
        return null;
      }
      return NikoVoiceStatus._(
          identity,
          raw['revision'],
          raw['resource_epoch'],
          raw['phase'],
          raw['reason'],
          raw['microphone_permission'],
          wire['call_nonce'],
          wire['call_epoch'],
          raw['muted'],
          raw['local_ready'],
          raw['peer_accepted'],
          raw['call_running'],
          raw['cleanup_only'] ?? false,
          selection);
    } catch (_) {
      return null;
    }
  }

  bool sameCall(NikoVoiceStatus other) =>
      identity.sameRequest(other.identity) &&
      callNonce == other.callNonce &&
      callEpoch == other.callEpoch;
  bool sameSnapshot(NikoVoiceStatus other) =>
      sameCall(other) &&
      revision == other.revision &&
      resourceEpoch == other.resourceEpoch &&
      phase == other.phase &&
      reason == other.reason &&
      microphonePermission == other.microphonePermission &&
      muted == other.muted &&
      localReady == other.localReady &&
      peerAccepted == other.peerAccepted &&
      callRunning == other.callRunning &&
      cleanupOnly == other.cleanupOnly &&
      (selection == null
          ? other.selection == null
          : selection!.same(other.selection));
}

class NikoVoiceCatalog {
  final NikoCapabilityIdentity identity;
  final String revision, rosterRevision, microphonePermission, reason;
  final List<NikoVoiceDevice> devices;
  bool get androidClientFormat =>
      devices.any((d) => d.formats.isNotEmpty) &&
      devices.every((d) => d.formats
          .every((f) => f.schema == 'android_client_pcm_f32_48k_mono_v1'));
  const NikoVoiceCatalog._(this.identity, this.revision, this.rosterRevision,
      this.microphonePermission, this.reason, this.devices);
  static NikoVoiceCatalog? parse(String json) {
    if (json.length > 1048576 || utf8.encode(json).length > 1048576) {
      return null;
    }
    try {
      final raw = jsonDecode(json);
      if (raw is! Map ||
          !_fields(raw, {
            'identity',
            'revision',
            'roster_revision',
            'microphone_permission',
            'reason',
            'devices'
          })) return null;
      final identity = NikoCapabilityIdentity.parse(raw['identity']);
      if (identity == null ||
          identity.connectionId > 2147483647 ||
          !_decimal(raw['revision']) ||
          !_decimal(raw['roster_revision']) ||
          !_permissions.contains(raw['microphone_permission']) ||
          !_reason(raw['reason']) ||
          raw['devices'] is! List ||
          raw['devices'].length > 256) return null;
      final devices = <NikoVoiceDevice>[];
      final tokens = <String>{};
      for (final value in raw['devices']) {
        final device = NikoVoiceDevice.parse(value);
        if (device == null ||
            !tokens.add(device.token) ||
            device.formats.any((f) => !tokens.add(f.token)) ||
            devices.any((d) =>
                d.token == device.token ||
                (d.uid == device.uid && d.direction == device.direction))) {
          return null;
        }
        devices.add(device);
      }
      return NikoVoiceCatalog._(
          identity,
          raw['revision'],
          raw['roster_revision'],
          raw['microphone_permission'],
          raw['reason'],
          List.unmodifiable(devices));
    } catch (_) {
      return null;
    }
  }

  NikoVoiceDevice? device(String? token, String direction) {
    for (final device in devices) {
      if (device.token == token && device.direction == direction) return device;
    }
    return null;
  }

  NikoVoiceSelection? select(String? capture, String? captureFormat,
      String? playback, String? playbackFormat) {
    final input = device(capture, 'capture');
    final output = device(playback, 'playback');
    if (input == null ||
        output == null ||
        !input.formats.any((f) => f.token == captureFormat) ||
        !output.formats.any((f) => f.token == playbackFormat)) return null;
    return NikoVoiceSelection._(rosterRevision, input.token, captureFormat!,
        output.token, playbackFormat!);
  }

  bool containsSelection(NikoVoiceSelection selection) =>
      selection.rosterRevision == rosterRevision &&
      select(selection.captureToken, selection.captureFormatToken,
              selection.playbackToken, selection.playbackFormatToken) !=
          null;
}

class NikoVoiceCommand {
  final NikoVoiceStatus captured;
  final String op;
  final NikoVoiceSelection? selection;
  final bool? allowBackground;
  const NikoVoiceCommand._(
      this.captured, this.op, this.selection, this.allowBackground);
  String toJson() => jsonEncode({
        'identity': captured.identity.toJson(),
        'revision': captured.revision,
        'op': op,
        if (selection != null) ...selection!.toJson(),
        if (allowBackground != null) 'allow_background': allowBackground,
      });
}

class NikoVoiceReply {
  final bool queued;
  final String reason;
  const NikoVoiceReply._(this.queued, this.reason);
  static NikoVoiceReply? parse(String json, NikoVoiceCommand command) {
    if (json.length > 8192 || utf8.encode(json).length > 8192) return null;
    try {
      final raw = jsonDecode(json);
      if (raw is! Map ||
          !_fields(raw, {'ok', 'status', 'identity', 'revision', 'reason'})) {
        return null;
      }
      final identity = NikoCapabilityIdentity.parse(raw['identity']);
      if (identity == null ||
          identity.connectionId > 2147483647 ||
          !identity.sameRequest(command.captured.identity) ||
          raw['revision'] != command.captured.revision ||
          (raw.containsKey('reason') && !_reason(raw['reason']))) return null;
      if (raw['ok'] == true && raw['status'] == 'queued') {
        return const NikoVoiceReply._(true, '');
      }
      if (raw['ok'] == false &&
          raw['status'] == 'error' &&
          _reason(raw['reason']) &&
          raw['reason'].isNotEmpty) {
        return NikoVoiceReply._(false, raw['reason']);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// The integration supplies verified platform/policy facts. Presence of an FFI
/// symbol, a device list or a permission result cannot enable the capability.
enum NikoVoiceAvailability {
  enabled,
  policyDisabled,
  peerPolicyDisabled,
  backendUnsupported,
  protocolUnsupported,
  contextUnsupported,
  permissionUnsupported,
  unknown
}

typedef NikoVoiceTransport = Future<String> Function(NikoVoiceCommand command);

enum NikoVoicePrepareResult { queued, unconfirmed, unsupported, policyRejected }

/// The integration closes over a real SessionID. Preparation never creates a
/// Dart identity; a verified native status must anchor a separate session model.
class NikoVoicePreparation extends ChangeNotifier {
  final String contextKey;
  final Future<NikoVoicePrepareResult> Function()? prepare;
  final Duration timeout;
  final NikoVoiceAvailability availability;
  String _phase = 'idle';
  bool _disposed = false;
  NikoVoicePreparation(
      {required this.contextKey,
      required this.availability,
      this.prepare,
      this.timeout = const Duration(seconds: 5)});
  String get phase => _phase;
  bool get mayPrepare =>
      !_disposed &&
      prepare != null &&
      availability == NikoVoiceAvailability.enabled &&
      _phase == 'idle';
  Future<void> start() async {
    if (!mayPrepare) return;
    _phase = 'preparing';
    notifyListeners();
    try {
      final result = await prepare!().timeout(timeout);
      if (_disposed) return;
      _phase = switch (result) {
        NikoVoicePrepareResult.queued => 'pending',
        NikoVoicePrepareResult.unconfirmed => 'unconfirmed',
        NikoVoicePrepareResult.unsupported => 'unsupported',
        NikoVoicePrepareResult.policyRejected => 'policy_rejected'
      };
    } catch (_) {
      if (_disposed) return;
      _phase = 'unconfirmed';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Construct only from this connection's verified local snapshot. Event updates
/// cannot replace the anchor or turn a live row into a retired cleanup row.
class NikoVoiceSessionModel extends ChangeNotifier {
  NikoVoiceStatus _status;
  NikoVoiceCatalog? _catalog;
  NikoVoiceSelection? _frozenSelection;
  final NikoVoiceTransport _transport;
  final Duration commandTimeout;
  final bool cleanupOnly;
  final bool androidController;
  NikoVoiceAvailability _availability;
  bool _disposed = false, _busy = false;
  bool _cleanupUnconfirmed = false, _approvalUnconfirmed = false;
  int _serial = 0;
  String? _operationMessage;

  NikoVoiceSessionModel(
      {required NikoVoiceStatus anchor,
      required NikoVoiceTransport transport,
      NikoVoiceAvailability availability = NikoVoiceAvailability.unknown,
      this.cleanupOnly = false,
      this.androidController = false,
      this.commandTimeout = const Duration(seconds: 5)})
      : _status = anchor,
        _frozenSelection = anchor.selection,
        _transport = transport,
        _availability = availability;
  NikoVoiceStatus get status => _status;
  NikoVoiceCatalog? get catalog => _catalog;
  NikoVoiceAvailability get availability => _availability;
  bool get busy => _busy;
  bool get cleanupUnconfirmed => _cleanupUnconfirmed;
  bool get approvalUnconfirmed => _approvalUnconfirmed;
  String? get operationMessage => _operationMessage;
  bool get mayPrepare =>
      !_disposed &&
      !cleanupOnly &&
      _availability == NikoVoiceAvailability.enabled &&
      _status.phase == 'Pending' &&
      !_cleanupUnconfirmed &&
      !_approvalUnconfirmed;
  bool get mayRequestPermission =>
      mayPrepare && _status.microphonePermission == 'NotDetermined';
  bool mayApprove(NikoVoiceSelection? selection) =>
      mayPrepare &&
      _status.microphonePermission == 'Authorized' &&
      _catalog?.microphonePermission == 'Authorized' &&
      selection != null &&
      _catalog!.containsSelection(selection);
  bool isCurrent(NikoVoiceStatus captured) =>
      !_disposed && _status.sameSnapshot(captured);

  void setAvailability(NikoVoiceAvailability value) {
    if (_disposed || value == _availability) return;
    _availability = value;
    ++_serial;
    _busy = false;
    _operationMessage = null;
    notifyListeners();
  }

  bool applyStatus(NikoVoiceStatus value) {
    if (_disposed ||
        !_status.sameCall(value) ||
        BigInt.parse(value.revision) < BigInt.parse(_status.revision) ||
        BigInt.parse(value.resourceEpoch) <
            BigInt.parse(_status.resourceEpoch) ||
        (value.revision == _status.revision && !_status.sameSnapshot(value)) ||
        (value.cleanupOnly && !cleanupOnly) ||
        (cleanupOnly &&
            {'Pending', 'Starting', 'Running'}.contains(value.phase)) ||
        (!_mayTransition(_status.phase, value.phase)) ||
        (value.selection != null &&
            _frozenSelection != null &&
            !_frozenSelection!.same(value.selection))) return false;
    if (_status.sameSnapshot(value)) return true;
    _status = value;
    if (value.phase == 'Pending') {
      _frozenSelection = null;
    } else if (value.selection != null) {
      _frozenSelection ??= value.selection;
    }
    ++_serial;
    _busy = false;
    _approvalUnconfirmed = false;
    _operationMessage = null;
    if (value.phase == 'Stopped') _cleanupUnconfirmed = false;
    if (_catalog?.revision != value.revision) _catalog = null;
    notifyListeners();
    return true;
  }

  bool _mayTransition(String before, String after) => switch (before) {
        'Pending' => true,
        'Starting' => after != 'Pending',
        'Running' => !{'Pending', 'Starting'}.contains(after),
        'Revoking' ||
        'RecoveryRequired' =>
          {'Revoking', 'RecoveryRequired', 'Stopped'}.contains(after),
        'Stopped' => after == 'Stopped',
        _ => false,
      };

  bool applyCatalog(NikoVoiceCatalog value) {
    if (_disposed ||
        !mayPrepare ||
        !_status.identity.sameRequest(value.identity) ||
        value.revision != _status.revision ||
        value.microphonePermission != _status.microphonePermission ||
        (_catalog != null &&
            BigInt.parse(value.rosterRevision) <
                BigInt.parse(_catalog!.rosterRevision))) return false;
    // Reusing a revision with a changed roster is not a new discovery snapshot.
    if (_catalog?.rosterRevision == value.rosterRevision) return false;
    _catalog = value;
    notifyListeners();
    return true;
  }

  bool _allowed(String op, NikoVoiceSelection? selection) {
    if (_disposed || _busy) return false;
    if (op == 'query') return true;
    if (cleanupOnly) {
      return op == 'retry_cleanup' &&
          (_status.phase != 'Stopped' || _cleanupUnconfirmed);
    }
    return switch (op) {
      'enumerate' => mayPrepare,
      'request_permission' => mayRequestPermission,
      'approve' => mayApprove(selection),
      'deny' => _status.phase == 'Pending',
      'revoke' => {'Starting', 'Running', 'Revoking'}.contains(_status.phase),
      'retry_cleanup' => _cleanupUnconfirmed ||
          {'Revoking', 'RecoveryRequired'}.contains(_status.phase),
      'mute' =>
        !_cleanupUnconfirmed && _status.phase == 'Running' && !_status.muted,
      'unmute' => !_cleanupUnconfirmed &&
          _availability == NikoVoiceAvailability.enabled &&
          _status.phase == 'Running' &&
          _status.muted,
      _ => false,
    };
  }

  Future<bool> send(String op,
      {NikoVoiceSelection? selection,
      NikoVoiceStatus? captured,
      bool? allowBackground}) async {
    if ((captured != null && !isCurrent(captured)) ||
        (allowBackground != null &&
            (op != 'approve' ||
                !androidController ||
                _catalog?.androidClientFormat != true)) ||
        !_allowed(op, selection)) {
      return false;
    }
    final before = _status;
    final command = NikoVoiceCommand._(
        before, op, op == 'approve' ? selection : null, allowBackground);
    final serial = ++_serial;
    _busy = true;
    _operationMessage = null;
    if (op == 'approve') {
      _approvalUnconfirmed = true;
      _frozenSelection = selection;
    }
    if ({'deny', 'revoke', 'retry_cleanup'}.contains(op)) {
      _cleanupUnconfirmed = true;
    }
    notifyListeners();
    try {
      final raw = await _transport(command).timeout(commandTimeout);
      if (_disposed || serial != _serial || !isCurrent(before)) return false;
      final reply = NikoVoiceReply.parse(raw, command);
      _operationMessage = reply == null
          ? 'operation_unconfirmed'
          : reply.queued
              ? 'queued'
              : reply.reason;
      return reply?.queued == true;
    } on TimeoutException {
      if (!_disposed && serial == _serial && isCurrent(before)) {
        _operationMessage = 'operation_unconfirmed';
      }
      return false;
    } catch (_) {
      if (!_disposed && serial == _serial && isCurrent(before)) {
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
