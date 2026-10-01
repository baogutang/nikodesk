import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/models/platform_model.dart';

import 'wake_proxy.dart';

class NikoWakeOnlineSnapshot {
  final String state;
  final BigInt observation;
  const NikoWakeOnlineSnapshot(this.state, this.observation);
  static NikoWakeOnlineSnapshot? parse(
      String raw, String namespace, String id) {
    if (raw.length > 1024) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 5 ||
          !value.keys.every({
            'schema',
            'namespace',
            'peer_id',
            'state',
            'observation'
          }.contains) ||
          value['schema'] != 1 ||
          value['namespace'] != namespace ||
          value['peer_id'] != id ||
          !{'online', 'offline', 'unknown'}.contains(value['state']) ||
          value['observation'] is! String ||
          !RegExp(r'^(0|[1-9][0-9]{0,19})$').hasMatch(value['observation'])) {
        return null;
      }
      final observation = BigInt.parse(value['observation']);
      if (observation > BigInt.parse('18446744073709551615') ||
          value['state'] != 'unknown' && observation == BigInt.zero) {
        return null;
      }
      return NikoWakeOnlineSnapshot(value['state'], observation);
    } catch (_) {
      return null;
    }
  }
}

/// Uses the real native query and observation cache, including from a tunnel
/// window. A cached reply from before this wake request cannot prove success.
class NikoWakeOnlineMonitor {
  final String namespace, peerId;
  final Future<String> Function()? readStatus, readNamespace;
  final Future<void> Function()? request;
  final Stopwatch _clock = Stopwatch()..start();
  BigInt? _baseline;
  Duration? _lastRequest;
  bool _closed = false, _polling = false;
  NikoWakeOnlineMonitor(this.namespace, this.peerId,
      {this.readStatus, this.readNamespace, this.request});

  Future<NikoWakeOnlineSnapshot> _read() async {
    if (_closed ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(namespace) ||
        namespace == '0' * 64 ||
        !RegExp(r'^[0-9]{6,16}$').hasMatch(peerId)) {
      throw StateError('Wake observation is closed or invalid');
    }
    final current = await (readNamespace?.call() ??
            NativeNikoWakeProxyGateway().namespace())
        .timeout(const Duration(seconds: 3));
    if (_closed || current != namespace) {
      throw StateError('Private server changed');
    }
    final raw = await (readStatus?.call() ??
            bind.mainGetPeerOption(
                id: jsonEncode({'namespace': namespace, 'peer_id': peerId}),
                key: 'nikodesk-peer-online-status'))
        .timeout(const Duration(seconds: 3));
    final snapshot = NikoWakeOnlineSnapshot.parse(raw, namespace, peerId);
    final after = await (readNamespace?.call() ??
            NativeNikoWakeProxyGateway().namespace())
        .timeout(const Duration(seconds: 3));
    if (_closed || snapshot == null || after != namespace) {
      throw StateError('Wake observation unconfirmed');
    }
    return snapshot;
  }

  Future<void> prepare() async {
    _baseline = (await _read()).observation;
    _lastRequest = null;
  }

  Future<void> prepareIfNeeded() async {
    if (_baseline == null && !_closed) await prepare();
  }

  Future<bool?> poll() async {
    if (_closed || _baseline == null || _polling) return null;
    _polling = true;
    try {
      final snapshot = await _read();
      if (_closed) return null;
      if (snapshot.observation > _baseline!) {
        if (snapshot.state == 'online') return true;
      }
      if (_lastRequest == null ||
          _clock.elapsed - _lastRequest! >= const Duration(seconds: 6)) {
        _lastRequest = _clock.elapsed;
        // Queue failure is not an offline acknowledgement. The next poll can
        // still consume a real reply from the existing device-list query.
        try {
          await (request?.call() ??
                  bind.queryOnlines(ids: ['nikodesk-scope:$namespace', peerId]))
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
      return snapshot.observation > _baseline! && snapshot.state == 'offline'
          ? false
          : null;
    } finally {
      _polling = false;
    }
  }

  void close() {
    _closed = true;
    _clock.stop();
  }
}
