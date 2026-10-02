import 'package:flutter/foundation.dart';

enum NikoConnectionPhase {
  preparing,
  connecting,
  authenticating,
  waitingForCredentials,
  waitingForApproval,
  waitingForFrame,
  authenticated,
  connected,
  reconnecting,
  failed,
  closed,
}

class NikoConnectionState {
  final NikoConnectionPhase phase;
  final NikoConnectionPhase? failedAt;
  const NikoConnectionState(this.phase, {this.failedAt});

  bool get pending => switch (phase) {
        NikoConnectionPhase.connecting ||
        NikoConnectionPhase.authenticating ||
        NikoConnectionPhase.waitingForApproval ||
        NikoConnectionPhase.waitingForFrame ||
        NikoConnectionPhase.reconnecting => true,
        _ => false,
      };
}

/// Presentation of observed session events; never authorizes a connection.
class NikoConnectionProgress extends ValueNotifier<NikoConnectionState> {
  bool _authenticated = false;

  NikoConnectionProgress()
      : super(const NikoConnectionState(NikoConnectionPhase.preparing));

  bool get _active => value.phase != NikoConnectionPhase.failed &&
      value.phase != NikoConnectionPhase.closed;

  void begin({bool reconnecting = false}) {
    _authenticated = false;
    value = NikoConnectionState(reconnecting
        ? NikoConnectionPhase.reconnecting
        : NikoConnectionPhase.connecting);
  }

  void transportReady() {
    if (!_active || _authenticated ||
        value.phase == NikoConnectionPhase.waitingForCredentials ||
        value.phase == NikoConnectionPhase.waitingForApproval) return;
    value = const NikoConnectionState(NikoConnectionPhase.authenticating);
  }

  void authenticated({required bool expectsFrame, bool fromCache = false}) {
    if (!_active || fromCache || _authenticated) return;
    _authenticated = true;
    value = NikoConnectionState(expectsFrame
        ? NikoConnectionPhase.waitingForFrame
        : NikoConnectionPhase.authenticated);
  }

  void frameReceived() {
    if (!_active || !_authenticated ||
        value.phase != NikoConnectionPhase.waitingForFrame) return;
    value = const NikoConnectionState(NikoConnectionPhase.connected);
  }

  void credentialsSubmitted() {
    if (!_active || _authenticated) return;
    value = const NikoConnectionState(NikoConnectionPhase.authenticating);
  }

  void message(Object? type, Object? title) {
    if (!_active) return;
    if (title == 'Connection Error' || title == 'Connection Failed' ||
        title == 'Disconnected') {
      fail();
    } else if (type == 'restarting' || type == 'restarting-show') {
      begin(reconnecting: true);
    } else if (!_authenticated) {
      if (type == 'wait-remote-accept-nook') {
        value = const NikoConnectionState(NikoConnectionPhase.waitingForApproval);
      } else if (type == 'input-password' || type == 're-input-password' ||
          type == 'input-2fa') {
        value = const NikoConnectionState(NikoConnectionPhase.waitingForCredentials);
      }
    }
  }

  void fail() {
    if (!_active) return;
    value = NikoConnectionState(NikoConnectionPhase.failed, failedAt: value.phase);
    _authenticated = false;
  }

  void close() {
    _authenticated = false;
    value = const NikoConnectionState(NikoConnectionPhase.closed);
  }
}
