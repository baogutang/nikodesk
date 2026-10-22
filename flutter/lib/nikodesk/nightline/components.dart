import 'package:flutter/material.dart';

import 'tokens.dart';

enum NlButtonTone { primary, ghost, danger }

/// Text button with an optional leading icon and shortcut hint. Primary is
/// the one accent action of a region; ghost is everything else.
class NlButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;

  /// Shown as a [NlKbd] after the label, e.g. "⏎" or "⌘K". Not announced to
  /// screen readers; the shortcut must also exist on the surrounding page.
  final String? shortcut;
  final NlButtonTone tone;
  final bool small;
  final bool autofocus;
  final FocusNode? focusNode;

  const NlButton(
      {super.key,
      required this.onPressed,
      required this.label,
      this.icon,
      this.shortcut,
      this.small = false,
      this.autofocus = false,
      this.focusNode})
      : tone = NlButtonTone.primary;

  const NlButton.ghost(
      {super.key,
      required this.onPressed,
      required this.label,
      this.icon,
      this.shortcut,
      this.small = false,
      this.autofocus = false,
      this.focusNode})
      : tone = NlButtonTone.ghost;

  const NlButton.danger(
      {super.key,
      required this.onPressed,
      required this.label,
      this.icon,
      this.shortcut,
      this.small = false,
      this.autofocus = false,
      this.focusNode})
      : tone = NlButtonTone.danger;

  static const height = 32.0;
  static const smallHeight = 26.0;

  @override
  State<NlButton> createState() => _NlButtonState();
}

class _NlButtonState extends State<NlButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final enabled = widget.onPressed != null;
    final fast = NlMotion.of(context, NlMotion.fast);
    final hovered = enabled && _hovered;
    final (Color fill, Color ink) = switch (widget.tone) {
      NlButtonTone.primary => (nl.accent, nl.onAccent),
      NlButtonTone.danger => (nl.dangerFill, nl.onDanger),
      NlButtonTone.ghost => (Colors.transparent, nl.fg),
    };
    // Hover moves the fill toward the text colour of the mode, which keeps
    // the label contrast at or above its resting value in both modes.
    final background = widget.tone == NlButtonTone.ghost
        ? (hovered ? nl.surface2 : fill)
        : (hovered ? Color.lerp(fill, nl.fg, .08)! : fill);
    final size = widget.small ? NlType.s2 : NlType.s3;
    return Semantics(
        button: true,
        enabled: enabled,
        child: AnimatedOpacity(
            opacity: enabled ? 1 : .4,
            duration: fast,
            curve: NlMotion.ease,
            child: AnimatedScale(
                scale: _pressed ? .97 : 1,
                duration: fast,
                curve: NlMotion.ease,
                child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                        onTap: widget.onPressed,
                        autofocus: widget.autofocus,
                        focusNode: widget.focusNode,
                        borderRadius: BorderRadius.circular(NlRadius.r2),
                        splashFactory: NoSplash.splashFactory,
                        overlayColor:
                            const WidgetStatePropertyAll(Colors.transparent),
                        onHover: (value) => setState(() => _hovered = value),
                        onHighlightChanged: (value) =>
                            setState(() => _pressed = value),
                        onFocusChange: (value) =>
                            setState(() => _focused = value),
                        child: AnimatedContainer(
                            duration: fast,
                            curve: NlMotion.ease,
                            height: widget.small
                                ? NlButton.smallHeight
                                : NlButton.height,
                            padding: EdgeInsets.symmetric(
                                horizontal:
                                    widget.small ? NlSpace.s2 : NlSpace.s3),
                            decoration: BoxDecoration(
                                color: background,
                                borderRadius:
                                    BorderRadius.circular(NlRadius.r2),
                                border: widget.tone == NlButtonTone.ghost
                                    ? Border.all(color: nl.line2)
                                    : null,
                                boxShadow: _focused ? nl.focusRing : null),
                            child: IconTheme.merge(
                                data: IconThemeData(
                                    color: ink, size: widget.small ? 14 : 16),
                                child: DefaultTextStyle.merge(
                                    style: NlType.text(size,
                                        weight: FontWeight.w600, color: ink),
                                    child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (widget.icon != null) ...[
                                            Icon(widget.icon),
                                            const SizedBox(width: NlSpace.s2),
                                          ],
                                          Flexible(
                                              child: Text(widget.label,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis)),
                                          if (widget.shortcut != null) ...[
                                            const SizedBox(width: NlSpace.s2),
                                            ExcludeSemantics(
                                                child: NlKbd(widget.shortcut!,
                                                    color: ink.withOpacity(.65))),
                                          ],
                                        ])))))))));
  }
}

/// Square icon-only action. [tooltip] doubles as the accessible name.
class NlIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;
  final Color? color;

  const NlIconButton(
      {super.key,
      required this.icon,
      required this.tooltip,
      required this.onPressed,
      this.active = false,
      this.color});

  static const size = 30.0;

  @override
  State<NlIconButton> createState() => _NlIconButtonState();
}

class _NlIconButtonState extends State<NlIconButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final enabled = widget.onPressed != null;
    final lit = enabled && (_hovered || widget.active);
    return Tooltip(
        message: widget.tooltip,
        excludeFromSemantics: true,
        child: Semantics(
            button: true,
            enabled: enabled,
            label: widget.tooltip,
            child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                    onTap: widget.onPressed,
                    borderRadius: BorderRadius.circular(NlRadius.r2),
                    splashFactory: NoSplash.splashFactory,
                    overlayColor:
                        const WidgetStatePropertyAll(Colors.transparent),
                    onHover: (value) => setState(() => _hovered = value),
                    onFocusChange: (value) => setState(() => _focused = value),
                    child: AnimatedContainer(
                        duration: NlMotion.of(context, NlMotion.fast),
                        curve: NlMotion.ease,
                        width: NlIconButton.size,
                        height: NlIconButton.size,
                        decoration: BoxDecoration(
                            color: lit ? nl.surface2 : Colors.transparent,
                            borderRadius: BorderRadius.circular(NlRadius.r2),
                            boxShadow: _focused ? nl.focusRing : null),
                        child: Icon(widget.icon,
                            size: 16,
                            color: !enabled
                                ? nl.fg3.withOpacity(.5)
                                : widget.color ?? (lit ? nl.fg : nl.fg2)))))));
  }
}

class NlSegment<T> {
  final T value;
  final String label;
  final IconData? icon;

  /// Small mono figure after the label, e.g. a filter's item count.
  final String? count;

  /// Key of the segment's button, for callers that address one segment.
  final Key? key;
  const NlSegment(
      {required this.value,
      required this.label,
      this.icon,
      this.count,
      this.key});
}

/// One-of-many switcher on a single track.
class NlSegmented<T> extends StatelessWidget {
  final List<NlSegment<T>> segments;
  final T selected;
  final ValueChanged<T>? onChanged;
  final bool small;

  /// Stretch segments to fill the available width.
  final bool expand;

  const NlSegmented(
      {super.key,
      required this.segments,
      required this.selected,
      required this.onChanged,
      this.small = false,
      this.expand = false});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final children = <Widget>[
      for (var i = 0; i < segments.length; i++) ...[
        if (i > 0) const SizedBox(width: 2),
        _wrap(_SegmentButton<T>(
            key: segments[i].key,
            segment: segments[i],
            selected: segments[i].value == selected,
            small: small,
            onTap: onChanged == null ? null : () => onChanged!(segments[i].value))),
      ]
    ];
    return Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
            color: nl.surface,
            borderRadius: BorderRadius.circular(NlRadius.r2),
            border: Border.all(color: nl.ring)),
        child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: children));
  }

  Widget _wrap(Widget child) => expand ? Expanded(child: child) : child;
}

class _SegmentButton<T> extends StatefulWidget {
  final NlSegment<T> segment;
  final bool selected;
  final bool small;
  final VoidCallback? onTap;
  const _SegmentButton(
      {super.key,
      required this.segment,
      required this.selected,
      required this.small,
      required this.onTap});

  @override
  State<_SegmentButton<T>> createState() => _SegmentButtonState<T>();
}

class _SegmentButtonState<T> extends State<_SegmentButton<T>> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final selected = widget.selected;
    final ink = selected ? nl.accentText : (_hovered ? nl.fg : nl.fg2);
    return Semantics(
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: Material(
            type: MaterialType.transparency,
            child: InkWell(
                onTap: widget.onTap,
                borderRadius: BorderRadius.circular(NlRadius.r1),
                splashFactory: NoSplash.splashFactory,
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                onHover: (value) => setState(() => _hovered = value),
                onFocusChange: (value) => setState(() => _focused = value),
                child: AnimatedContainer(
                    duration: NlMotion.of(context, NlMotion.fast),
                    curve: NlMotion.ease,
                    height: widget.small ? 22 : 26,
                    padding: EdgeInsets.symmetric(
                        horizontal: widget.small ? NlSpace.s2 : NlSpace.s3),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: selected ? nl.accentSoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(NlRadius.r1),
                        boxShadow: _focused ? nl.focusRing : null),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (widget.segment.icon != null) ...[
                        Icon(widget.segment.icon, size: 14, color: ink),
                        const SizedBox(width: NlSpace.s1),
                      ],
                      Flexible(
                          child: Text(widget.segment.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NlType.text(
                                  widget.small ? NlType.s1 : NlType.s2,
                                  weight: FontWeight.w500,
                                  color: ink))),
                      if (widget.segment.count != null) ...[
                        const SizedBox(width: NlSpace.s1),
                        Text(widget.segment.count!,
                            style: NlType.monoText(NlType.s1,
                                color: selected ? nl.accentText : nl.fg3)),
                      ],
                    ])))));
  }
}

/// Toggleable chip. With [strikeWhenOff] an unselected chip reads as
/// "revoked", as permission chips do in the connection manager.
class NlChip extends StatefulWidget {
  final String label;
  final bool selected;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;
  final bool strikeWhenOff;

  const NlChip(
      {super.key,
      required this.label,
      required this.selected,
      required this.onChanged,
      this.icon,
      this.strikeWhenOff = false});

  @override
  State<NlChip> createState() => _NlChipState();
}

class _NlChipState extends State<NlChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final on = widget.selected;
    final ink = on ? nl.accentText : nl.fg3;
    return Semantics(
        toggled: on,
        button: true,
        child: Material(
            type: MaterialType.transparency,
            child: InkWell(
                onTap: widget.onChanged == null
                    ? null
                    : () => widget.onChanged!(!on),
                borderRadius: BorderRadius.circular(NlRadius.r1),
                splashFactory: NoSplash.splashFactory,
                hoverColor: nl.surface2,
                onFocusChange: (value) => setState(() => _focused = value),
                child: AnimatedContainer(
                    duration: NlMotion.of(context, NlMotion.fast),
                    curve: NlMotion.ease,
                    height: 28,
                    padding: const EdgeInsets.symmetric(horizontal: NlSpace.s3),
                    decoration: BoxDecoration(
                        color: on ? nl.accentSoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(NlRadius.r1),
                        border: Border.all(
                            color: on ? nl.accent.withOpacity(.45) : nl.line2),
                        boxShadow: _focused ? nl.focusRing : null),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (widget.icon != null) ...[
                        Icon(widget.icon, size: 14, color: ink),
                        const SizedBox(width: NlSpace.s2),
                      ],
                      Flexible(
                          child: Text(widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NlType.text(NlType.s2, color: ink).copyWith(
                                  decoration: !on && widget.strikeWhenOff
                                      ? TextDecoration.lineThrough
                                      : null,
                                  decorationColor: nl.fg3.withOpacity(.6)))),
                    ])))));
  }
}

/// Resting surface for grouped content. Elevation 1 is a hairline only;
/// 2 and 3 are for floating layers.
class NlPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final int elevation;
  final Color? color;

  const NlPanel(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.symmetric(
          horizontal: NlSpace.s4, vertical: NlSpace.s3),
      this.elevation = 1,
      this.color});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Container(
        padding: padding,
        decoration: BoxDecoration(
            color: color ?? (elevation > 1 ? nl.overlay : nl.surface),
            borderRadius: BorderRadius.circular(NlRadius.r3),
            border: elevation > 1 ? null : Border.all(color: nl.ring),
            boxShadow: nl.shadow(elevation)),
        child: child);
  }
}

/// Settings-style row: title, optional detail, trailing control.
class NlListRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Draws the hairline above the row; the first row of a group omits it.
  final bool divider;
  final bool dense;

  const NlListRow(
      {super.key,
      required this.title,
      this.subtitle,
      this.leading,
      this.trailing,
      this.onTap,
      this.divider = true,
      this.dense = false});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final row = Container(
        constraints: BoxConstraints(minHeight: dense ? 32 : 48),
        padding:
            EdgeInsets.symmetric(vertical: dense ? NlSpace.s1 : NlSpace.s2),
        decoration: BoxDecoration(
            border: divider
                ? Border(top: BorderSide(color: nl.line))
                : null),
        child: Row(children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: NlSpace.s3),
          ],
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                Text(title, style: NlType.text(NlType.s3, color: nl.fg)),
                if (subtitle != null)
                  Text(subtitle!,
                      style: NlType.text(NlType.s1, color: nl.fg3)),
              ])),
          if (trailing != null) ...[
            const SizedBox(width: NlSpace.s3),
            trailing!,
          ],
        ]));
    if (onTap == null) return row;
    return Material(
        type: MaterialType.transparency,
        child: InkWell(
            onTap: onTap,
            splashFactory: NoSplash.splashFactory,
            hoverColor: nl.surface2.withOpacity(.6),
            focusColor: nl.accentSoft,
            child: row));
  }
}

/// Keyboard key cap for shortcut hints.
class NlKbd extends StatelessWidget {
  final String keys;
  final Color? color;
  const NlKbd(this.keys, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final ink = color ?? nl.fg3;
    return Container(
        height: 16,
        padding: const EdgeInsets.symmetric(horizontal: NlSpace.s1),
        alignment: Alignment.center,
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(NlRadius.r1),
            border: Border.all(color: color ?? nl.line2)),
        child: Text(keys,
            style: NlType.monoText(NlType.s1, color: ink).copyWith(height: 1)));
  }
}

enum NlLedState { off, ok, warn, danger, live }

/// Status light. [NlLedState.live] pulses unless motion is reduced.
class NlLed extends StatefulWidget {
  final NlLedState state;
  final String? semanticLabel;
  const NlLed(this.state, {super.key, this.semanticLabel});

  static const size = 7.0;

  @override
  State<NlLed> createState() => _NlLedState();
}

class _NlLedState extends State<NlLed> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(NlLed oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    final pulse = widget.state == NlLedState.live && !NlMotion.reduced(context);
    if (pulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!pulse && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final color = switch (widget.state) {
      NlLedState.off => null,
      NlLedState.ok || NlLedState.live => nl.ok,
      NlLedState.warn => nl.warn,
      NlLedState.danger => nl.danger,
    };
    final dot = Container(
        width: NlLed.size,
        height: NlLed.size,
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: color == null ? Border.all(color: nl.fg3, width: 1.5) : null,
            boxShadow: color == null
                ? null
                : [BoxShadow(color: color.withOpacity(.7), blurRadius: 6)]));
    return Semantics(
        label: widget.semanticLabel,
        child: widget.state == NlLedState.live
            ? FadeTransition(
                opacity: Tween<double>(begin: 1, end: .35).animate(
                    CurvedAnimation(parent: _pulse, curve: NlMotion.ease)),
                child: dot)
            : dot);
  }
}

enum NlTone { neutral, accent, ok, warn, danger }

/// Uppercase mono label used for section names, units and metric captions.
class NlMonoLabel extends StatelessWidget {
  final String text;
  final NlTone tone;
  final Widget? leading;
  const NlMonoLabel(this.text, {super.key, this.tone = NlTone.neutral, this.leading});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final color = switch (tone) {
      NlTone.neutral => nl.fg3,
      NlTone.accent => nl.accentText,
      NlTone.ok => nl.okText,
      NlTone.warn => nl.warnText,
      NlTone.danger => nl.dangerText,
    };
    final label = Text(text.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: NlType.monoText(NlType.s1, weight: FontWeight.w500, color: color)
            .copyWith(letterSpacing: NlType.s1 * NlType.labelTracking));
    if (leading == null) return label;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      leading!,
      const SizedBox(width: NlSpace.s2),
      Flexible(child: label),
    ]);
  }
}

/// The NikoDesk mark on its dark tile, as drawn in the Nightline draft.
class NlMark extends StatelessWidget {
  final double size;
  const NlMark({super.key, this.size = 36});

  @override
  Widget build(BuildContext context) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * .28),
          gradient: const RadialGradient(
              center: Alignment(-.6, -1),
              radius: 1.2,
              stops: [0, .7],
              colors: [Color(0xFF1F2A3A), Color(0xFF0B0E13)]),
          border: Border.all(color: const Color(0x477FA2FF)),
          boxShadow: const [
            BoxShadow(color: Color(0x992FD8EE), blurRadius: 15, spreadRadius: -6)
          ]),
      child: CustomPaint(painter: _MarkPainter()));
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final glyph = size.width * .72;
    final scale = glyph / 64;
    canvas.translate((size.width - glyph) / 2, (size.height - glyph) / 2);
    canvas.scale(scale);
    const stroke = 7.6;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..shader = const LinearGradient(
              colors: [Color(0xFF7FA2FF), Color(0xFF2FD8EE)])
          .createShader(const Rect.fromLTWH(0, 0, 64, 64));
    canvas.drawPath(
        Path()
          ..moveTo(14, 16)
          ..lineTo(14, 48)
          ..lineTo(24, 48)
          ..moveTo(14, 16)
          ..lineTo(50, 49)
          ..lineTo(50, 37)
          ..moveTo(39, 15)
          ..lineTo(50, 15)
          ..lineTo(50, 29),
        paint);
    final dot = Paint()..color = const Color(0xFF2FD8EE);
    canvas.drawCircle(const Offset(31.5, 15), stroke * .52, dot);
    canvas.drawCircle(const Offset(31.5, 48.5), stroke * .52, dot);
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => false;
}
