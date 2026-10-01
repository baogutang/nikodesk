import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/tunnel_cleanup.dart';
import 'package:flutter_hbb/nikodesk/tunnel_cleanup_view.dart';
import 'package:flutter_hbb/nikodesk/tunnel_controller_view.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

/// A tunnel page never borrows the global remote/file session UUID.
class NikoMobileTunnelOwner {
  static NikoMobileTunnelOwner? _active;
  static bool get hasActiveSession => _active != null;
  final FFI ffi;
  final NikoTunnelOwnerIdentity identity;
  final Future<String> Function(NikoTunnelOwnerIdentity) _closeNative,
      _queryNative;
  final Future<void> Function(FFI) _closeDart;
  final Duration timeout;
  Future<bool>? _closing;
  Future<void>? _dartClosing;
  bool _released = false;
  NikoMobileTunnelOwner._(this.ffi, this.identity, this._closeNative,
      this._queryNative, this._closeDart, this.timeout);
  static NikoMobileTunnelOwner open(
      {required FFI globalOwner,
      required String namespace,
      required String peerId,
      FFI Function(FFI)? createFfi,
      Future<String> Function(NikoTunnelOwnerIdentity)? closeNative,
      Future<String> Function(NikoTunnelOwnerIdentity)? queryNative,
      Future<void> Function(FFI)? closeDart,
      Duration timeout = const Duration(seconds: 5)}) {
    if (_active != null) {
      throw StateError('Close the current mobile tunnel session first');
    }
    final ffi =
        (createFfi ?? (global) => FFI(null, globalOwner: global))(globalOwner);
    final identity =
        NikoTunnelOwnerIdentity(ffi.sessionId.toString(), namespace, peerId);
    const native = NativeNikoTunnelCleanupTransport();
    final owner = NikoMobileTunnelOwner._(
        ffi,
        identity,
        closeNative ?? native.close,
        queryNative ?? native.query,
        closeDart ?? _closeOwnedDart,
        timeout);
    _active = owner;
    NikoTunnelCleanupProofs.confirmed.addListener(owner._proofChanged);
    return owner;
  }

  static Future<void> _closeOwnedDart(FFI ffi) async {
    try {
      await ffi.close(closeSession: false);
    } finally {
      ffi.dialogManager.dismissAll();
    }
  }

  void _proofChanged() {
    final proof = NikoTunnelCleanupProofs.confirmed.value;
    if (proof != null && proof.confirmed && proof.owner.same(identity)) {
      _release();
    }
  }

  void _release() {
    if (_released) return;
    _released = true;
    NikoTunnelCleanupProofs.confirmed.removeListener(_proofChanged);
    if (identical(_active, this)) _active = null;
  }

  Future<bool> close({bool query = false}) {
    if (_released) return Future.value(true);
    return _closing ??= _closeOnce(query).whenComplete(() => _closing = null);
  }

  Future<bool> _closeOnce(bool query) async {
    ffi.nikoTunnelController?.invalidate();
    NikoTunnelCleanupReply? reply;
    try {
      reply = NikoTunnelCleanupReply.parse(
          await (query ? _queryNative : _closeNative)(identity)
              .timeout(timeout),
          identity);
    } catch (_) {/* The original owner remains occupied on unknown/timeout. */}
    if (reply?.confirmed == true) NikoTunnelCleanupProofs.record(reply!);
    if (reply?.confirmed == true ||
        reply?.reason == 'cleanup_pending' ||
        (reply?.ok == true && reply?.reason == 'ui_detached')) {
      try {
        await (_dartClosing ??= _closeDart(ffi)).timeout(timeout);
      } catch (_) {/* Native proof controls release, never Dart teardown. */}
    }
    return _released;
  }
}

class NikoMobilePortForwardPage extends StatefulWidget {
  final String id;
  final String? password, serverNamespace, connToken;
  final bool? forceRelay, isSharedPassword;
  const NikoMobilePortForwardPage(
      {super.key,
      required this.id,
      this.password,
      this.connToken,
      this.serverNamespace,
      this.forceRelay,
      this.isSharedPassword});
  @override
  State<NikoMobilePortForwardPage> createState() =>
      _NikoMobilePortForwardPageState();
}

class _NikoMobilePortForwardPageState extends State<NikoMobilePortForwardPage> {
  NikoMobileTunnelOwner? _owner;
  bool _closing = false, _closeUnconfirmed = false, _allowPop = false;
  @override
  void initState() {
    super.initState();
    try {
      final scope = widget.serverNamespace;
      if (scope == null) return;
      final owner = NikoMobileTunnelOwner.open(
          globalOwner: gFFI, namespace: scope, peerId: widget.id);
      _owner = owner;
      owner.ffi.start(widget.id,
          isPortForward: true,
          password: widget.password,
          connToken: widget.connToken,
          serverNamespace: scope,
          forceRelay: widget.forceRelay,
          isSharedPassword: widget.isSharedPassword);
    } catch (_) {/* No credentials or raw native errors in UI/logs. */}
  }

  @override
  void dispose() {
    // System destruction can bypass Back; original retired-owner cleanup is
    // reachable from home and retains the CAS until a real exact-owner proof.
    _owner?.close().catchError((Object _) => false);
    super.dispose();
  }

  Future<void> _exit({bool query = false}) async {
    if (_closing) return;
    if (_owner == null) {
      Navigator.pop(context);
      return;
    }
    setState(() => _closing = true);
    final confirmed = await _owner!.close(query: query);
    if (!mounted) return;
    setState(() {
      _closing = false;
      _closeUnconfirmed = !confirmed;
      _allowPop = confirmed;
    });
    if (confirmed) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final ffi = _owner?.ffi;
    final controller = ffi?.nikoTunnelController;
    return Theme(
        data: nikoTheme(Theme.of(context).brightness),
        child: PopScope(
          canPop: _allowPop || _owner == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _exit();
          },
          child: Scaffold(
            appBar: AppBar(
                title: Text(nikoText('TCP 隧道', 'TCP tunnel')),
                leading: IconButton(
                    tooltip: nikoText('退出隧道会话', 'Exit tunnel session'),
                    constraints:
                        const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed: _closing ? null : _exit,
                    icon: const Icon(Icons.arrow_back))),
            body: Column(children: [
              if (_closing || _closeUnconfirmed)
                Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Semantics(
                              liveRegion: true,
                              child: Text(_closing
                                  ? nikoText('正在退出，等待本机资源确认。',
                                      'Exiting; waiting for local resource confirmation.')
                                  : nikoText('退出尚未确认，仍保留本次会话。请查询清理，或重试退出。',
                                      'Exit is unconfirmed. This session is retained. Check cleanup or retry exit.'))),
                          if (!_closing)
                            Wrap(spacing: 8, runSpacing: 8, children: [
                              OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                      minimumSize: const Size(48, 48)),
                                  onPressed: () => _exit(query: true),
                                  child: Text(nikoText(
                                      '查询并重试清理', 'Check and retry cleanup'))),
                              OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                      minimumSize: const Size(48, 48)),
                                  onPressed: _exit,
                                  child: Text(nikoText('重试退出', 'Retry exit'))),
                            ]),
                        ])),
              Expanded(
                  child: controller == null
                      ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(nikoText('此隧道会话未能创建。请关闭页面，检查私服与密码后重试。',
                              'The tunnel session could not be created. Close this page, check the private server and password, and retry.')))
                      : NikoTunnelControllerView(
                          controller: controller,
                          sendCommand: ffi!.sendNikoTunnelCommand,
                          mobile: true)),
            ]),
          ),
        ));
  }
}
