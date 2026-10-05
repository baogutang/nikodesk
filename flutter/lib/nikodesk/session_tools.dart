import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show CustomAlertDialog, SessionID;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'metrics.dart';
import 'diagnostics_export.dart';
import 'policy.dart';
import 'ui.dart';

void showNikoSessionTools(FFI ffi, {bool diagnostics = false}) {
  if (ffi.closed || !ffi.ffiModel.pi.isSet.value) return;
  final session = ffi.sessionId;
  final language = bind.mainGetLocalOption(key: 'lang');
  NikoLanguage.english = language.isNotEmpty && !language.startsWith('zh');
  ffi.inputModel.enterOrLeave(false);
  ffi.dialogManager.show((_, close, context) {
    final width = (MediaQuery.sizeOf(context).width - 64)
        .clamp(0.0, diagnostics ? 690.0 : 590.0);
    return CustomAlertDialog(
      onCancel: close,
      contentBoxConstraints: BoxConstraints(maxWidth: width),
      content: SizedBox(
        width: width,
        child: diagnostics
            ? NikoDiagnostics(ffi: ffi, onClose: close, session: session)
            : _PictureModes(ffi: ffi, onClose: close, session: session),
      ),
    );
  }, backDismiss: true, tag: 'nikodesk-session-panel');
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

String _modeLabel(PictureMode mode) {
  switch (mode) {
    case PictureMode.office:
      return nikoText('办公清晰', 'Office clarity');
    case PictureMode.smooth:
      return nikoText('操作流畅', 'Responsive control');
    case PictureMode.constrained:
      return nikoText('弱网稳定', 'Constrained network');
    case PictureMode.custom:
      return nikoText('自定义', 'Custom');
  }
}

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
          _fps = (double.tryParse(fps ?? '') ?? 30).clamp(5, 60);
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
          _message = nikoText('读取会话偏好失败，请重新打开面板。',
              'Could not read session preferences. Reopen this panel.');
        });
      }
    }
  }

  Future<void> _apply() async {
    if (!_sessionCurrent || _loading || _saving) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    final request = PictureRequest.forMode(_mode,
        customPercent: _quality.round(), customFps: _fps.round());
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
      if (request.originalScale) {
        await bind.sessionSetViewStyle(sessionId: session, value: 'original');
        if (_sessionCurrent) await widget.ffi.canvasModel.updateViewStyle();
      }
      await bind.sessionPeerOption(
          sessionId: session, name: 'nikodesk-picture-mode', value: _mode.name);
      await _read();
      if (mounted) {
        setState(() => _message = request.requestsCustomFps && !_supportsFps
            ? nikoText('已发送画质请求。对端版本不支持自定义 FPS，已保留其默认帧率；未应用请求 FPS。',
                'Quality requested. This peer does not support custom FPS, so its default frame rate was retained.')
            : nikoText('请求已发送并按设备保存。请在诊断中查看实际结果；对端可能继续按能力和负载调整。',
                'Request sent and saved for this device. See diagnostics for observed results; the peer may adapt to its capabilities and load.'));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = nikoText('部分参数可能已发送，保存未完成。请查看实际诊断后重试。',
            'Some parameters may have been sent, but saving did not finish. Check diagnostics and retry.'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _description(PictureMode mode) {
    switch (mode) {
      case PictureMode.office:
        return nikoText('上游 best 画质 + 原始 1:1 缩放；编码器自动协商。',
            'Upstream best quality + original 1:1 view; automatic codec negotiation.');
      case PictureMode.smooth:
        return nikoText('帧率上限 60、50% 码率比例（需要对端支持）；对端仍按网络延迟自行下调。保留当前缩放。',
            'Up to 60 FPS at a 50% bitrate ratio when supported; the peer still lowers both when the network is slow. Keeps the current view scale.');
      case PictureMode.constrained:
        return nikoText('保守请求：30% 码率比例、15 FPS（需要对端支持）。沿用上游 QoS；弱网改善尚未测量。',
            'Conservative request: 30% bitrate ratio and 15 FPS when supported. Uses upstream QoS; weak-network improvement is unmeasured.');
      case PictureMode.custom:
        return nikoText('设置码率比例与目标 FPS；这些值不代表实测码率或呈现帧率。',
            'Set bitrate ratio and target FPS; these are not measured bitrate or presentation FPS.');
    }
  }

  @override
  Widget build(BuildContext context) => !_sessionCurrent
      ? Padding(
          padding: const EdgeInsets.all(24),
          child: Text(nikoText(
              '此会话已结束，请关闭面板。', 'This session has ended. Close the panel.')))
      : SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(nikoText('画面模式', 'Picture mode'),
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(nikoText('编码器自动协商；不强制硬编、H.264 或 4:4:4。',
                    'Codec is negotiated automatically. Hardware encoding, H.264 and 4:4:4 are not forced.')),
                const SizedBox(height: 12),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else
                  ...PictureMode.values
                      .map((mode) => RadioListTile<PictureMode>(
                            contentPadding: EdgeInsets.zero,
                            value: mode,
                            groupValue: _mode,
                            onChanged: _saving
                                ? null
                                : (value) => setState(() => _mode = value!),
                            title: Text(_modeLabel(mode)),
                            subtitle: Text(_description(mode)),
                          )),
                if (_mode == PictureMode.custom) ...[
                  const Divider(),
                  Text(
                      '${nikoText('码率比例', 'Bitrate ratio')}: ${_quality.round()}%'),
                  Slider(
                      value: _quality,
                      min: 10,
                      max: 100,
                      divisions: 90,
                      label: '${_quality.round()}%',
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _quality = value)),
                  Text('${nikoText('目标 FPS', 'Target FPS')}: ${_fps.round()}'),
                  Slider(
                      value: _fps,
                      min: 5,
                      max: 60,
                      divisions: 55,
                      label: '${_fps.round()}',
                      onChanged: _saving || !_supportsFps
                          ? null
                          : (value) => setState(() => _fps = value)),
                ],
                if (!_supportsFps)
                  Text(nikoText('对端版本未知或低于 1.2.0：不会发送自定义 FPS。',
                      'Peer version is unknown or older than 1.2.0: custom FPS will not be sent.')),
                const SizedBox(height: 12),
                Text(
                    '${nikoText('当前核心画质设置', 'Current core quality setting')}: ${_currentQuality ?? nikoText('未知', 'Unknown')}'
                    '${_currentQuality == 'custom' ? ' · ${nikoText('目标 FPS', 'Target FPS')}: ${_currentFps ?? nikoText('未知', 'Unknown')}' : ''}',
                    style: Theme.of(context).textTheme.bodySmall),
                if (_message != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_message!)),
                const SizedBox(height: 20),
                Wrap(spacing: 12, runSpacing: 8, children: [
                  TextButton(
                      onPressed: _saving ? null : widget.onClose,
                      child: Text(nikoText('关闭', 'Close'))),
                  FilledButton(
                      onPressed: _loading || _saving ? null : _apply,
                      child: Text(nikoText('应用并保存', 'Apply and save'))),
                ]),
              ]));
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
        setState(() => _feedback = nikoText(
            '采样设置未确认，请重新读取。', 'Sampling was not confirmed. Reload it.'));
      }
    } catch (_) {
      if (mounted && _sessionCurrent) {
        setState(() => _feedback =
            nikoText('无法确认采样设置，请重试。', 'Could not confirm sampling. Retry.'));
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
        setState(() => _feedback = nikoText(
            '已保存脱敏 JSON。报告不含设备 ID、IP、密钥、密码、剪贴板或画面内容。',
            'Redacted JSON saved. No device ID, IP address, key, password, clipboard or screen content is included.'));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _feedback = nikoText('导出失败。请选择可写的位置后重试。',
            'Export failed. Choose a writable location and retry.'));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _name(String name) {
    switch (name) {
      case 'receiveKiBps':
        return nikoText('接收速率', 'Receive throughput');
      case 'decodedCallbackFps':
        return nikoText('解码回调帧率', 'Decoded callback FPS');
      case 'applicationRttMs':
        return nikoText('应用层往返', 'Application round trip');
      case 'targetBitrateKbps':
        return nikoText('目标码率快照', 'Target bitrate snapshot');
      case 'receivedCodec':
        return nikoText('实际收到的编码格式', 'Received codec');
      case 'decodedChroma':
        return nikoText('解码色度格式', 'Decoded chroma');
      case 'decoderBackend':
        return nikoText('解码实例', 'Decoder backend');
      case 'hardwareDecoder':
        return nikoText('硬件解码实例', 'Hardware decoder');
      case 'decodeConvertMeanMs':
        return nikoText('解码与转换调用均值', 'Mean decode + convert call');
      case 'nativeSubmitMeanMs':
        return nikoText('原生提交调用均值', 'Mean native submit call');
      case 'deltaQueuePeak':
        return nikoText('非关键帧队列峰值', 'Delta queue peak');
      case 'deltaOverflow':
        return nikoText('非关键帧队列溢出次数', 'Delta queue overflows');
      case 'renderSkips':
        return nikoText('显示路径跳过次数', 'Render path skips');
      default:
        return name;
    }
  }

  String _limit(String name) {
    if (NikoLanguage.english) return SessionMetrics.specs[name]!.limitation;
    switch (name) {
      case 'receiveKiBps':
        return '约 1 秒窗口，包含全部接收消息，不等同于视频码率。上游 kB/s 实际按 1024 计算。';
      case 'decodedCallbackFps':
        return '每台显示器进入解码回调的帧率，不能证明渲染器接收或屏幕实际呈现；静态桌面低帧率不自动表示卡顿。';
      case 'applicationRttMs':
        return '应用探测往返时间，不是网络 Ping、单向延迟或输入到画面延迟。';
      case 'targetBitrateKbps':
        return '编码器目标值快照，不是实测吞吐。';
      case 'receivedCodec':
        return '真实接收编码格式；不能据此判断硬件编码或解码。';
      case 'decodedChroma':
        return '真实解码色度格式；4:4:4 不等于无损。';
      case 'decoderBackend':
        return '按显示器记录实际成功输出帧的解码实例；格式或偏好设置不是实现证明，未收到真实输出时为未知。';
      case 'hardwareDecoder':
        return '来自实际输出帧的解码实例；平台未报告时为未知，不能据此判断被控端是否硬件编码。';
      case 'decodeConvertMeanMs':
        return '最多每秒 8 次的解码与转换调用耗时采样，包含失败调用；不等于纯解码、采集、呈现或端到端延迟。';
      case 'nativeSubmitMeanMs':
        return '原生提交函数的调用耗时采样；该接口没有接收或呈现确认，不能证明屏幕已显示。';
      case 'deltaQueuePeak':
        return '当前采样窗口内非关键帧队列的观测峰值；不包含关键帧或整个视频管线。';
      case 'deltaOverflow':
        return '当前采样窗口内非关键帧队列的实际溢出计数；不等于网络丢包或全部丢帧。';
      case 'renderSkips':
        return '显示路径中被明确记录的跳过次数；详细原因随脱敏诊断导出，不等于全部丢帧。';
      default:
        return SessionMetrics.specs[name]?.limitation ?? '';
    }
  }

  String _value(String name) {
    final value = _metrics.current(name);
    if (value == null) {
      return _metrics.isStale(name)
          ? nikoText('已失效', 'Stale')
          : nikoText('未知', 'Unknown');
    }
    if (value is Map<String, Object?>) {
      return value.entries
          .map((e) =>
              '${nikoText('显示器', 'Display')} ${(int.tryParse(e.key) ?? -1) + 1}: ${_formatValue(e.value)}')
          .join(' · ');
    }
    return _formatValue(value);
  }

  String _formatValue(Object? value) {
    if (value == null) return nikoText('未知', 'Unknown');
    if (value is bool) {
      return value ? nikoText('是', 'Yes') : nikoText('否', 'No');
    }
    if (value is num) {
      return value == value.roundToDouble()
          ? value.toInt().toString()
          : value.toStringAsFixed(2);
    }
    return value.toString();
  }

  String _unit(String name) {
    switch (name) {
      case 'decodedCallbackFps':
        return 'fps';
      case 'decodeConvertMeanMs':
      case 'nativeSubmitMeanMs':
        return 'ms';
      case 'deltaQueuePeak':
        return nikoText('项', 'entries');
      case 'deltaOverflow':
      case 'renderSkips':
        return nikoText('次 / 采样窗口', 'events / window');
      case 'receivedCodec':
      case 'decodedChroma':
      case 'decoderBackend':
      case 'hardwareDecoder':
        return '';
      default:
        return SessionMetrics.specs[name]?.unit ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_sessionCurrent) {
      return Padding(
          padding: const EdgeInsets.all(24),
          child: Text(nikoText(
              '此会话已结束，请关闭面板。', 'This session has ended. Close the panel.')));
    }
    final metrics = _metrics;
    final connection = metrics.connectionSampledAt;
    final unknown = nikoText('未知', 'Unknown');
    final displays = widget.ffi.ffiModel.pi.displays;
    return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                    child: Text(nikoText('会话诊断', 'Session diagnostics'),
                        style: Theme.of(context).textTheme.headlineSmall)),
                IconButton(
                    tooltip: nikoText('关闭', 'Close'),
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close))
              ]),
              const SizedBox(height: 8),
              Text(nikoText('每秒刷新 · 10 秒无新样本后标记失效 · 脱敏报告仅在导出时保存',
                  'Updates once per second · Samples expire after 10 seconds · Redacted reports are saved only on export')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(nikoText('性能采样', 'Performance sampling')),
                subtitle: Text(nikoText('与会话性能浮窗同步；开启后才会记录原生视频处理样本。',
                    'Shares the session performance overlay setting. Native video samples are recorded while enabled.')),
                value: _sampling ?? false,
                onChanged:
                    _sampling == null || _samplingBusy ? null : _setSampling,
              ),
              if (_sampling == null)
                TextButton(
                  onPressed: _loadSampling,
                  child: Text(nikoText(
                      '采样状态未知，重新读取', 'Sampling state unknown. Reload')),
                ),
              const SizedBox(height: 16),
              NikoCard(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        '${nikoText('连接路径', 'Connection path')}: ${connection == null ? unknown : metrics.direct == true ? nikoText('直连', 'Direct') : nikoText('中继', 'Relay')} · ${metrics.transport ?? unknown}'),
                    const SizedBox(height: 6),
                    Text(
                        '${nikoText('会话加密', 'Session encryption')}: ${connection == null ? unknown : metrics.secure == true ? nikoText('核心报告已加密', 'Encrypted per core event') : nikoText('核心报告未加密', 'Unencrypted per core event')}'),
                    const SizedBox(height: 6),
                    if (metrics.direct != true)
                      SelectableText(
                          '${nikoText('中继目标', 'Relay target')}: ${metrics.relayTarget ?? unknown}'),
                    Text(
                        '${nikoText('代理路径', 'Proxy path')}: ${metrics.proxyInUse == null ? unknown : metrics.proxyInUse == true ? nikoText('已使用本次连接的代理', 'Uses this connection’s captured proxy') : nikoText('未使用代理', 'No proxy used')}'),
                    if (metrics.transport == 'WebSocket')
                      Text(
                          '${nikoText('WebSocket TLS', 'WebSocket TLS')}: ${metrics.websocketTls == null ? unknown : metrics.websocketTls == true ? nikoText('已启用', 'Enabled') : nikoText('未启用', 'Disabled')}'),
                    const SizedBox(height: 6),
                    Text(
                        '${metrics.connectionFromCache ? nikoText('会话缓存接收时间（非新握手）', 'Session cache received (not a new handshake)') : nikoText('握手采样时间', 'Handshake sampled at')}: ${connection?.toLocal().toIso8601String() ?? unknown}',
                        style: Theme.of(context).textTheme.bodySmall),
                    Text(
                        nikoText(
                            '服务器注册、会话认证与加密是不同状态。中继目标来自本次连接固定的路由，非解析后的 IP；导出时隐藏地址。',
                            'Server registration, session authentication and encryption are separate states. The relay target comes from this connection’s captured route, not its resolved IP. Exports hide the address.'),
                        style: Theme.of(context).textTheme.bodySmall),
                  ])),
              const SizedBox(height: 12),
              Text(
                  '${nikoText('源分辨率', 'Source resolution')}: ${displays.isEmpty ? unknown : displays.map((d) => '${d.width} × ${d.height}').join(' · ')}'),
              Text(
                  '${nikoText('当前画布缩放', 'Current canvas scale')}: ${widget.ffi.canvasModel.scale.toStringAsFixed(2)}×'),
              const SizedBox(height: 12),
              ...SessionMetrics.specs.entries
                  .where((entry) => entry.key != 'nativeVideo')
                  .map((entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: NikoCard(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(spacing: 12, runSpacing: 4, children: [
                                Text(_name(entry.key),
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                                Text(
                                    '${_value(entry.key)}${_unit(entry.key).isEmpty ? '' : ' ${_unit(entry.key)}'}',
                                    style:
                                        Theme.of(context).textTheme.titleMedium)
                              ]),
                              const SizedBox(height: 6),
                              Text(_limit(entry.key),
                                  style: Theme.of(context).textTheme.bodySmall),
                              const SizedBox(height: 4),
                              Text(
                                  '${nikoText('采样', 'Sampled')}: ${metrics.sample(entry.key)?.sampledAt.toLocal().toIso8601String() ?? unknown}',
                                  style: Theme.of(context).textTheme.bodySmall),
                              Text(entry.value.source,
                                  style: Theme.of(context).textTheme.bodySmall),
                            ]),
                      ))),
              Text(nikoText(
                  '未知：硬件编码与回退原因、采集 / 编码 / 纯解码 / 屏幕呈现耗时、输入到画面延迟和全部丢帧。原生统计须开启性能面板且绑定当前连接后才有样本；未进行性能 A/B 验证。',
                  'Unknown: hardware encoding and fallback reasons; capture/encode/pure-decode/presentation timing; input-to-photon latency and total dropped frames. Native samples require the performance panel and a verified current connection. No performance A/B verification has been performed.')),
              const SizedBox(height: 16),
              if (_feedback != null)
                Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_feedback!)),
              OutlinedButton.icon(
                  onPressed: _exporting ? null : _export,
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label:
                      Text(nikoText('导出脱敏诊断', 'Export redacted diagnostics'))),
            ]));
  }
}
