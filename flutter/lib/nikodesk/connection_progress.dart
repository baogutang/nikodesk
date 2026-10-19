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

/// How long each connection step took, on a monotonic clock started by
/// [NikoConnectionProgress.begin]. Time spent waiting for the user (a password,
/// or approval on the controlled side) is reported as [userWait] and is not
/// part of [authentication]. Null means the step was not observed.
class NikoConnectionTimings {
  final Duration? transport, authentication, userWait, firstFrame;
  const NikoConnectionTimings(
      {this.transport, this.authentication, this.userWait, this.firstFrame});
}

/// Presentation of observed session events; never authorizes a connection.
class NikoConnectionProgress extends ValueNotifier<NikoConnectionState> {
  bool _authenticated = false;
  final Duration Function() _clock;
  Duration? _began, _transportAt, _authAt, _frameAt, _waitFrom;
  Duration _userWait = Duration.zero;
  static final _watch = Stopwatch()..start();

  NikoConnectionProgress({@visibleForTesting Duration Function()? clock})
      : _clock = clock ?? (() => _watch.elapsed),
        super(const NikoConnectionState(NikoConnectionPhase.preparing));

  NikoConnectionTimings get timings {
    final began = _began, transport = _transportAt, auth = _authAt;
    if (began == null) return const NikoConnectionTimings();
    Duration? span(Duration? from, Duration? to) =>
        from == null || to == null || to < from ? null : to - from;
    final authSpan = span(transport, auth);
    return NikoConnectionTimings(
        transport: span(began, transport),
        authentication: authSpan == null
            ? null
            : (authSpan - _userWait < Duration.zero
                ? Duration.zero
                : authSpan - _userWait),
        userWait: auth == null ? null : _userWait,
        firstFrame: span(auth, _frameAt));
  }

  void _endWait() {
    final from = _waitFrom;
    if (from == null) return;
    _userWait += _clock() - from;
    _waitFrom = null;
  }

  bool get _active => value.phase != NikoConnectionPhase.failed &&
      value.phase != NikoConnectionPhase.closed;

  void begin({bool reconnecting = false}) {
    _authenticated = false;
    _began = _clock();
    _transportAt = _authAt = _frameAt = _waitFrom = null;
    _userWait = Duration.zero;
    value = NikoConnectionState(reconnecting
        ? NikoConnectionPhase.reconnecting
        : NikoConnectionPhase.connecting);
  }

  void transportReady() {
    if (_active && !_authenticated) _transportAt ??= _clock();
    if (!_active || _authenticated ||
        value.phase == NikoConnectionPhase.waitingForCredentials ||
        value.phase == NikoConnectionPhase.waitingForApproval) return;
    value = const NikoConnectionState(NikoConnectionPhase.authenticating);
  }

  void authenticated({required bool expectsFrame, bool fromCache = false}) {
    if (!_active || fromCache || _authenticated) return;
    _authenticated = true;
    _endWait();
    _authAt = _clock();
    value = NikoConnectionState(expectsFrame
        ? NikoConnectionPhase.waitingForFrame
        : NikoConnectionPhase.authenticated);
  }

  void frameReceived() {
    if (!_active || !_authenticated ||
        value.phase != NikoConnectionPhase.waitingForFrame) return;
    _frameAt = _clock();
    value = const NikoConnectionState(NikoConnectionPhase.connected);
  }

  void credentialsSubmitted() {
    if (!_active || _authenticated) return;
    _endWait();
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
        _waitFrom ??= _clock();
        value = const NikoConnectionState(NikoConnectionPhase.waitingForApproval);
      } else if (type == 'input-password' || type == 're-input-password' ||
          type == 'input-2fa') {
        _waitFrom ??= _clock();
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
