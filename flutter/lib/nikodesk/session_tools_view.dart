import 'package:flutter/material.dart';

import 'metrics.dart';
import 'nightline.dart';
import 'policy.dart' show PictureMode, nikoMaxFps;
import 'settings_kit.dart';
import 'ui.dart';

String _modeLabel(PictureMode mode) => switch (mode) {
      PictureMode.office => nikoText('办公清晰', 'Office clarity'),
      PictureMode.smooth => nikoText('操作流畅', 'Responsive control'),
      PictureMode.constrained => nikoText('弱网稳定', 'Constrained network'),
      PictureMode.custom => nikoText('自定义', 'Custom'),
    };

String _modeDetail(PictureMode mode, int smoothFps) => switch (mode) {
      PictureMode.office => nikoText('上游 best 画质 + 原始 1:1 缩放；编码器自动协商。',
          'Upstream best quality + original 1:1 view; automatic codec negotiation.'),
      PictureMode.smooth => nikoText(
          '帧率上限跟随本机屏幕刷新率（此处为 $smoothFps，范围 60–$nikoMaxFps）、50% 码率比例（需要对端支持）；实际帧率不超过对端屏幕的刷新率，对端仍按网络延迟自行下调。保留当前缩放。',
          'Frame limit follows this screen\'s refresh rate ($smoothFps here, 60–$nikoMaxFps) at a 50% bitrate ratio when supported. The peer sends no more than its own screen refreshes and still lowers both when the network is slow. Keeps the current view scale.'),
      PictureMode.constrained => nikoText(
          '保守请求：30% 码率比例、15 FPS（需要对端支持）。沿用上游 QoS；弱网改善尚未测量。',
          'Conservative request: 30% bitrate ratio and 15 FPS when supported. Uses upstream QoS; weak-network improvement is unmeasured.'),
      PictureMode.custom => nikoText('设置码率比例与目标 FPS；这些值不代表实测码率或呈现帧率。',
          'Set bitrate ratio and target FPS; these are not measured bitrate or presentation FPS.'),
    };

/// Local wall-clock time of a sample, with the date when it may be from
/// another day.
String _clock(DateTime time, {bool date = false}) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final clock = '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  return date
      ? '${local.year}-${two(local.month)}-${two(local.day)} $clock'
      : clock;
}

/// A panel over a session, such as a tool or the voice call: the title row
/// and [footer] stay in place while the line on what it covers scrolls with
/// [body], so neither end outgrows a small window at large text sizes. The
/// scrolling part fades out where more of it is hidden.
class NikoToolFrame extends StatefulWidget {
  final String title;
  final String detail;
  final Widget body;
  final List<Widget> footer;

  /// Shown as a close button when no footer button closes the panel.
  final VoidCallback? onClose;
  final Key? closeKey;
  const NikoToolFrame(
      {super.key,
      required this.title,
      required this.detail,
      this.body = const SizedBox.shrink(),
      this.footer = const [],
      this.onClose,
      this.closeKey});

  @override
  State<NikoToolFrame> createState() => _NikoToolFrameState();
}

class _NikoToolFrameState extends State<NikoToolFrame> {
  var _before = false;
  var _after = false;

  bool _measure(ScrollMetrics metrics) {
    final before = metrics.extentBefore > .5;
    final after = metrics.extentAfter > .5;
    if (before != _before || after != _after) {
      // Metrics arrive during layout; repaint the fade after it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _before = before;
            _after = after;
          });
        }
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    const fade = 24.0;
    final nl = NlColors.of(context);
    final title = widget.title, onClose = widget.onClose;
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
                child: Semantics(
                    header: true,
                    child: Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: NlType.text(NlType.s5,
                            weight: FontWeight.w600, color: nl.fg)))),
            if (onClose != null)
              NlIconButton(
                  key: widget.closeKey,
                  icon: NlIcons.close,
                  tooltip: nikoText('关闭', 'Close'),
                  onPressed: onClose),
          ]),
          Flexible(
              // Always in the tree, so the scroll position survives the
              // fade coming and going.
              child: ShaderMask(
                  key: const Key('nikodesk-tool-fade'),
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) => LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            _before ? Colors.transparent : Colors.white,
                            Colors.white,
                            Colors.white,
                            _after ? Colors.transparent : Colors.white,
                          ],
                          stops: bounds.height > 3 * fade
                              ? [
                                  0,
                                  fade / bounds.height,
                                  1 - fade / bounds.height,
                                  1
                                ]
                              : const [0, .3, .7, 1])
                      .createShader(bounds),
                  child: NotificationListener<ScrollMetricsNotification>(
                      onNotification: (n) => _measure(n.metrics),
                      child: NotificationListener<ScrollNotification>(
                          onNotification: (n) => _measure(n.metrics),
                          child: SingleChildScrollView(
                              padding: const EdgeInsets.only(top: 2),
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(widget.detail,
                                        style: NlType.text(NlType.s2,
                                            color: nl.fg2)),
                                    const SizedBox(height: NlSpace.s4),
                                    widget.body,
                                  ])))))),
          ...widget.footer,
        ]);
  }
}

/// What a session tool panel shows once its session has ended.
class NikoSessionToolEnded extends StatelessWidget {
  final String title;
  final VoidCallback onClose;
  const NikoSessionToolEnded(
      {super.key, required this.title, required this.onClose});

  @override
  Widget build(BuildContext context) => NikoToolFrame(
      title: title,
      detail:
          nikoText('此会话已结束，请关闭面板。', 'This session has ended. Close the panel.'),
      onClose: onClose);
}

/// The picture modes a session can ask the remote for, and the bitrate
/// ratio and frame rate of the custom one. What it sets is a request; the
/// diagnostics show what arrives.
class NikoPictureModePanel extends StatelessWidget {
  final bool loading;
  final bool saving;
  final PictureMode mode;
  final ValueChanged<PictureMode> onMode;

  /// The frame limit the responsive mode asks for on this screen.
  final int smoothFps;
  final double quality;
  final ValueChanged<double> onQuality;
  final double fps;
  final ValueChanged<double> onFps;
  final bool supportsFps;

  /// The quality setting the session core reports now, and its frame rate.
  final String? currentQuality;
  final String? currentFps;
  final String? message;
  final NlTone messageTone;
  final VoidCallback onApply;
  final VoidCallback onClose;

  const NikoPictureModePanel(
      {super.key,
      required this.loading,
      this.saving = false,
      required this.mode,
      required this.onMode,
      required this.smoothFps,
      required this.quality,
      required this.onQuality,
      required this.fps,
      required this.onFps,
      required this.supportsFps,
      this.currentQuality,
      this.currentFps,
      this.message,
      this.messageTone = NlTone.accent,
      required this.onApply,
      required this.onClose});

  Widget _slider(BuildContext context,
      {required String title, required String value, required Widget slider}) {
    final nl = NlColors.of(context);
    return Padding(
        padding: const EdgeInsets.only(top: NlSpace.s3),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
                child: Text(title,
                    style: NlType.text(
                        NlLayout.touch(context) ? NlType.s4 : NlType.s3,
                        weight: FontWeight.w500,
                        color: nl.fg))),
            Text(value, style: NlType.monoText(NlType.s3, color: nl.fg)),
          ]),
          SliderTheme(
              data: SliderTheme.of(context).copyWith(
                  trackShape: const _FlushTrack(),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 16)),
              child: slider),
        ]));
  }

  Widget _custom(BuildContext context) {
    final nl = NlColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _slider(context,
          title: nikoText('码率比例', 'Bitrate ratio'),
          value: '${quality.round()}%',
          slider: Slider(
              key: const Key('nikodesk-picture-quality'),
              value: quality,
              min: 10,
              max: 100,
              divisions: 90,
              label: '${quality.round()}%',
              onChanged: saving ? null : onQuality)),
      _slider(context,
          title: nikoText('目标 FPS', 'Target FPS'),
          value: '${fps.round()}',
          slider: Slider(
              key: const Key('nikodesk-picture-fps'),
              value: fps,
              min: 5,
              max: nikoMaxFps.toDouble(),
              divisions: nikoMaxFps - 5,
              label: '${fps.round()}',
              onChanged: saving || !supportsFps ? null : onFps)),
      Text(
          nikoText('实际帧率不会超过对端屏幕的刷新率，也不会超过本机能显示的帧率。',
              'The peer sends no more frames than its own screen refreshes, and this screen shows no more than its own rate.'),
          style: NlType.text(NlType.s2, color: nl.fg3)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final unknown = nikoText('未知', 'Unknown');
    final current = currentQuality == 'custom'
        ? '${currentQuality ?? unknown} · ${currentFps ?? unknown} FPS'
        : currentQuality ?? unknown;
    return NikoToolFrame(
        title: nikoText('画面模式', 'Picture mode'),
        detail: nikoText('编码器自动协商；不强制硬编、H.264 或 4:4:4。',
            'Codec is negotiated automatically. Hardware encoding, H.264 and 4:4:4 are not forced.'),
        body: loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: NlSpace.s8),
                child: Center(child: NlSpinner(size: 20)))
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final item in PictureMode.values) ...[
                  if (item != PictureMode.values.first)
                    const SizedBox(height: NlSpace.s2),
                  _ModeOption(
                      mode: item,
                      selected: item == mode,
                      label: _modeLabel(item),
                      detail: _modeDetail(item, smoothFps),
                      onTap: saving ? null : () => onMode(item)),
                ],
                AnimatedSize(
                    duration: NlMotion.of(context, NlMotion.base),
                    curve: NlMotion.ease,
                    alignment: Alignment.topCenter,
                    child: mode == PictureMode.custom
                        ? Padding(
                            padding: const EdgeInsets.only(top: NlSpace.s2),
                            child: _custom(context))
                        : const SizedBox(width: double.infinity)),
                if (!supportsFps)
                  Padding(
                      padding: const EdgeInsets.only(top: NlSpace.s4),
                      child: NikoSettingNote(
                          nikoText('对端版本未知或低于 1.2.0：不会发送自定义 FPS。',
                              'Peer version is unknown or older than 1.2.0: custom FPS will not be sent.'),
                          tone: NlTone.warn)),
                const SizedBox(height: NlSpace.s4),
                Wrap(spacing: NlSpace.s2, children: [
                  Text(nikoText('当前核心画质设置', 'Current core quality setting'),
                      style: NlType.text(NlType.s2, color: nl.fg3)),
                  Text(current,
                      key: const Key('nikodesk-picture-current'),
                      style: NlType.monoText(NlType.s2, color: nl.fg2)),
                ]),
              ]),
        footer: [
          if (message != null)
            Padding(
                padding: const EdgeInsets.only(top: NlSpace.s4),
                child: Semantics(
                    liveRegion: true,
                    child: NikoSettingNote(message!, tone: messageTone))),
          const SizedBox(height: NlSpace.s5),
          Wrap(
              alignment: WrapAlignment.end,
              spacing: NlSpace.s2,
              runSpacing: NlSpace.s2,
              children: [
                NlButton.ghost(
                    key: const Key('nikodesk-picture-close'),
                    label: nikoText('关闭', 'Close'),
                    onPressed: saving ? null : onClose),
                NlButton(
                    key: const Key('nikodesk-picture-apply'),
                    label: nikoText('应用并保存', 'Apply and save'),
                    loading: saving,
                    onPressed: loading || saving ? null : onApply),
              ]),
        ]);
  }
}

/// A slider track that ends at the thumb's edge rather than its halo's, so
/// the slider lines up with the text above it.
class _FlushTrack extends RoundedRectSliderTrackShape {
  const _FlushTrack();

  @override
  Rect getPreferredRect(
      {required RenderBox parentBox,
      Offset offset = Offset.zero,
      required SliderThemeData sliderTheme,
      bool isEnabled = false,
      bool isDiscrete = false}) {
    final thumb =
        sliderTheme.thumbShape?.getPreferredSize(isEnabled, isDiscrete).width ??
            20;
    final height = sliderTheme.trackHeight ?? 4;
    final width = parentBox.size.width - thumb;
    return Rect.fromLTWH(
        offset.dx + thumb / 2,
        offset.dy + (parentBox.size.height - height) / 2,
        width < 0 ? 0 : width,
        height);
  }
}

/// One picture mode as a card to pick: its icon, name and what it asks
/// for, with a check when picked.
class _ModeOption extends StatelessWidget {
  final PictureMode mode;
  final bool selected;
  final String label;
  final String detail;
  final VoidCallback? onTap;
  const _ModeOption(
      {required this.mode,
      required this.selected,
      required this.label,
      required this.detail,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final duration = NlMotion.of(context, NlMotion.fast);
    final icon = switch (mode) {
      PictureMode.office => NlIcons.type,
      PictureMode.smooth => NlIcons.zap,
      PictureMode.constrained => NlIcons.signal,
      PictureMode.custom => NlIcons.slidersHorizontal,
    };
    return MergeSemantics(
        child: NlPressable(
            key: ValueKey('nikodesk-picture-${mode.name}'),
            selected: selected,
            pressScale: .99,
            onTap: onTap,
            builder: (context, states) {
              final hovered = states.contains(WidgetState.hovered);
              return AnimatedContainer(
                  duration: duration,
                  curve: NlMotion.ease,
                  padding: const EdgeInsets.all(NlSpace.s3),
                  decoration: BoxDecoration(
                      color: selected
                          ? nl.accentSoft
                          : hovered
                              ? nl.hover
                              : Colors.transparent,
                      borderRadius: BorderRadius.circular(NlRadius.r3),
                      border: Border.all(
                          color: selected
                              ? nl.accent
                              : hovered
                                  ? nl.line2
                                  : nl.line),
                      boxShadow: states.contains(WidgetState.focused)
                          ? nl.focusRing
                          : null),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnimatedContainer(
                            duration: duration,
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                                color: selected
                                    ? nl.accent.withOpacity(.18)
                                    : nl.surface2,
                                borderRadius:
                                    BorderRadius.circular(NlRadius.r2)),
                            child: Icon(icon,
                                size: 16,
                                color: selected ? nl.accentText : nl.fg2)),
                        const SizedBox(width: NlSpace.s3),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(label,
                                  style: NlType.text(NlType.s3,
                                      weight: FontWeight.w600, color: nl.fg)),
                              const SizedBox(height: 2),
                              Text(detail,
                                  style: NlType.text(NlType.s2, color: nl.fg2)),
                            ])),
                        const SizedBox(width: NlSpace.s3),
                        Padding(
                            padding: const EdgeInsets.only(top: 7),
                            child: AnimatedContainer(
                                duration: duration,
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: selected
                                        ? nl.accentFill
                                        : Colors.transparent,
                                    border: Border.all(
                                        color:
                                            selected ? nl.accentFill : nl.line2,
                                        width: 1.5)),
                                child: selected
                                    ? Icon(NlIcons.check,
                                        size: 12, color: nl.onAccent)
                                    : null)),
                      ]));
            }));
  }
}

String _metricName(String name) => switch (name) {
      'receiveKiBps' => nikoText('接收速率', 'Receive throughput'),
      'decodedCallbackFps' => nikoText('解码回调帧率', 'Decoded callback FPS'),
      'applicationRttMs' => nikoText('应用层往返', 'Application round trip'),
      'targetBitrateKbps' => nikoText('目标码率快照', 'Target bitrate snapshot'),
      'receivedCodec' => nikoText('实际收到的编码格式', 'Received codec'),
      'decodedChroma' => nikoText('解码色度格式', 'Decoded chroma'),
      'decoderBackend' => nikoText('解码实例', 'Decoder backend'),
      'hardwareDecoder' => nikoText('硬件解码实例', 'Hardware decoder'),
      'decodeConvertMeanMs' =>
        nikoText('解码与转换调用均值', 'Mean decode + convert call'),
      'nativeSubmitMeanMs' => nikoText('原生提交调用均值', 'Mean native submit call'),
      'deltaQueuePeak' => nikoText('非关键帧队列峰值', 'Delta queue peak'),
      'deltaOverflow' => nikoText('非关键帧队列溢出次数', 'Delta queue overflows'),
      'renderSkips' => nikoText('显示路径跳过次数', 'Render path skips'),
      'hostVideo' => nikoText('被控端画面', 'Controlled side picture'),
      _ => name,
    };

String _metricLimit(String name) {
  if (NikoLanguage.english) return SessionMetrics.specs[name]!.limitation;
  return switch (name) {
    'receiveKiBps' => '约 1 秒窗口，包含全部接收消息，不等同于视频码率。上游 kB/s 实际按 1024 计算。',
    'decodedCallbackFps' => '每台显示器进入解码回调的帧率，不能证明渲染器接收或屏幕实际呈现；静态桌面低帧率不自动表示卡顿。',
    'applicationRttMs' => '应用探测往返时间，不是网络 Ping、单向延迟或输入到画面延迟。',
    'targetBitrateKbps' => '编码器目标值快照，不是实测吞吐。',
    'receivedCodec' => '真实接收编码格式；不能据此判断硬件编码或解码。',
    'decodedChroma' => '真实解码色度格式；4:4:4 不等于无损。',
    'decoderBackend' => '按显示器记录实际成功输出帧的解码实例；格式或偏好设置不是实现证明，未收到真实输出时为未知。',
    'hardwareDecoder' => '来自实际输出帧的解码实例；平台未报告时为未知，不能据此判断被控端是否硬件编码。',
    'decodeConvertMeanMs' => '最多每秒 8 次的解码与转换调用耗时采样，包含失败调用；不等于纯解码、采集、呈现或端到端延迟。',
    'nativeSubmitMeanMs' => '原生提交函数的调用耗时采样；该接口没有接收或呈现确认，不能证明屏幕已显示。',
    'deltaQueuePeak' => '当前采样窗口内非关键帧队列的观测峰值；不包含关键帧或整个视频管线。',
    'deltaOverflow' => '当前采样窗口内非关键帧队列的实际溢出计数；不等于网络丢包或全部丢帧。',
    'renderSkips' => '显示路径中被明确记录的跳过次数；详细原因随脱敏诊断导出，不等于全部丢帧。',
    'hostVideo' => '被控端自己测得的每帧均值，约每秒一次；标注“含等待”时采集时间包含等待新画面；系统未报告刷新率时为未知。',
    _ => SessionMetrics.specs[name]?.limitation ?? '',
  };
}

String _metricUnit(String name) => switch (name) {
      'decodedCallbackFps' => 'fps',
      'decodeConvertMeanMs' || 'nativeSubmitMeanMs' => 'ms',
      'deltaQueuePeak' => nikoText('项', 'entries'),
      'deltaOverflow' ||
      'renderSkips' =>
        nikoText('次 / 采样窗口', 'events / window'),
      'receivedCodec' ||
      'decodedChroma' ||
      'decoderBackend' ||
      'hardwareDecoder' ||
      'hostVideo' =>
        '',
      _ => SessionMetrics.specs[name]?.unit ?? '',
    };

String _formatValue(Object? value) {
  if (value == null) return nikoText('未知', 'Unknown');
  if (value is bool) return value ? nikoText('是', 'Yes') : nikoText('否', 'No');
  if (value is num) {
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toStringAsFixed(2);
  }
  if (value is NikoHostVideo) {
    String ms(double? v) => v == null ? '?' : v.toStringAsFixed(1);
    final kind = value.hardware
        ? nikoText('硬件', 'hardware')
        : nikoText('软件', 'software');
    final capture = value.captureIncludesWait
        ? nikoText('采集(含等待)', 'capture (incl. wait)')
        : nikoText('采集', 'capture');
    return [
      '${value.width}×${value.height}',
      if (value.encoder.isNotEmpty) '${value.encoder} $kind',
      if (value.fps != null) '${value.fps!.round()}/s',
      '$capture ${ms(value.captureMs)} · ${nikoText('转换', 'convert')} '
          '${ms(value.convertMs)} · ${nikoText('编码', 'encode')} '
          '${ms(value.encodeMs)} ms',
    ].join(' · ');
  }
  return value.toString();
}

String _metricValue(SessionMetrics metrics, String name) {
  final value = metrics.current(name);
  if (value == null) {
    return metrics.isStale(name)
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

/// What the session measures, each value with its source and what it does
/// not show, and what stays unknown; an export saves it redacted.
class NikoDiagnosticsPanel extends StatelessWidget {
  final SessionMetrics metrics;

  /// Null while the sampling setting could not be read.
  final bool? sampling;
  final bool samplingBusy;
  final ValueChanged<bool> onSampling;
  final VoidCallback onReloadSampling;

  /// Width and height of each display as the remote reported them.
  final List<(int, int)> resolutions;
  final double scale;
  final String? feedback;
  final NlTone feedbackTone;
  final bool exporting;
  final VoidCallback onExport;
  final VoidCallback onClose;

  const NikoDiagnosticsPanel(
      {super.key,
      required this.metrics,
      required this.sampling,
      this.samplingBusy = false,
      required this.onSampling,
      required this.onReloadSampling,
      required this.resolutions,
      required this.scale,
      this.feedback,
      this.feedbackTone = NlTone.accent,
      this.exporting = false,
      required this.onExport,
      required this.onClose});

  Widget _fact(String title, String value, {bool mono = false}) =>
      NikoSettingRow(
          title: title, trailing: NikoSettingValue(value, mono: mono));

  @override
  Widget build(BuildContext context) {
    final unknown = nikoText('未知', 'Unknown');
    final connection = metrics.connectionSampledAt;
    final known = connection != null;
    String state(bool? value, String yes, String no) =>
        value == null ? unknown : (value ? yes : no);
    return NikoToolFrame(
        title: nikoText('会话诊断', 'Session diagnostics'),
        detail: nikoText('每秒刷新 · 10 秒无新样本后标记失效 · 脱敏报告仅在导出时保存',
            'Updates once per second · Samples expire after 10 seconds · Redacted reports are saved only on export'),
        onClose: onClose,
        closeKey: const Key('nikodesk-diagnostics-close'),
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          NikoSettingsGroup(bottom: NlSpace.s5, children: [
            NikoSettingRow(
                title: nikoText('性能采样', 'Performance sampling'),
                description: nikoText('与会话性能浮窗同步；开启后才会记录原生视频处理样本。',
                    'Shares the session performance overlay setting. Native video samples are recorded while enabled.'),
                busy: samplingBusy,
                trailing: NlSwitch(
                    key: const Key('nikodesk-diagnostics-sampling'),
                    value: sampling ?? false,
                    semanticLabel: nikoText('性能采样', 'Performance sampling'),
                    onChanged:
                        sampling == null || samplingBusy ? null : onSampling),
                below: sampling == null
                    ? NikoSettingNote(
                        nikoText('采样状态未知。', 'Sampling state unknown.'),
                        tone: NlTone.warn,
                        actionLabel: nikoText('重新读取', 'Reload'),
                        onAction: onReloadSampling)
                    : null),
          ]),
          NikoSettingsGroup(
              title: nikoText('连接', 'Connection'),
              description: nikoText(
                  '服务器注册、会话认证与加密是不同状态。中继目标来自本次连接固定的路由，非解析后的 IP；导出时隐藏地址。',
                  'Server registration, session authentication and encryption are separate states. The relay target comes from this connection’s captured route, not its resolved IP. Exports hide the address.'),
              bottom: NlSpace.s5,
              children: [
                _fact(
                    nikoText('连接路径', 'Connection path'),
                    known
                        ? '${metrics.direct == true ? nikoText('直连', 'Direct') : nikoText('中继', 'Relay')} · ${metrics.transport ?? unknown}'
                        : unknown),
                _fact(
                    nikoText('会话加密', 'Session encryption'),
                    known
                        ? state(
                            metrics.secure == true,
                            nikoText('核心报告已加密', 'Encrypted per core event'),
                            nikoText('核心报告未加密', 'Unencrypted per core event'))
                        : unknown),
                if (metrics.direct != true)
                  _fact(nikoText('中继目标', 'Relay target'),
                      metrics.relayTarget ?? unknown,
                      mono: true),
                _fact(
                    nikoText('代理路径', 'Proxy path'),
                    state(
                        metrics.proxyInUse,
                        nikoText('已使用本次连接的代理',
                            'Uses this connection’s captured proxy'),
                        nikoText('未使用代理', 'No proxy used'))),
                if (metrics.transport == 'WebSocket')
                  _fact(
                      'WebSocket TLS',
                      state(metrics.websocketTls, nikoText('已启用', 'Enabled'),
                          nikoText('未启用', 'Disabled'))),
                _fact(
                    metrics.connectionFromCache
                        ? nikoText('会话缓存接收时间（非新握手）',
                            'Session cache received (not a new handshake)')
                        : nikoText('握手采样时间', 'Handshake sampled at'),
                    connection == null
                        ? unknown
                        : _clock(connection, date: true),
                    mono: true),
              ]),
          NikoSettingsGroup(
              title: nikoText('画面', 'Picture'),
              bottom: NlSpace.s5,
              children: [
                _fact(
                    nikoText('源分辨率', 'Source resolution'),
                    resolutions.isEmpty
                        ? unknown
                        : resolutions
                            .map((r) => '${r.$1} × ${r.$2}')
                            .join(' · '),
                    mono: true),
                _fact(nikoText('当前画布缩放', 'Current canvas scale'),
                    '${scale.toStringAsFixed(2)}×',
                    mono: true),
              ]),
          NikoSettingsGroup(
              title: nikoText('测量值', 'Measurements'),
              bottom: NlSpace.s4,
              children: [
                for (final name in SessionMetrics.specs.keys)
                  if (name != 'nativeVideo')
                    _MetricRow(metrics: metrics, name: name),
              ]),
          NikoSettingNote(nikoText(
              '未知：硬件编码与回退原因、采集 / 编码 / 纯解码 / 屏幕呈现耗时、输入到画面延迟和全部丢帧。原生统计须开启性能面板且绑定当前连接后才有样本；未进行性能 A/B 验证。',
              'Unknown: hardware encoding and fallback reasons; capture/encode/pure-decode/presentation timing; input-to-photon latency and total dropped frames. Native samples require the performance panel and a verified current connection. No performance A/B verification has been performed.')),
        ]),
        footer: [
          if (feedback != null)
            Padding(
                padding: const EdgeInsets.only(top: NlSpace.s4),
                child: Semantics(
                    liveRegion: true,
                    child: NikoSettingNote(feedback!, tone: feedbackTone))),
          const SizedBox(height: NlSpace.s4),
          Align(
              alignment: AlignmentDirectional.centerEnd,
              child: NlButton.ghost(
                  key: const Key('nikodesk-diagnostics-export'),
                  icon: NlIcons.download,
                  label: nikoText('导出脱敏诊断', 'Export redacted diagnostics'),
                  loading: exporting,
                  onPressed: exporting ? null : onExport)),
        ]);
  }
}

/// One measurement: its name and current value, what it does not show,
/// and when and where it was sampled.
class _MetricRow extends StatelessWidget {
  final SessionMetrics metrics;
  final String name;
  const _MetricRow({required this.metrics, required this.name});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    final current = metrics.current(name);
    final unit = _metricUnit(name);
    final value = _metricValue(metrics, name);
    final sampled = metrics.sample(name)?.sampledAt;
    return Padding(
        padding:
            EdgeInsets.symmetric(vertical: touch ? NlSpace.s4 : NlSpace.s3),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: NlSpace.s3,
              runSpacing: 2,
              children: [
                Text(_metricName(name),
                    style: NlType.text(touch ? NlType.s4 : NlType.s3,
                        weight: FontWeight.w500, color: nl.fg)),
                Text(current == null || unit.isEmpty ? value : '$value $unit',
                    style: NlType.monoText(NlType.s3,
                        color: current != null
                            ? nl.fg
                            : metrics.isStale(name)
                                ? nl.warnText
                                : nl.fg3)),
              ]),
          const SizedBox(height: 2),
          Text(_metricLimit(name),
              style: NlType.text(NlType.s2, color: nl.fg2)),
          const SizedBox(height: 2),
          Text(
              '${nikoText('采样', 'Sampled')} ${sampled == null ? nikoText('未知', 'Unknown') : _clock(sampled)} · ${SessionMetrics.specs[name]?.source ?? ''}',
              style: NlType.monoText(NlType.s1, color: nl.fg3)),
        ]));
  }
}
