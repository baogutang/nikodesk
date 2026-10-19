import 'dart:async';

import 'package:flutter/material.dart';

import 'connection_progress.dart';
import 'metrics.dart';
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
          .join(' · ');
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
    return metrics.transport == null ? route : '$route · ${metrics.transport}';
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
    final codec = host.encoder.isEmpty ? '' : ' · ${host.encoder} $kind';
    return '${host.width}×${host.height}$codec';
  }

  String _hostStages(NikoHostVideo host) {
    String ms(double? v) => v == null ? '?' : v.toStringAsFixed(1);
    final capture = host.captureIncludesWait
        ? nikoText('采集(含等待)', 'capture (incl. wait)')
        : nikoText('采集', 'capture');
    return '$capture ${ms(host.captureMs)} · ${nikoText('转换', 'convert')} '
        '${ms(host.convertMs)} · ${nikoText('编码', 'encode')} ${ms(host.encodeMs)} ms';
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
}
