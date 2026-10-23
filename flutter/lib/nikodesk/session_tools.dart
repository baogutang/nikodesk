import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show SessionID;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'metrics.dart';
import 'diagnostics_export.dart';
import 'nightline.dart' show NlTone;
import 'policy.dart';
import 'remote_resolution.dart' show nikoViewRefreshRate, nikoAutomaticFpsOption,
    nikoCancelViewportUpdate;
import 'session_sheet.dart';
import 'session_tools_view.dart';
import 'ui.dart';

void showNikoSessionTools(FFI ffi, {bool diagnostics = false}) {
  if (ffi.closed || !ffi.ffiModel.pi.isSet.value) return;
  final session = ffi.sessionId;
  final language = bind.mainGetLocalOption(key: 'lang');
  NikoLanguage.english = language.isNotEmpty && !language.startsWith('zh');
  ffi.inputModel.enterOrLeave(false);
  ffi.dialogManager.show(
      (_, close, context) => NikoSessionSheet(
          width: diagnostics ? 690 : 590,
          onCancel: close,
          child: diagnostics
              ? NikoDiagnostics(ffi: ffi, onClose: close, session: session)
              : _PictureModes(ffi: ffi, onClose: close, session: session)),
      backDismiss: true,
      clickMaskDismiss: true,
      tag: 'nikodesk-session-panel');
}

class NikoSessionButton extends StatelessWidget {
  final FFI ffi;
  final bool diagnostics;
  const NikoSessionButton(
      {super.key, required this.ffi, this.diagnostics = false});
  @override
  Widget build(BuildContext context) => IconButton(
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        padding: const EdgeInsets.all(6),
        iconSize: 20,
        tooltip: diagnostics
            ? nikoText('会话诊断', 'Session diagnostics')
            : nikoText('画面模式', 'Picture mode'),
        icon: Icon(
            diagnostics ? Icons.monitor_heart_outlined : Icons.tune_rounded),
        onPressed: () => showNikoSessionTools(ffi, diagnostics: diagnostics),
      );
}

/// Refresh rate of the view containing this panel, never another monitor.
double? nikoLocalRefreshRate([BuildContext? context]) =>
    nikoViewRefreshRate(context == null ? null : View.of(context));

class _PictureModes extends StatefulWidget {
  final FFI ffi;
  final VoidCallback onClose;
  final SessionID session;
  const _PictureModes(
      {required this.ffi, required this.onClose, required this.session});
  @override
  State<_PictureModes> createState() => _PictureModesState();
}

class _PictureModesState extends State<_PictureModes> {
  late final SessionID _session;
  bool get _sessionCurrent =>
      !widget.ffi.closed && widget.ffi.sessionId == _session;
  PictureMode _mode = PictureMode.smooth;
  double _quality = 50;
  double _fps = 30;
  bool _loading = true;
  bool _saving = false;
  String? _message;
  NlTone _tone = NlTone.accent;
  String? _currentQuality;
  String? _currentFps;
  bool get _supportsFps =>
      PictureRequest.supportsCustomFps(widget.ffi.ffiModel.pi.version);

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _read();
  }

  Future<void> _read() async {
    if (!_sessionCurrent) return;
    try {
      final session = _session;
      final saved = await bind.sessionGetPeerOption(
          sessionId: session, name: 'nikodesk-picture-mode');
      final quality =
          await bind.sessionGetCustomImageQuality(sessionId: session);
      final fps =
          await bind.sessionGetOption(sessionId: session, arg: 'custom-fps');
      final current = await bind.sessionGetImageQuality(sessionId: session);
      final viewStyle = await bind.sessionGetViewStyle(sessionId: session);
      final codec = await bind.sessionGetOption(
          sessionId: session, arg: 'codec-preference');
      if (mounted && _sessionCurrent) {
        setState(() {
          _mode = PictureRequest.observedMode(saved,
              quality: current,
              percent: quality?.isNotEmpty == true ? quality!.first : null,
              fps: int.tryParse(fps ?? ''),
              viewStyle: viewStyle,
              codecPreference: codec,
              supportsFps: _supportsFps);
          if (quality != null && quality.isNotEmpty) {
            _quality = quality.first.toDouble().clamp(10, 100);
          }
          _fps = (double.tryParse(fps ?? '') ?? 30)
              .clamp(5, nikoMaxFps)
              .toDouble();
          _currentQuality =
              const ['best', 'balanced', 'low', 'custom'].contains(current)
                  ? current
                  : null;
          _currentFps = int.tryParse(fps ?? '')?.toString();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _tone = NlTone.danger;
          _message = nikoText('读取会话偏好失败，请重新打开面板。',
              'Could not read session preferences. Reopen this panel.');
        });
      }
    }
  }

  Future<void> _apply() async {
    if (!_sessionCurrent || _loading || _saving) return;
    nikoCancelViewportUpdate(_session);
    setState(() {
      _saving = true;
      _message = null;
    });
    final request = PictureRequest.forMode(_mode,
        customPercent: _quality.round(),
        customFps: _fps.round(),
        smoothFps: nikoSmoothFps(nikoLocalRefreshRate(context)));
    final session = _session;
    try {
      await bind.sessionPeerOption(
          sessionId: session, name: 'codec-preference', value: 'auto');
      await bind.sessionChangePreferCodec(sessionId: session);
      await bind.sessionSetImageQuality(
          sessionId: session, value: request.imageQuality);
      if (request.bitratePercent != null) {
        await bind.sessionSetCustomImageQuality(
            sessionId: session, value: request.bitratePercent!);
      }
      if (request.requestsCustomFps && _supportsFps) {
        await bind.sessionSetCustomFps(sessionId: session, fps: request.fps!);
      }
      if (!_sessionCurrent) return;
      await bind.sessionPeerOption(sessionId: session,
          name: nikoAutomaticFpsOption,
          value: _mode == PictureMode.smooth && _supportsFps ? '${request.fps}' : '');
      if (request.originalScale) {
        await bind.sessionSetViewStyle(sessionId: session, value: 'original');
        if (_sessionCurrent) await widget.ffi.canvasModel.updateViewStyle();
      }
      await bind.sessionPeerOption(
          sessionId: session, name: 'nikodesk-picture-mode', value: _mode.name);
      await _read();
      if (mounted) {
        setState(() {
          _tone = request.requestsCustomFps && !_supportsFps
              ? NlTone.warn
              : NlTone.accent;
          _message = request.requestsCustomFps && !_supportsFps
              ? nikoText('已发送画质请求。对端版本不支持自定义 FPS，已保留其默认帧率；未应用请求 FPS。',
                  'Quality requested. This peer does not support custom FPS, so its default frame rate was retained.')
              : nikoText('请求已发送并按设备保存。请在诊断中查看实际结果；对端可能继续按能力和负载调整。',
                  'Request sent and saved for this device. See diagnostics for observed results; the peer may adapt to its capabilities and load.');
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _tone = NlTone.danger;
          _message = nikoText('部分参数可能已发送，保存未完成。请查看实际诊断后重试。',
              'Some parameters may have been sent, but saving did not finish. Check diagnostics and retry.');
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => !_sessionCurrent
      ? NikoSessionToolEnded(
          title: nikoText('画面模式', 'Picture mode'), onClose: widget.onClose)
      : NikoPictureModePanel(
          loading: _loading,
          saving: _saving,
          mode: _mode,
          onMode: (mode) => setState(() => _mode = mode),
          smoothFps: nikoSmoothFps(nikoLocalRefreshRate(context)),
          quality: _quality,
          onQuality: (value) => setState(() => _quality = value),
          fps: _fps,
          onFps: (value) => setState(() => _fps = value),
          supportsFps: _supportsFps,
          currentQuality: _currentQuality,
          currentFps: _currentFps,
          message: _message,
          messageTone: _tone,
          onApply: _apply,
          onClose: widget.onClose);
}

class NikoDiagnostics extends StatefulWidget {
  final FFI ffi;
  final VoidCallback onClose;
  final SessionID? session;
  const NikoDiagnostics(
      {super.key, required this.ffi, required this.onClose, this.session});
  @override
  State<NikoDiagnostics> createState() => _NikoDiagnosticsState();
}

class _NikoDiagnosticsState extends State<NikoDiagnostics> {
  late final SessionID _session;
  bool get _sessionCurrent =>
      !widget.ffi.closed && widget.ffi.sessionId == _session;
  Timer? _timer;
  String? _feedback;
  NlTone _feedbackTone = NlTone.accent;
  bool _exporting = false;
  bool? _sampling;
  bool _samplingBusy = false;
  SessionMetrics get _metrics => widget.ffi.qualityMonitorModel.nikoMetrics;
  @override
  void initState() {
    super.initState();
    _session = widget.session ?? widget.ffi.sessionId;
    unawaited(_loadSampling());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadSampling() async {
    try {
      final enabled = await bind.sessionGetToggleOption(
          sessionId: _session, arg: 'show-quality-monitor');
      if (mounted && _sessionCurrent) {
        setState(() => _sampling = enabled);
        if (enabled != null) {
          await widget.ffi.qualityMonitorModel
              .checkShowQualityMonitor(_session);
        }
      }
    } catch (_) {
      if (mounted && _sessionCurrent) setState(() => _sampling = null);
    }
  }

  Future<void> _setSampling(bool enabled) async {
    if (!_sessionCurrent || _samplingBusy || _sampling == null) return;
    setState(() => _samplingBusy = true);
    try {
      final current = await bind.sessionGetToggleOption(
          sessionId: _session, arg: 'show-quality-monitor');
      if (current == null) throw StateError('Sampling state unavailable');
      if (current != enabled && _sessionCurrent) {
        await bind.sessionToggleOption(
            sessionId: _session, value: 'show-quality-monitor');
      }
      await _loadSampling();
      if (_sessionCurrent && _sampling == enabled) {
        await widget.ffi.qualityMonitorModel.checkShowQualityMonitor(_session);
      } else if (mounted && _sessionCurrent) {
        setState(() {
          _feedbackTone = NlTone.warn;
          _feedback = nikoText(
              '采样设置未确认，请重新读取。', 'Sampling was not confirmed. Reload it.');
        });
      }
    } catch (_) {
      if (mounted && _sessionCurrent) {
        setState(() {
          _feedbackTone = NlTone.danger;
          _feedback =
              nikoText('无法确认采样设置，请重试。', 'Could not confirm sampling. Retry.');
        });
      }
    } finally {
      if (mounted) setState(() => _samplingBusy = false);
    }
  }

  Future<void> _export() async {
    if (!_sessionCurrent || _exporting) return;
    setState(() {
      _exporting = true;
      _feedback = null;
    });
    try {
      final report = _metrics.export();
      report['display'] = {
        'source': 'peer_info.displays and CanvasModel.scale',
        'scale': widget.ffi.canvasModel.scale,
        'resolutions': widget.ffi.ffiModel.pi.displays
            .where((d) => d.width > 0 && d.height > 0)
            .map((d) => {'width': d.width, 'height': d.height})
            .toList(),
        'limitation':
            'Display metadata is not a measurement of capture or presentation time.',
      };
      final contents = const JsonEncoder.withIndent('  ').convert(report);
      if (Platform.isAndroid) {
        final saved = await exportNikoAndroidDiagnostics(contents,
            exportFile: (path) => widget.ffi
                .invokeMethod(AndroidChannel.kExportFile, {'path': path}));
        if (!saved) return;
      } else {
        final path = await FilePicker.platform.saveFile(
            dialogTitle: nikoText('保存脱敏诊断', 'Save redacted diagnostics'),
            fileName: 'NikoDesk-diagnostics.json',
            type: FileType.custom,
            allowedExtensions: ['json']);
        if (path == null) return;
        await File(path).writeAsString(contents, flush: true);
      }
      if (mounted) {
        setState(() {
          _feedbackTone = NlTone.ok;
          _feedback = nikoText(
              '已保存脱敏 JSON。报告不含设备 ID、IP、密钥、密码、剪贴板或画面内容。',
              'Redacted JSON saved. No device ID, IP address, key, password, clipboard or screen content is included.');
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _feedbackTone = NlTone.danger;
          _feedback = nikoText('导出失败。请选择可写的位置后重试。',
              'Export failed. Choose a writable location and retry.');
        });
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => !_sessionCurrent
      ? NikoSessionToolEnded(
          title: nikoText('会话诊断', 'Session diagnostics'),
          onClose: widget.onClose)
      : NikoDiagnosticsPanel(
          metrics: _metrics,
          sampling: _sampling,
          samplingBusy: _samplingBusy,
          onSampling: _setSampling,
          onReloadSampling: _loadSampling,
          resolutions: [
            for (final display in widget.ffi.ffiModel.pi.displays)
              (display.width, display.height)
          ],
          scale: widget.ffi.canvasModel.scale,
          feedback: _feedback,
          feedbackTone: _feedbackTone,
          exporting: _exporting,
          onExport: _export,
          onClose: widget.onClose);
}
