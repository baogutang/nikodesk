import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart'
    show TRadioMenu, TToggleMenu;
import 'package:flutter_hbb/consts.dart';

import 'nightline.dart';
import 'settings_kit.dart';
import 'ui.dart';

/// The phone and iPad session's display options: the stock sheet's menus
/// laid out as settings groups. Every control calls the stock handler, and
/// the panel remembers what it set, as the stock sheet does.
class NikoDisplayOptionsPanel extends StatefulWidget {
  /// How the session is connected, e.g. "Relayed and encrypted connection".
  final String? connection;
  final bool secure;

  /// Displays to switch between; fewer than two hides the switcher.
  final int displays;
  final int currentDisplay;
  final ValueChanged<int>? onDisplay;

  final List<TRadioMenu<String>> viewStyles;

  /// Builds the custom scale control shown while the custom scale is on.
  final WidgetBuilder? customScale;
  final List<TRadioMenu<String>> qualities;
  final List<TRadioMenu<String>> codecs;
  final String? codecInUse;
  final VoidCallback? onPictureMode;

  /// The remote display's size, shown beside the resolution choice.
  final String? resolution;
  final VoidCallback? onResolution;
  final VoidCallback? onVirtualDisplay;

  final List<TToggleMenu> cursors;
  final List<TToggleMenu> toggles;
  final VoidCallback? onDiagnostics;
  final VoidCallback onClose;

  const NikoDisplayOptionsPanel(
      {super.key,
      this.connection,
      this.secure = true,
      this.displays = 0,
      this.currentDisplay = 0,
      this.onDisplay,
      this.viewStyles = const [],
      this.customScale,
      this.qualities = const [],
      this.codecs = const [],
      this.codecInUse,
      this.onPictureMode,
      this.resolution,
      this.onResolution,
      this.onVirtualDisplay,
      this.cursors = const [],
      this.toggles = const [],
      this.onDiagnostics,
      required this.onClose});

  @override
  State<NikoDisplayOptionsPanel> createState() =>
      _NikoDisplayOptionsPanelState();
}

String _label(Widget child) =>
    child is Text ? child.data ?? child.textSpan?.toPlainText() ?? '' : '';

class _NikoDisplayOptionsPanelState extends State<NikoDisplayOptionsPanel> {
  late String? _viewStyle = widget.viewStyles.firstOrNull?.groupValue;
  late String? _quality = widget.qualities.firstOrNull?.groupValue;
  late String? _codec = widget.codecs.firstOrNull?.groupValue;
  late final _cursors = [for (final e in widget.cursors) e.value];
  late final _toggles = [for (final e in widget.toggles) e.value];

  /// Calls the stock handler of the choice [value] and reports whether it
  /// took it; a choice without a handler is unavailable.
  bool _pick(List<TRadioMenu<String>> menus, String value) {
    final menu = menus.where((e) => e.value == value).firstOrNull;
    if (menu?.onChanged == null) return false;
    menu!.onChanged!(value);
    return true;
  }

  /// A setting choosing one of [menus]. A short set sits beside the title;
  /// a longer one spans the row under the text, which on a narrow panel
  /// starts past three choices.
  Widget _choiceRow(
      {required bool wide,
      required String key,
      required String title,
      String? description,
      required List<TRadioMenu<String>> menus,
      required String? selected,
      required String Function(TRadioMenu<String>) label,
      required ValueChanged<String> pick,
      List<String> order = const [],
      Widget? extra}) {
    int rank(String value) {
      final i = order.indexOf(value);
      return i < 0 ? order.length : i;
    }

    final sorted = [...menus]
      ..sort((a, b) => rank(a.value).compareTo(rank(b.value)));
    final under = menus.length > (wide ? 4 : 3);
    final control = NlSegmented<String?>(
        key: Key(key),
        expand: under,
        selected: selected,
        segments: [
          for (final e in sorted)
            NlSegment(
                key: ValueKey('$key-${e.value}'),
                value: e.value,
                label: label(e)),
        ],
        onChanged: (value) {
          if (value != null) pick(value);
        });
    return NikoSettingRow(
        title: title,
        description: description,
        trailing: under ? null : control,
        below: under && extra != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [control, const SizedBox(height: NlSpace.s2), extra])
            : under
                ? control
                : extra);
  }

  List<Widget> _switches(
          String key, List<TToggleMenu> menus, List<bool> values) =>
      [
        for (var i = 0; i < menus.length; i++)
          NikoSettingRow(
              title: _label(menus[i].child),
              trailing: NlSwitch(
                  key: Key('$key-$i'),
                  value: values[i],
                  semanticLabel: _label(menus[i].child),
                  onChanged: menus[i].onChanged == null
                      ? null
                      : (value) {
                          menus[i].onChanged!(value);
                          setState(() => values[i] = value);
                        })),
      ];

  List<Widget> _picture(bool wide) => [
        if (widget.displays > 1)
          NikoSettingRow(
              title: nikoText('显示器', 'Display'),
              description: nikoText('远端有 ${widget.displays} 块显示器。',
                  'The remote has ${widget.displays} displays.'),
              trailing: NlSegmented<int>(
                  key: const Key('nikodesk-displays'),
                  selected: widget.currentDisplay,
                  segments: [
                    for (var i = 0; i < widget.displays; i++)
                      NlSegment(
                          key: ValueKey('nikodesk-display-$i'),
                          value: i,
                          icon: NlIcons.monitor,
                          label: '${i + 1}'),
                  ],
                  onChanged: widget.onDisplay == null
                      ? null
                      : (i) {
                          if (i != widget.currentDisplay) widget.onDisplay!(i);
                        })),
        if (widget.viewStyles.isNotEmpty)
          _choiceRow(
              wide: wide,
              key: 'nikodesk-view-style',
              title: nikoText('缩放', 'Scale'),
              menus: widget.viewStyles,
              selected: _viewStyle,
              label: (e) => switch (e.value) {
                    kRemoteViewStyleAdaptive => nikoText('适应窗口', 'Fit window'),
                    kRemoteViewStyleOriginal =>
                      nikoText('原始 1:1', 'Original 1:1'),
                    kRemoteViewStyleCustom => nikoText('自定义', 'Custom'),
                    _ => _label(e.child),
                  },
              pick: (value) {
                if (value == _viewStyle) return;
                if (_pick(widget.viewStyles, value)) {
                  setState(() => _viewStyle = value);
                }
              },
              order: const [
                kRemoteViewStyleAdaptive,
                kRemoteViewStyleOriginal,
                kRemoteViewStyleCustom,
              ],
              extra: _viewStyle == kRemoteViewStyleCustom &&
                      widget.customScale != null
                  ? widget.customScale!(context)
                  : null),
        if (widget.qualities.isNotEmpty)
          _choiceRow(
              wide: wide,
              key: 'nikodesk-image-quality',
              title: nikoText('画质', 'Quality'),
              description: nikoText('画质优先更清晰，流畅优先延迟更低。',
                  'Quality is sharper; Speed reacts faster.'),
              menus: widget.qualities,
              selected: _quality,
              label: (e) => switch (e.value) {
                    kRemoteImageQualityBest => nikoText('画质优先', 'Quality'),
                    kRemoteImageQualityBalanced => nikoText('均衡', 'Balanced'),
                    kRemoteImageQualityLow => nikoText('流畅优先', 'Speed'),
                    kRemoteImageQualityCustom => nikoText('自定义', 'Custom'),
                    _ => _label(e.child),
                  },
              // Choosing custom again reopens its settings.
              pick: (value) {
                if (value == _quality && value != kRemoteImageQualityCustom) {
                  return;
                }
                if (_pick(widget.qualities, value)) {
                  setState(() => _quality = value);
                }
              }),
        if (widget.codecs.isNotEmpty)
          _choiceRow(
              wide: wide,
              key: 'nikodesk-codec',
              title: nikoText('编码', 'Codec'),
              description: widget.codecInUse == null
                  ? null
                  : nikoText('正在使用 ${widget.codecInUse}。',
                      'Using ${widget.codecInUse}.'),
              menus: widget.codecs,
              selected: _codec,
              label: (e) => e.value == 'auto'
                  ? nikoText('自动', 'Auto')
                  : e.value.toUpperCase(),
              pick: (value) {
                if (value == _codec) return;
                if (_pick(widget.codecs, value)) {
                  setState(() => _codec = value);
                }
              }),
        if (widget.onPictureMode != null)
          NikoSettingRow(
              key: const Key('nikodesk-picture-mode'),
              title: nikoText('画面模式', 'Picture mode'),
              description: nikoText('按用途一次调好帧率、画质和编码。',
                  'Set frame rate, quality and codec for a task at once.'),
              onTap: widget.onPictureMode),
      ];

  List<Widget> _screen() => [
        if (widget.onResolution != null)
          NikoSettingRow(
              key: const Key('nikodesk-resolution'),
              title: nikoText('分辨率', 'Resolution'),
              trailing: widget.resolution == null
                  ? null
                  : NikoSettingValue(widget.resolution!, mono: true),
              onTap: widget.onResolution),
        if (widget.onVirtualDisplay != null)
          NikoSettingRow(
              key: const Key('nikodesk-virtual-display'),
              title: nikoText('虚拟显示器', 'Virtual display'),
              onTap: widget.onVirtualDisplay),
      ];

  @override
  Widget build(BuildContext context) =>
      // Rows stack their control under the text below this width, as
      // NikoSettingRow does.
      LayoutBuilder(builder: (context, box) => _build(box.maxWidth >= 460));

  Widget _build(bool wide) {
    final nl = NlColors.of(context);
    final groups = [
      (
        nikoText('画面', 'Picture'),
        nikoText('这些选择按设备保存。', 'These choices are saved for this device.'),
        _picture(wide)
      ),
      (nikoText('远端屏幕', 'Remote screen'), null, _screen()),
      (
        nikoText('光标', 'Cursor'),
        null,
        _switches('nikodesk-cursor', widget.cursors, _cursors)
      ),
      (
        nikoText('会话', 'Session'),
        null,
        _switches('nikodesk-toggle', widget.toggles, _toggles)
      ),
    ].where((group) => group.$3.isNotEmpty).toList();
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Semantics(
                      header: true,
                      child: Text(nikoText('画面与显示', 'Display'),
                          style: NlType.text(NlType.s5,
                              weight: FontWeight.w600, color: nl.fg))),
                  if (widget.connection != null)
                    Padding(
                        padding: const EdgeInsets.only(top: NlSpace.s1),
                        child: Row(children: [
                          Icon(widget.secure ? NlIcons.lock : NlIcons.lockOpen,
                              size: 13,
                              color: widget.secure ? nl.okText : nl.warnText),
                          const SizedBox(width: NlSpace.s1 + 2),
                          Flexible(
                              child: Text(widget.connection!,
                                  key: const Key('nikodesk-connection'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      NlType.text(NlType.s2, color: nl.fg2))),
                        ])),
                ])),
            if (widget.onDiagnostics != null)
              NlIconButton(
                  key: const Key('nikodesk-display-diagnostics'),
                  icon: NlIcons.activity,
                  tooltip: nikoText('会话诊断', 'Session diagnostics'),
                  onPressed: widget.onDiagnostics),
            NlIconButton(
                key: const Key('nikodesk-display-close'),
                icon: NlIcons.close,
                tooltip: nikoText('关闭', 'Close'),
                onPressed: widget.onClose),
          ]),
          const SizedBox(height: NlSpace.s2),
          Flexible(
              child: SingleChildScrollView(
                  padding: const EdgeInsets.only(top: NlSpace.s3),
                  child: AnimatedSize(
                      duration: NlMotion.of(context, NlMotion.base),
                      curve: NlMotion.ease,
                      alignment: Alignment.topCenter,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final (title, description, rows) in groups)
                              NikoSettingsGroup(
                                  title: title,
                                  description: description,
                                  bottom: identical(rows, groups.last.$3)
                                      ? 0
                                      : NlSpace.s5,
                                  children: rows),
                          ])))),
        ]);
  }
}

/// The custom scale: a slider between a smaller and a larger step, with
/// the percent it gives. [position] runs from 0 to 1 along the track.
class NikoScaleSlider extends StatelessWidget {
  final int percent;
  final double position;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<int> onStep;

  const NikoScaleSlider(
      {super.key,
      required this.percent,
      required this.position,
      required this.divisions,
      required this.onChanged,
      required this.onStep});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Row(children: [
      NlIconButton(
          icon: NlIcons.minus,
          tooltip: nikoText('缩小', 'Smaller'),
          onPressed: () => onStep(-1)),
      Expanded(
          child: Slider(
              key: const Key('nikodesk-custom-scale'),
              value: position.clamp(0.0, 1.0),
              divisions: divisions,
              label: '$percent%',
              onChanged: onChanged)),
      NlIconButton(
          icon: NlIcons.plus,
          tooltip: nikoText('放大', 'Larger'),
          onPressed: () => onStep(1)),
      SizedBox(
          width: 52,
          child: Text('$percent%',
              textAlign: TextAlign.end,
              style: NlType.monoText(NlType.s3, color: nl.fg))),
    ]);
  }
}
