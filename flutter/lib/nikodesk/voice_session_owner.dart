import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'voice_session_model.dart';

class NikoVoiceAvailabilitySnapshot {
  final bool supported, requestsAllowed, peerSupported, peerRequestsAllowed;
  final String reason;
  const NikoVoiceAvailabilitySnapshot._(this.supported, this.requestsAllowed,
      this.peerSupported, this.peerRequestsAllowed, this.reason);
  static NikoVoiceAvailabilitySnapshot? parse(String json) {
    if (json.length > 4096 || utf8.encode(json).length > 4096) return null;
    try {
      final raw = jsonDecode(json);
      if (raw is! Map ||
          raw.keys.toSet().difference({
            'supported',
            'requests_allowed',
            'peer_supported',
            'peer_requests_allowed',
            'reason'
          }).isNotEmpty ||
          raw['supported'] is! bool ||
          raw['requests_allowed'] is! bool ||
          raw['peer_supported'] is! bool ||
          raw['peer_requests_allowed'] is! bool ||
          raw['reason'] is! String ||
          !RegExp(r'^[a-z0-9_]{0,96}$').hasMatch(raw['reason'])) return null;
      return NikoVoiceAvailabilitySnapshot._(
          raw['supported'],
          raw['requests_allowed'],
          raw['peer_supported'],
          raw['peer_requests_allowed'],
          raw['reason']);
    } catch (_) {
      return null;
    }
  }

  NikoVoiceAvailability get availability {
    if (!supported) {
      return {'unsupported', 'backend_unsupported', 'voice_unsupported'}
              .contains(reason)
          ? NikoVoiceAvailability.backendUnsupported
          : NikoVoiceAvailability.unknown;
    }
    if (!requestsAllowed) return NikoVoiceAvailability.policyDisabled;
    if (!peerSupported) return NikoVoiceAvailability.protocolUnsupported;
    if (!peerRequestsAllowed) return NikoVoiceAvailability.peerPolicyDisabled;
    return NikoVoiceAvailability.enabled;
  }

  // The peer's incoming-call policy does not deny a call it already initiated.
  // Keep that fact intact; only this incoming CM decision uses three facts.
  NikoVoiceAvailability get receiverAvailability {
    if (!supported || !requestsAllowed || !peerSupported) return availability;
    return NikoVoiceAvailability.enabled;
  }
}

NikoVoicePrepareResult nikoVoicePrepareReply(String json) {
  if (json.length > 4096 || utf8.encode(json).length > 4096) {
    return NikoVoicePrepareResult.unconfirmed;
  }
  try {
    final raw = jsonDecode(json);
    if (raw is! Map ||
        raw.keys.toSet().difference({'ok', 'status', 'reason'}).isNotEmpty ||
        (raw.containsKey('reason') &&
            (raw['reason'] is! String ||
                !RegExp(r'^[a-z0-9_]{0,96}$').hasMatch(raw['reason'])))) {
      return NikoVoicePrepareResult.unconfirmed;
    }
    if (raw['ok'] == true && raw['status'] == 'queued') {
      return NikoVoicePrepareResult.queued;
    }
    // These two explicit native Prepare failures precede Call construction.
    // A timeout, missing reply or any other error cannot establish that fact.
    if (raw['ok'] == false &&
        raw['status'] == 'error' &&
        {'policy_disabled', 'peer_policy_disabled'}.contains(raw['reason'])) {
      return NikoVoicePrepareResult.policyRejected;
    }
    if (raw['ok'] == false &&
        raw['status'] == 'error' &&
        {'unsupported', 'backend_unsupported', 'voice_unsupported'}
            .contains(raw['reason'])) {
      return NikoVoicePrepareResult.unsupported;
    }
  } catch (_) {}
  return NikoVoicePrepareResult.unconfirmed;
}

/// The FFI owns this cache, not an open dialog. It closes over one immutable
/// SessionID/scope/peer and receives only that session's native event sink.
class NikoVoiceSessionOwner extends ChangeNotifier {
  final String contextKey, namespace, peerId;
  final bool Function() isCurrent;
  final Future<String> Function() readAvailability, prepareNative;
  final NikoVoiceTransport commandNative;
  final Duration timeout;
  final bool androidController;
  NikoVoiceSessionModel? _model;
  late NikoVoicePreparation _preparation;
  NikoVoiceAvailability _availability = NikoVoiceAvailability.unknown;
  String? _reason;
  bool _disposed = false, _reading = false, _awaitingFresh = false;
  int _availabilitySerial = 0;
  int _prepareSerial = 0;
  bool _policyRejected = false;
  BigInt? _highestEpoch;
  NikoVoiceCatalog? _pendingCatalog;
  bool _incoming = false;
  String? _announcedIncoming;

  NikoVoiceSessionOwner(
      {required this.contextKey,
      required this.namespace,
      required this.peerId,
      required this.isCurrent,
      required this.readAvailability,
      required this.prepareNative,
      required this.commandNative,
      this.androidController = false,
      this.timeout = const Duration(seconds: 5)}) {
    _preparation = _newPreparation();
    _preparation.addListener(_changed);
  }
  NikoVoiceSessionModel? get model => _model;
  NikoVoicePreparation get preparation => _preparation;
  NikoVoiceAvailability get availability => _availability;
  String? get reason => _reason;
  bool get reading => _reading;
  bool get active => !_disposed && isCurrent();
  bool get incomingCall => _incoming && _model?.status.phase == 'Pending';
  bool takeIncomingNotice() {
    final status = _model?.status;
    if (!active || !incomingCall || status == null ||
        _announcedIncoming == status.identity.requestNonce) return false;
    _announcedIncoming = status.identity.requestNonce;
    return true;
  }
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  NikoVoicePreparation _newPreparation() => NikoVoicePreparation(
      contextKey: contextKey,
      availability: _availability,
      timeout: timeout,
      prepare: () async {
        if (!active ||
            (_model != null &&
                (_model!.status.phase != 'Stopped' ||
                    _model!.cleanupUnconfirmed))) {
          return NikoVoicePrepareResult.unconfirmed;
        }
        final attempt = ++_prepareSerial;
        final capturedModel = _model;
        _policyRejected = false;
        _awaitingFresh = true;
        final reply = await prepareNative().timeout(timeout);
        if (!active || attempt != _prepareSerial ||
            !identical(_model, capturedModel)) {
          return NikoVoicePrepareResult.unconfirmed;
        }
        final result = nikoVoicePrepareReply(reply);
        if (result == NikoVoicePrepareResult.policyRejected && _model == null) {
          _awaitingFresh = false;
          _policyRejected = true;
          _reason = jsonDecode(reply)['reason'];
        }
        return result;
      });
  void _resetPreparation() {
    ++_prepareSerial;
    _preparation.removeListener(_changed);
    _preparation.dispose();
    _preparation = _newPreparation();
    _preparation.addListener(_changed);
  }

  Future<void> refreshAvailability() async {
    if (!active || _reading) return;
    final serial = ++_availabilitySerial;
    final capturedModel = _model;
    final rejectedPreparation = _policyRejected && _model == null &&
            _preparation.phase == 'policy_rejected'
        ? _preparation : null;
    final capturedAttempt = _prepareSerial;
    var freshMetadata = false;
    _reading = true;
    notifyListeners();
    try {
      final raw = await readAvailability().timeout(timeout);
      if (!active ||
          serial != _availabilitySerial ||
          (capturedModel != null && !identical(_model, capturedModel))) return;
      final snapshot = NikoVoiceAvailabilitySnapshot.parse(raw);
      freshMetadata = snapshot != null;
      _availability = (_incoming ? snapshot?.receiverAvailability : snapshot?.availability) ?? NikoVoiceAvailability.unknown;
      _reason = snapshot?.reason ?? 'operation_unconfirmed';
    } catch (_) {
      if (!active ||
          serial != _availabilitySerial ||
          (capturedModel != null && !identical(_model, capturedModel))) return;
      _availability = NikoVoiceAvailability.unknown;
      _reason = 'operation_unconfirmed';
    } finally {
      if (!_disposed && serial == _availabilitySerial) {
        _reading = false;
        if (capturedModel == null || identical(_model, capturedModel)) {
          _model?.setAvailability(_availability);
        }
        final catalog = _pendingCatalog;
        if (catalog != null && _model?.applyCatalog(catalog) == true) {
          _pendingCatalog = null;
        }
        if (active && _preparation.phase == 'idle') {
          _resetPreparation();
        } else if (active && freshMetadata && rejectedPreparation != null &&
            identical(_preparation, rejectedPreparation) &&
            capturedAttempt == _prepareSerial &&
            _policyRejected && _model == null &&
            _availability == NikoVoiceAvailability.enabled) {
          _policyRejected = false;
          _resetPreparation();
        }
        notifyListeners();
      }
    }
  }

  bool handleEvent(Map<String, dynamic> event) {
    if (!active ||
        event['namespace'] != namespace ||
        event['peer_id'] != peerId ||
        event['payload'] is! String) return false;
    final payload = event['payload'] as String;
    if (event['name'] == 'nikodesk_voice_status') {
      final status = NikoVoiceStatus.parse(payload);
      if (status == null ||
          status.cleanupOnly ||
          status.identity.namespace != namespace ||
          status.identity.peerId != peerId ||
          event['connection_nonce'] != status.identity.connectionNonce) {
        return false;
      }
      final current = _model;
      if (current != null && current.status.sameCall(status)) {
        if (!current.applyStatus(status)) return false;
        if (_incoming && status.phase == 'Stopped') {
          _incoming = false;
          _availability = NikoVoiceAvailability.unknown;
          _resetPreparation();
          refreshAvailability();
        }
        if (_pendingCatalog?.revision != status.revision) {
          _pendingCatalog = null;
        }
        if (status.phase == 'Stopped' &&
            !_awaitingFresh &&
            _preparation.phase != 'idle') {
          _resetPreparation();
        }
        notifyListeners();
        return true;
      }
      final epoch = BigInt.parse(status.callEpoch);
      final incoming = event['initiator'] == 'peer' && status.phase == 'Pending';
      if (_highestEpoch != null &&
          (epoch <= _highestEpoch! ||
              (!_awaitingFresh && !incoming) ||
              current?.status.phase != 'Stopped' ||
              current!.cleanupUnconfirmed)) return false;
      current?.removeListener(_changed);
      current?.dispose();
      if (current != null) {
        ++_availabilitySerial;
        _reading = false;
        _availability = NikoVoiceAvailability.unknown;
        _reason = null;
      }
      _pendingCatalog = null;
      _incoming = incoming;
      late final NikoVoiceSessionModel created;
      created = NikoVoiceSessionModel(
          anchor: status,
          availability: _availability,
          androidController: androidController,
          transport: (command) async {
            if (!active ||
                !identical(_model, created) ||
                !created.isCurrent(command.captured)) {
              return '{}';
            }
            return commandNative(command);
          },
          commandTimeout: timeout);
      _model = created;
      ++_prepareSerial;
      _policyRejected = false;
      _model!.addListener(_changed);
      _highestEpoch = epoch;
      _awaitingFresh = false;
      _preparation.removeListener(_changed);
      _preparation.dispose();
      _preparation = _newPreparation();
      _preparation.addListener(_changed);
      notifyListeners();
      if (current != null || incoming) refreshAvailability();
      return true;
    }
    if (event['name'] == 'nikodesk_voice_catalog') {
      final catalog = NikoVoiceCatalog.parse(payload);
      if (catalog == null ||
          catalog.identity.namespace != namespace ||
          catalog.identity.peerId != peerId ||
          event['connection_nonce'] != catalog.identity.connectionNonce) {
        return false;
      }
      final current = _model;
      if (current == null ||
          current.status.phase != 'Pending' ||
          !current.status.identity.sameRequest(catalog.identity) ||
          current.status.revision != catalog.revision ||
          current.status.microphonePermission != catalog.microphonePermission ||
          (_pendingCatalog != null &&
              BigInt.parse(catalog.rosterRevision) <=
                  BigInt.parse(_pendingCatalog!.rosterRevision))) return false;
      if (current.applyCatalog(catalog)) {
        _pendingCatalog = null;
        return true;
      }
      if (current.availability == NikoVoiceAvailability.unknown) {
        _pendingCatalog = catalog;
        return true;
      }
      return false;
    }
    return false;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_availabilitySerial;
    notifyListeners();
    _preparation.removeListener(_changed);
    _preparation.dispose();
    _model?.removeListener(_changed);
    _model?.dispose();
    super.dispose();
  }
}
