import 'dart:async';

import 'package:flutter/material.dart';

import 'connection_progress.dart';
import 'metrics.dart';
import 'nightline.dart';
import 'ui.dart';

class NikoQualityOverlay extends StatefulWidget {
  final SessionMetrics metrics;
  final int? display;
  const NikoQualityOverlay({super.key, required this.metrics, this.display});

  @override
  State<NikoQualityOverlay> createState() => _NikoQualityOverlayState();
}

class _NikoQualityOverlayState extends State<NikoQualityOverlay> {
  late final Timer _expiry;

  @override
  void initState() {
    super.initState();
    _expiry = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _expiry.cancel();
    super.dispose();
  }

  String _value(String name, String unit) {
    final value = widget.metrics.current(name);
    if (value == null) {
      return widget.metrics.isStale(name)
          ? nikoText('已过期', 'Expired')
          : nikoText('未知', 'Unknown');
    }
    if (value is Map<String, Object?>) {
      if (widget.display != null && widget.display! >= 0) {
        final sample = value[widget.display.toString()];
        return sample == null
            ? nikoText('未知', 'Unknown')
            : _format(sample, unit);
      }
      return value.entries
          .map((e) =>
              '${e.key}: ${e.value == null ? nikoText('未知', 'Unknown') : _format(e.value!, unit)}')
          .join(nikoSep);
    }
    return _format(value, unit);
  }

  String _format(Object value, String unit) {
    if (value is bool) {
      return value ? nikoText('是', 'Yes') : nikoText('否', 'No');
    }
    final text = value is num && value == value.roundToDouble()
        ? value.toInt().toString()
        : value is num
            ? value.toStringAsFixed(2)
            : value.toString();
    return unit.isEmpty ? text : '$text $unit';
  }

  String _route() {
    final metrics = widget.metrics;
    if (metrics.direct == null) return nikoText('未知', 'Unknown');
    final route =
        metrics.direct! ? nikoText('直连', 'Direct') : nikoText('中继', 'Relay');
    return metrics.transport == null ? route : '$route$nikoSep${metrics.transport}';
  }

  String _duration(Duration? value) =>
      value == null ? nikoText('未知', 'Unknown') : '${value.inMilliseconds} ms';

  String _authentication(NikoConnectionTimings? setup) {
    final text = _duration(setup?.authentication);
    final wait = setup?.userWait;
    if (wait == null || wait == Duration.zero) return text;
    return nikoText('$text（另等待输入/确认 ${wait.inMilliseconds} ms）',
        '$text (+${wait.inMilliseconds} ms waiting for input/approval)');
  }

  Widget _line(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
                child: Text(label,
                    style: Theme.of(context).textTheme.labelMedium)),
            const SizedBox(width: 8),
            Flexible(
                child: Text(value,
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelMedium)),
          ],
        ),
      );

  NikoHostVideo? _host() {
    final value = widget.metrics.current('hostVideo');
    if (value is! Map<String, NikoHostVideo> || value.isEmpty) return null;
    final display = widget.display;
    if (display != null && display >= 0) return value[display.toString()];
    final keys = value.keys.toList()..sort();
    return value[keys.first];
  }

  double? _localDecodeMs(NikoHostVideo? host) {
    final value = widget.metrics.current('decodeConvertMeanMs');
    if (value is! Map<String, Object?>) return null;
    final key = (widget.display ?? host?.display)?.toString();
    final sample = key == null ? null : value[key];
    return sample is num ? sample.toDouble() : null;
  }

  String _unknownOr(String? text) => text ?? nikoText('未知', 'Unknown');

  String _hostPicture(NikoHostVideo host) {
    final kind =
        host.hardware ? nikoText('硬件', 'hardware') : nikoText('软件', 'software');
    final codec = host.encoder.isEmpty ? '' : '$nikoSep${host.encoder} $kind';
    return '${host.width}×${host.height}$codec';
  }

  String _hostStages(NikoHostVideo host) {
    String ms(double? v) => v == null ? '?' : v.toStringAsFixed(1);
    final capture = host.captureIncludesWait
        ? nikoText('采集(含等待)', 'capture (incl. wait)')
        : nikoText('采集', 'capture');
    return '$capture ${ms(host.captureMs)}$nikoSep${nikoText('转换', 'convert')} '
        '${ms(host.convertMs)}$nikoSep${nikoText('编码', 'encode')} ${ms(host.encodeMs)} ms';
  }

  String? _frameCap(NikoHostVideo? host) {
    if (host == null) return null;
    final cap = nikoFrameCap(
        limit: host.limit,
        refreshHz: host.refreshHz,
        hostMaxFps: host.processingMaxFps,
        localDecodeMs: _localDecodeMs(host));
    if (cap == null) return null;
    final reason = switch (cap.reason) {
      NikoFrameCapReason.setting => nikoText(
          '帧率设定（含网络自适应）', 'frame-rate setting, incl. network adaptation'),
      NikoFrameCapReason.display =>
        nikoText('被控显示器刷新率', 'controlled display refresh rate'),
      NikoFrameCapReason.hostProcessing =>
        nikoText('被控端每帧处理耗时', 'controlled side per-picture work'),
      NikoFrameCapReason.localDecode =>
        nikoText('本机解码耗时', 'local decoding time'),
    };
    return nikoText(
        '${cap.fps.round()}/s（$reason）', '${cap.fps.round()}/s ($reason)');
  }

  @override
  Widget build(BuildContext context) {
    if (NlColors.maybeOf(context) != null) return _telemetry(context);
    final scheme = Theme.of(context).colorScheme;
    final setup = widget.metrics.setup;
    final host = _host();
    return Material(
      color: scheme.surface.withOpacity(.94),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: BoxConstraints(
            maxWidth: 265, maxHeight: MediaQuery.sizeOf(context).height * .8),
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in [
              (nikoText('接收吞吐', 'Receive rate'), 'receiveKiBps', 'KiB/s'),
              (
                nikoText('解码回调帧率', 'Decoded callback FPS'),
                'decodedCallbackFps',
                'fps'
              ),
              (nikoText('应用往返', 'Application RTT'), 'applicationRttMs', 'ms'),
              (nikoText('目标码率', 'Target bitrate'), 'targetBitrateKbps', 'kbps'),
              (nikoText('接收编码', 'Received codec'), 'receivedCodec', ''),
              (nikoText('解码色度', 'Decoded chroma'), 'decodedChroma', ''),
              (nikoText('解码实现', 'Decoder backend'), 'decoderBackend', ''),
              (nikoText('硬解实例', 'Hardware decoder'), 'hardwareDecoder', ''),
              (
                nikoText('解码与转换调用', 'Decode + convert call'),
                'decodeConvertMeanMs',
                'ms'
              ),
              (
                nikoText('原生提交调用', 'Native submit call'),
                'nativeSubmitMeanMs',
                'ms'
              ),
              (nikoText('非关键帧队列峰值', 'Delta queue peak'), 'deltaQueuePeak', ''),
              (nikoText('队列溢出次数', 'Delta overflows'), 'deltaOverflow', ''),
              (nikoText('显示路径跳过次数', 'Render path skips'), 'renderSkips', ''),
            ])
              _line(context, row.$1, _value(row.$2, row.$3)),
            const Divider(height: 14),
            _line(context, nikoText('连接路径', 'Route'), _route()),
            _line(context, nikoText('建立连接', 'Connection setup'),
                _duration(setup?.transport)),
            _line(context, nikoText('认证', 'Authentication'),
                _authentication(setup)),
            _line(context, nikoText('首帧', 'First frame'),
                _duration(setup?.firstFrame)),
            const Divider(height: 14),
            _line(context, nikoText('被控端画面', 'Remote picture'),
                _unknownOr(host == null ? null : _hostPicture(host))),
            _line(
                context,
                nikoText('被控端新画面', 'Remote new pictures'),
                _unknownOr(host?.fps == null
                    ? null
                    : '${host!.fps!.toStringAsFixed(1)}/s')),
            _line(
                context,
                nikoText('被控显示器', 'Remote display'),
                _unknownOr(host?.refreshHz == null
                    ? null
                    : '${host!.refreshHz!.round()} Hz')),
            _line(context, nikoText('被控端每帧', 'Remote per picture'),
                _unknownOr(host == null ? null : _hostStages(host))),
            _line(context, nikoText('帧率上限', 'Frame-rate ceiling'),
                _unknownOr(_frameCap(host))),
          ],
        )),
      ),
    );
  }

  /// Latest scalar sample of [name] for this display, if any.
  num? _number(String name) {
    final value = widget.metrics.current(name);
    if (value is num) return value;
    if (value is Map<String, Object?>) {
      final display = widget.display;
      final keys = value.keys.toList()..sort();
      final key = display != null && display >= 0
          ? display.toString()
          : (keys.isEmpty ? null : keys.first);
      final sample = key == null ? null : value[key];
      if (sample is num) return sample;
    }
    return null;
  }

  /// Nightline telemetry HUD: three headline figures over the same rows as
  /// the plain panel. It stays dark in both modes, like the session dock.
  Widget _telemetry(BuildContext context) {
    final nl = NlColors.dark;
    final setup = widget.metrics.setup;
    final host = _host();
    final fps = _number('decodedCallbackFps');
    final rtt = _number('applicationRttMs');
    final kib = _number('receiveKiBps');
    Widget figure(String label, String value) => Expanded(
        child: Container(
            padding: const EdgeInsets.all(NlSpace.s2),
            decoration: BoxDecoration(
                color: const Color(0x0AFFFFFF),
                borderRadius: BorderRadius.circular(NlRadius.r2),
                border: Border.all(color: const Color(0x0DFFFFFF))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              NlMonoLabel(label),
              const SizedBox(height: 2),
              Text(value,
                  maxLines: 1,
                  style: NlType.monoText(NlType.s6,
                      weight: FontWeight.w500, color: nl.fg)),
            ])));
    Widget row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: Text(label, style: NlType.text(NlType.s2, color: nl.fg2))),
          const SizedBox(width: NlSpace.s2),
          Flexible(
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: NlType.monoText(NlType.s2, color: nl.fg))),
        ]));
    Widget section(String label) => Padding(
        padding: const EdgeInsets.only(top: NlSpace.s3, bottom: NlSpace.s1),
        child: NlMonoLabel(label));
    return Container(
      key: const Key('nikodesk-telemetry-hud'),
      constraints: BoxConstraints(
          maxWidth: 320, maxHeight: MediaQuery.sizeOf(context).height * .8),
      decoration: BoxDecoration(
          color: NlDock.background,
          borderRadius: BorderRadius.circular(NlRadius.r3),
          border: Border.all(color: NlDock.line),
          boxShadow: nl.shadow3),
      padding: const EdgeInsets.all(NlSpace.s3),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: nl.fg, decoration: TextDecoration.none),
        child: SingleChildScrollView(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              const NlMonoLabel('Telemetry'),
              const Spacer(),
              Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: NlSpace.s2, vertical: 2),
                  decoration: BoxDecoration(
                      color: widget.metrics.direct == true
                          ? nl.accentSoft
                          : const Color(0x14FFFFFF),
                      borderRadius: BorderRadius.circular(NlRadius.r1)),
                  child: Text(_route(),
                      style: NlType.monoText(NlType.s1,
                          color: widget.metrics.direct == true
                              ? nl.accentText
                              : nl.fg2))),
            ]),
            const SizedBox(height: NlSpace.s2),
            Row(children: [
              figure('FPS', fps == null ? '—' : fps.round().toString()),
              const SizedBox(width: NlSpace.s2),
              figure('RTT (ms)', rtt == null ? '—' : rtt.round().toString()),
              const SizedBox(width: NlSpace.s2),
              figure('Mbit/s',
                  kib == null ? '—' : (kib * 8192 / 1e6).toStringAsFixed(1)),
            ]),
            section(nikoText('画面流', 'Stream')),
            for (final line in _streamRows)
              row(line.$1, _value(line.$2, line.$3)),
            section(nikoText('建立', 'Setup')),
            row(nikoText('连接路径', 'Route'), _route()),
            row(nikoText('建立连接', 'Connection setup'),
                _duration(setup?.transport)),
            row(nikoText('认证', 'Authentication'), _authentication(setup)),
            row(nikoText('首帧', 'First frame'), _duration(setup?.firstFrame)),
            section(nikoText('被控端', 'Remote')),
            row(nikoText('被控端画面', 'Remote picture'),
                _unknownOr(host == null ? null : _hostPicture(host))),
            row(
                nikoText('被控端新画面', 'Remote new pictures'),
                _unknownOr(host?.fps == null
                    ? null
                    : '${host!.fps!.toStringAsFixed(1)}/s')),
            row(
                nikoText('被控显示器', 'Remote display'),
                _unknownOr(host?.refreshHz == null
                    ? null
                    : '${host!.refreshHz!.round()} Hz')),
            row(nikoText('被控端每帧', 'Remote per picture'),
                _unknownOr(host == null ? null : _hostStages(host))),
            row(nikoText('帧率上限', 'Frame-rate ceiling'),
                _unknownOr(_frameCap(host))),
          ],
        )),
      ),
    );
  }

  List<(String, String, String)> get _streamRows => [
        (nikoText('接收吞吐', 'Receive rate'), 'receiveKiBps', 'KiB/s'),
        (nikoText('解码回调帧率', 'Decoded callback FPS'), 'decodedCallbackFps', 'fps'),
        (nikoText('应用往返', 'Application RTT'), 'applicationRttMs', 'ms'),
        (nikoText('目标码率', 'Target bitrate'), 'targetBitrateKbps', 'kbps'),
        (nikoText('接收编码', 'Received codec'), 'receivedCodec', ''),
        (nikoText('解码色度', 'Decoded chroma'), 'decodedChroma', ''),
        (nikoText('解码实现', 'Decoder backend'), 'decoderBackend', ''),
        (nikoText('硬解实例', 'Hardware decoder'), 'hardwareDecoder', ''),
        (nikoText('解码与转换调用', 'Decode + convert call'), 'decodeConvertMeanMs', 'ms'),
        (nikoText('原生提交调用', 'Native submit call'), 'nativeSubmitMeanMs', 'ms'),
        (nikoText('非关键帧队列峰值', 'Delta queue peak'), 'deltaQueuePeak', ''),
        (nikoText('队列溢出次数', 'Delta overflows'), 'deltaOverflow', ''),
        (nikoText('显示路径跳过次数', 'Render path skips'), 'renderSkips', ''),
      ];
}
