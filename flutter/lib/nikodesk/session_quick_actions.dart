import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart'
    show CustomAlertDialog, SessionID, isMobile, isDesktop, isWindows, isLinux;
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'connection_progress.dart';
import 'remote_resolution.dart';
import 'session_quick_actions_view.dart';
import 'session_shortcuts.dart';
import 'ui.dart';

void showNikoSessionQuickActions(FFI ffi) {
  if (ffi.closed || !ffi.ffiModel.pi.isSet.value) return;
  final session = ffi.sessionId;
  NikoLanguage.usePreference(bind.mainGetLocalOption(key: 'lang'));
  ffi.inputModel.enterOrLeave(false);
  ffi.dialogManager.show((_, close, context) {
    final width = (MediaQuery.sizeOf(context).width - 64).clamp(0.0, 560.0);
    return CustomAlertDialog(
      onCancel: close,
      contentBoxConstraints: BoxConstraints(maxWidth: width),
      content: SizedBox(
        width: width,
        child: _NikoSessionQuickActions(
            ffi: ffi, session: session, onClose: close),
      ),
    );
  }, backDismiss: true, tag: 'nikodesk-quick-actions');
}

class _NativeShortcutInput implements NikoShortcutInput {
  final InputModel input;
  final SessionID session;
  _NativeShortcutInput(this.input, this.session);

  @override
  void releaseCapture() => input.enterOrLeave(false);

  @override
  void setModifiers(NikoShortcutKeys? keys) {
    input.resetModifiers();
    input.ctrl = keys?.control ?? false;
    input.command = keys?.command ?? false;
    input.alt = keys?.alt ?? false;
    input.shift = keys?.shift ?? false;
  }

  @override
  Future<void> inputKey(String key, {required bool press}) =>
      input.inputNikoShortcutKey(session, key, press: press);
}

class _NikoSessionQuickActions extends StatefulWidget {
  final FFI ffi;
  final SessionID session;
  final VoidCallback onClose;
  const _NikoSessionQuickActions(
      {required this.ffi, required this.session, required this.onClose});

  @override
  State<_NikoSessionQuickActions> createState() =>
      _NikoSessionQuickActionsState();
}

class _NikoSessionQuickActionsState extends State<_NikoSessionQuickActions> {
  String? _viewStyle;
  NikoMacShortcutMode? _macShortcutMode;
  bool? _autoFitResolution;
  NikoCaptureMode? _captureMode;
  bool get _macMappingAvailable =>
      isDesktop &&
      (isWindows || isLinux) &&
      widget.ffi.ffiModel.pi.platform == 'Mac OS';
  bool get _sessionCurrent =>
      !widget.ffi.closed &&
      widget.ffi.sessionId == widget.session &&
      widget.ffi.nikoConnectionProgress.value.phase ==
          NikoConnectionPhase.connected;
  bool get _keyboardAllowed =>
      _sessionCurrent &&
      widget.ffi.connType == ConnType.defaultConn &&
      !widget.ffi.ffiModel.viewOnly &&
      widget.ffi.ffiModel.keyboard &&
      widget.ffi.ffiModel.permissions['keyboard'] != false;
  bool get _canvasAllowed =>
      _sessionCurrent &&
      {ConnType.defaultConn, ConnType.viewCamera}
          .contains(widget.ffi.connType) &&
      widget.ffi.canvasModel.size.width > 0 &&
      widget.ffi.canvasModel.size.height > 0 &&
      widget.ffi.canvasModel.getDisplayWidth() > 0 &&
      widget.ffi.canvasModel.getDisplayHeight() > 0;

  @override
  void initState() {
    super.initState();
    unawaited(_readViewStyle());
    if (_macMappingAvailable) unawaited(_readMacShortcutMode());
    if (_resolutionAvailable) unawaited(_readAutoFitResolution());
    if (_resolutionAvailable) unawaited(_readCaptureMode());
  }

  Future<void> _readCaptureMode() async {
    try {
      final mode = await nikoReadCaptureMode(widget.session);
      if (mounted && _sessionCurrent) setState(() => _captureMode = mode);
    } catch (_) {
      if (mounted) setState(() => _captureMode = null);
    }
  }

  Future<void> _setCaptureMode(NikoCaptureMode mode) async {
    if (!_sessionCurrent) throw StateError('Session unavailable');
    await nikoDeclareCaptureWidth(widget.session, mode: mode);
    if (mounted) setState(() => _captureMode = mode);
  }

  bool get _resolutionAvailable =>
      widget.ffi.connType == ConnType.defaultConn;

  Future<void> _readAutoFitResolution() async {
    try {
      final enabled = await nikoReadAutoFitResolution(widget.session);
      if (mounted && _sessionCurrent) {
        setState(() => _autoFitResolution = enabled);
      }
    } catch (_) {
      if (mounted) setState(() => _autoFitResolution = null);
    }
  }

  Future<void> _setAutoFitResolution(bool enabled) async {
    if (!_sessionCurrent) throw StateError('Session unavailable');
    await nikoSetAutoFitResolution(widget.session, enabled);
    if (mounted) setState(() => _autoFitResolution = enabled);
  }

  Future<void> _setRemoteResolution(NikoDisplayMode mode) async {
    if (!_keyboardAllowed) throw StateError('Remote input unavailable');
    await nikoChangeRemoteResolution(widget.ffi, widget.session, mode);
    if (!_keyboardAllowed) throw StateError('Remote input unavailable');
  }

  Future<void> _readMacShortcutMode() async {
    try {
      final mode = await widget.ffi.inputModel.readNikoMacShortcutMode();
      if (mounted && _sessionCurrent) setState(() => _macShortcutMode = mode);
    } catch (_) {
      if (mounted) setState(() => _macShortcutMode = null);
    }
  }

  Future<void> _setMacShortcutMode(NikoMacShortcutMode mode) async {
    if (!_keyboardAllowed || !_macMappingAvailable) {
      throw StateError('Remote input unavailable');
    }
    await widget.ffi.inputModel.setNikoMacShortcutMode(widget.session, mode);
    if (!_keyboardAllowed) throw StateError('Remote input unavailable');
    if (mounted) setState(() => _macShortcutMode = mode);
  }

  Future<void> _readViewStyle() async {
    try {
      final style = await bind.sessionGetViewStyle(sessionId: widget.session);
      if (mounted && _sessionCurrent) setState(() => _viewStyle = style);
    } catch (_) {
      if (mounted) setState(() => _viewStyle = null);
    }
  }

  Future<void> _shortcut(NikoSessionShortcut shortcut) async {
    final keys = nikoShortcutKeys(shortcut, widget.ffi.ffiModel.pi.platform);
    if (keys == null) throw StateError('Shortcut unavailable');
    await sendNikoShortcut(
        keys, _NativeShortcutInput(widget.ffi.inputModel, widget.session),
        allowed: () => _keyboardAllowed);
    if (!_keyboardAllowed) throw StateError('Remote input unavailable');
  }

  Future<void> _setViewStyle(String style) async {
    if (!_canvasAllowed || !{'adaptive', 'original'}.contains(style)) {
      throw StateError('Canvas unavailable');
    }
    await bind.sessionSetViewStyle(sessionId: widget.session, value: style);
    if (!_canvasAllowed) throw StateError('Canvas unavailable');
    await widget.ffi.canvasModel.updateViewStyle();
    if (!_canvasAllowed) throw StateError('Canvas unavailable');
    final observed = await bind.sessionGetViewStyle(sessionId: widget.session);
    if (!_canvasAllowed || observed != style) {
      throw StateError('View style unconfirmed');
    }
    if (mounted) setState(() => _viewStyle = observed);
  }

  void _resetCanvas() {
    if (!_canvasAllowed) throw StateError('Canvas unavailable');
    widget.ffi.canvasModel.reset();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([
          widget.ffi.ffiModel,
          widget.ffi.canvasModel,
          widget.ffi.nikoConnectionProgress,
        ]),
        builder: (context, _) => NikoSessionQuickActionsPanel(
          peerPlatform: widget.ffi.ffiModel.pi.platform,
          keyboardAllowed: _keyboardAllowed,
          canvasAllowed: _canvasAllowed,
          viewStyle: _viewStyle,
          macShortcutMode: _macShortcutMode,
          onMacShortcutMode: _macMappingAvailable ? _setMacShortcutMode : null,
          onShortcut: _shortcut,
          onViewStyle: _setViewStyle,
          onResetCanvas: isMobile ? _resetCanvas : null,
          remoteResolution:
              _sessionCurrent ? nikoRemoteResolution(widget.ffi) : null,
          autoFitResolution: _autoFitResolution,
          onRemoteResolution:
              _resolutionAvailable ? _setRemoteResolution : null,
          onAutoFitResolution:
              _resolutionAvailable ? _setAutoFitResolution : null,
          captureMode: _captureMode,
          onCaptureMode: _resolutionAvailable ? _setCaptureMode : null,
          onClose: widget.onClose,
        ),
      );
}
