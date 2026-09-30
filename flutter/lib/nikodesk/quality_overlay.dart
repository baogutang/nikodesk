import 'dart:async';

import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                        child: Text(row.$1,
                            style: Theme.of(context).textTheme.labelMedium)),
                    const SizedBox(width: 8),
                    Flexible(
                        child: Text(_value(row.$2, row.$3),
                            textAlign: TextAlign.end,
                            style: Theme.of(context).textTheme.labelMedium)),
                  ],
                ),
              ),
          ],
        )),
      ),
    );
  }
}
