import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'cm_voice_panel.dart';
import 'ui.dart';
import 'voice_call_panel.dart';
import 'voice_session_model.dart';
import 'voice_session_owner.dart';

class NikoCmVoiceStartContext {
  final int connectionId;
  final String namespace, peerId, connectionNonce;
  const NikoCmVoiceStartContext._(
      this.connectionId, this.namespace, this.peerId, this.connectionNonce);

  static NikoCmVoiceStartContext? parse(dynamic raw) {
    if (raw is! Map ||
        raw.length != 5 ||
        raw['schema'] != 1 ||
        raw['connection_id'] is! int ||
        raw['connection_id'] <= 0 ||
        raw['namespace'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['namespace']) ||
        raw['namespace'] == '0' * 64 ||
        raw['peer_id'] is! String ||
        !RegExp(r'^[0-9]{6,16}$').hasMatch(raw['peer_id']) ||
        raw['connection_nonce'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(raw['connection_nonce']) ||
        raw['connection_nonce'] == '0' * 32) return null;
    return NikoCmVoiceStartContext._(raw['connection_id'], raw['namespace'],
        raw['peer_id'], raw['connection_nonce']);
  }

  Map<String, dynamic> toJson() => {
        'schema': 1,
        'connection_id': connectionId,
        'namespace': namespace,
        'peer_id': peerId,
        'connection_nonce': connectionNonce
      };
  String prepareJson({int? deadline}) => jsonEncode({
        'op': 'prepare',
        'context': toJson(),
        'expires_at_ms':
            deadline ?? DateTime.now().millisecondsSinceEpoch + 4500
      });
}

/// Preparation is metadata only. The actual call panel subsequently requests
/// microphone access, lists real devices and asks for an explicit selection.
class NikoCmVoiceStart extends StatefulWidget {
  final NikoCmVoiceStartContext context;
  final Future<String> Function(String)? availability, prepare;
  final String? prepareError;
  final int? prepareDeadline;
  const NikoCmVoiceStart(
      {super.key,
      required this.context,
      this.availability,
      this.prepare,
      this.prepareError,
      this.prepareDeadline});
  @override
  State<NikoCmVoiceStart> createState() => _NikoCmVoiceStartState();
}

class _NikoCmVoiceStartState extends State<NikoCmVoiceStart> {
  NikoVoicePreparation? _preparation;
  bool _reading = false;
  String? _reason;
  int _serial = 0;
  int? _deadline;
  bool _failed = false;
  @override
  void didUpdateWidget(covariant NikoCmVoiceStart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_deadline != null &&
        widget.prepareDeadline == _deadline &&
        widget.prepareError != null &&
        RegExp(r'^[a-z0-9_]{1,96}$').hasMatch(widget.prepareError!)) {
      _failed = true;
      _reason = widget.prepareError;
    }
  }

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    if (_reading) return;
    final serial = ++_serial;
    setState(() => _reading = true);
    try {
      final json = jsonEncode(widget.context.toJson());
      final raw = await (widget.availability?.call(json) ??
              bind.cmVoiceAvailability(jsonIdentity: json))
          .timeout(const Duration(seconds: 5));
      if (!mounted || serial != _serial) return;
      final snapshot = NikoVoiceAvailabilitySnapshot.parse(raw);
      final allowed = snapshot?.availability ?? NikoVoiceAvailability.unknown;
      _reason = snapshot?.reason ?? 'operation_unconfirmed';
      if (_preparation == null ||
          _preparation!.phase == 'idle' ||
          _preparation!.phase == 'policy_rejected' ||
          _failed) {
        _preparation?.dispose();
        _deadline = null;
        _failed = false;
        _preparation = NikoVoicePreparation(
            contextKey:
                '${widget.context.connectionId}/${widget.context.connectionNonce}',
            availability: allowed,
            prepare: () async {
              _failed = false;
              final previous = _deadline ?? 0;
              final next = DateTime.now().millisecondsSinceEpoch + 4500;
              _deadline = next > previous ? next : previous + 1;
              final request = widget.context.prepareJson(deadline: _deadline);
              final reply = await (widget.prepare?.call(request) ??
                  Future<String>.sync(
                      () => bind.cmVoiceCommand(json: request)));
              return nikoVoicePrepareReply(reply);
            });
      }
    } catch (_) {
      if (mounted && serial == _serial) _reason = 'operation_unconfirmed';
    } finally {
      if (mounted && serial == _serial) setState(() => _reading = false);
    }
  }

  @override
  void dispose() {
    ++_serial;
    _preparation?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(nikoText('向主控端发起语音', 'Call the controller')),
        Text(nikoText('双方都需要开启语音请求，并明确选择本机设备、同意通话。',
            'Both sides must enable voice requests, select their local devices and approve the call.')),
        if (!_failed) NikoVoiceCallPanel(preparation: _preparation),
        if (_reason != null && _reason != 'available')
          Text(nikoVoiceReasonText(_reason!)),
        OutlinedButton(
            onPressed: _reading ? null : _read,
            child: Text(nikoText('检查语音可用性', 'Check voice availability'))),
        if (_reading) const LinearProgressIndicator(),
      ]);
}
