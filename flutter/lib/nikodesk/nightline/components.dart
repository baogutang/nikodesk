import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'icons.dart';
import 'tokens.dart';

/// Whether keyboard focus should be drawn: true after a key press, false
/// after a pointer press, as the web's :focus-visible. Flutter's own
/// highlight mode misses a trackpad connecting to an iPad, and treats a
/// mouse click like a key press.
class NlFocusVisible extends ChangeNotifier {
  NlFocusVisible._() {
    HardwareKeyboard.instance.addHandler(_key);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
  }

  static NlFocusVisible? _instance;
  static NlFocusVisible get instance => _instance ??= NlFocusVisible._();

  static final _modifiers = {
    ...LogicalKeyboardKey.expandSynonyms({
      LogicalKeyboardKey.shift,
      LogicalKeyboardKey.control,
      LogicalKeyboardKey.alt,
      LogicalKeyboardKey.meta,
    }),
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.fn,
  };

  bool _visible = false;
  bool get visible => _visible;

  bool _key(KeyEvent event) {
    if (event is KeyDownEvent &&
        !_visible &&
        !_modifiers.contains(event.logicalKey)) {
      _visible = true;
      notifyListeners();
    }
    return false;
  }

  void _pointer(PointerEvent event) {
    if (event is PointerDownEvent && _visible) {
      _visible = false;
      notifyListeners();
    }
  }
}

/// Hover, press and keyboard-focus states for a custom tappable surface.
/// The focus ring only shows for keyboard focus; [onContextMenu] fires on a
/// secondary click and on a long press. [semanticLabel] is for surfaces
/// without text of their own; visible text already names the control.
class NlPressable extends StatefulWidget {
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onContextMenu;
  final Widget Function(BuildContext context, Set<WidgetState> states) builder;
  final bool autofocus;
  final FocusNode? focusNode;
  final String? semanticLabel;
  final bool selected;
  final bool button;

  /// Scale while pressed; 1 turns the effect off.
  final double pressScale;
  final MouseCursor? cursor;

  const NlPressable(
      {super.key,
      required this.onTap,
      required this.builder,
      this.onContextMenu,
      this.autofocus = false,
      this.focusNode,
      this.semanticLabel,
      this.selected = false,
      this.button = true,
      this.pressScale = .98,
      this.cursor});

  @override
  State<NlPressable> createState() => _NlPressableState();
}

class _NlPressableState extends State<NlPressable> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  /// A long press opens the context menu for touch and stylus only; a
  /// held mouse button is not a gesture on desktop.
  PointerDeviceKind? _kind;

  bool get _enabled => widget.onTap != null;

  Set<WidgetState> get _states => {
        if (!_enabled) WidgetState.disabled,
        if (_hovered && _enabled) WidgetState.hovered,
        if (_pressed && _enabled) WidgetState.pressed,
        if (_focused && NlFocusVisible.instance.visible) WidgetState.focused,
        if (widget.selected) WidgetState.selected,
      };

  @override
  void initState() {
    super.initState();
    NlFocusVisible.instance.addListener(_focusVisibleChanged);
  }

  @override
  void dispose() {
    NlFocusVisible.instance.removeListener(_focusVisibleChanged);
    super.dispose();
  }

  void _focusVisibleChanged() {
    if (_focused && mounted) setState(() {});
  }

  void _hover(bool value) {
    if (_hovered != value) setState(() => _hovered = value);
  }

  void _press(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scale = _pressed && _enabled ? widget.pressScale : 1.0;
    Widget child = widget.builder(context, _states);
    if (widget.pressScale != 1) {
      child = AnimatedScale(
          scale: scale,
          duration: NlMotion.of(context, NlMotion.fast),
          curve: NlMotion.ease,
          child: child);
    }
    return Semantics(
        button: widget.button,
        enabled: _enabled,
        selected: widget.selected,
        label: widget.semanticLabel,
        child: FocusableActionDetector(
            enabled: _enabled,
            autofocus: widget.autofocus,
            focusNode: widget.focusNode,
            mouseCursor: _enabled
                ? widget.cursor ?? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onFocusChange: (value) => setState(() => _focused = value),
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) => widget.onTap?.call()),
            },
            child: MouseRegion(
                onEnter: (_) => _hover(true),
                onExit: (_) => _hover(false),
                child: Listener(
                onPointerDown: (event) => _kind = event.kind,
                child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: _enabled ? (_) => _press(true) : null,
                onTapUp: _enabled ? (_) => _press(false) : null,
                onTapCancel: () => _press(false),
                onTap: widget.onTap,
                onSecondaryTapUp: widget.onContextMenu == null
                    ? null
                    : (details) =>
                        widget.onContextMenu!(details.globalPosition),
                onLongPressStart: widget.onContextMenu == null
                    ? null
                    : (details) {
                        _press(false);
                        if (_kind == PointerDeviceKind.mouse ||
                            _kind == PointerDeviceKind.trackpad) return;
                        HapticFeedback.mediumImpact();
                        widget.onContextMenu!(details.globalPosition);
                      },
                child: child)))));
  }
}

enum NlButtonTone { primary, ghost, quiet, danger }

/// Text button with an optional leading icon and shortcut hint. Primary is
/// the one accent action of a region; ghost (bordered) is the default for
/// everything else; quiet is a text-only action inside dense rows.
class NlButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;

  /// Shown as a [NlKbd] after the label, e.g. "⏎" or "⌘K". Not announced to
  /// screen readers; the shortcut must also exist on the surrounding page.
  final String? shortcut;
  final NlButtonTone tone;
  final bool small;
  final bool large;

  /// Replaces the icon with a spinner and ignores presses.
  final bool loading;
  final bool expand;
  final bool autofocus;
  final FocusNode? focusNode;

  const NlButton(
      {super.key,
      required this.onPressed,
      required this.label,
      this.icon,
      this.shortcut,
      this.small = false,
      this.large = false,
      this.loading = false,
      this.expand = false,
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
      this.large = false,
      this.loading = false,
      this.expand = false,
      this.autofocus = false,
      this.focusNode})
      : tone = NlButtonTone.ghost;

  const NlButton.quiet(
      {super.key,
      required this.onPressed,
      required this.label,
      this.icon,
      this.shortcut,
      this.small = false,
      this.large = false,
      this.loading = false,
      this.expand = false,
      this.autofocus = false,
      this.focusNode})
      : tone = NlButtonTone.quiet;

  const NlButton.danger(
      {super.key,
      required this.onPressed,
      required this.label,
      this.icon,
      this.shortcut,
      this.small = false,
      this.large = false,
      this.loading = false,
      this.expand = false,
      this.autofocus = false,
      this.focusNode})
      : tone = NlButtonTone.danger;

  /// Pointer-platform heights; touch platforms add 8.
  static const height = 32.0;
  static const smallHeight = 26.0;
  static const largeHeight = 40.0;

  static double heightOf(BuildContext context,
          {bool small = false, bool large = false}) =>
      (small
          ? smallHeight
          : large
              ? largeHeight
              : height) +
      (NlLayout.touch(context) ? 8 : 0);

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final enabled = onPressed != null && !loading;
    final instant = NlMotion.of(context, NlMotion.instant);
    final size = small ? NlType.s2 : (large ? NlType.s4 : NlType.s3);
    return NlPressable(
        onTap: enabled ? onPressed : null,
        autofocus: autofocus,
        focusNode: focusNode,
        pressScale: .97,
        builder: (context, states) {
          final hovered = states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.pressed);
          final (Color fill, Color ink, Color? side) = switch (tone) {
            NlButtonTone.primary => (
                hovered ? nl.accentHover : nl.accentFill,
                nl.onAccent,
                null
              ),
            NlButtonTone.danger => (
                hovered ? nl.dangerHover : nl.dangerFill,
                nl.onDanger,
                null
              ),
            NlButtonTone.ghost => (
                nl.solid(hovered ? nl.hover : Colors.transparent,
                    nl.isDark ? nl.surface2 : nl.overlay),
                nl.fg,
                nl.line2
              ),
            NlButtonTone.quiet => (
                hovered ? nl.hover : Colors.transparent,
                nl.fg,
                null
              ),
          };
          final content = Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (loading) ...[
                  NlSpinner(size: small ? 12 : 14, color: ink),
                  const SizedBox(width: NlSpace.s2),
                ] else if (icon != null) ...[
                  Icon(icon),
                  SizedBox(width: small ? 5 : 6),
                ],
                Flexible(
                    child: Text(label,
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (shortcut != null) ...[
                  const SizedBox(width: NlSpace.s2),
                  ExcludeSemantics(
                      child: NlKbd(shortcut!, color: ink.withOpacity(.7))),
                ],
              ]);
          final visual = AnimatedOpacity(
              opacity: onPressed == null ? .45 : 1,
              duration: instant,
              child: AnimatedContainer(
                  duration: instant,
                  curve: NlMotion.standard,
                  // A minimum, so large text grows the button instead of
                  // clipping its label.
                  constraints: BoxConstraints(
                      minHeight: heightOf(context, small: small, large: large)),
                  padding: EdgeInsets.symmetric(
                      horizontal: small
                          ? NlSpace.s2 + 2
                          : (large ? NlSpace.s5 : NlSpace.s3 + 2)),
                  decoration: BoxDecoration(
                      color: fill,
                      borderRadius: BorderRadius.circular(NlRadius.r2),
                      border: side == null ? null : Border.all(color: side),
                      boxShadow: [
                        if (states.contains(WidgetState.focused))
                          ...nl.focusRing
                        else if (tone == NlButtonTone.ghost)
                          ...nl.shadow1,
                      ]),
                  child: Center(
                      widthFactor: expand ? null : 1,
                      heightFactor: 1,
                      child: IconTheme.merge(
                          data: IconThemeData(
                              color: ink, size: small ? 14 : (large ? 18 : 16)),
                          child: DefaultTextStyle.merge(
                              style: NlType.text(size,
                                  weight: FontWeight.w500, color: ink),
                              child: content)))));
          if (!NlLayout.touch(context)) return visual;
          // Touch keeps a 48-point hit area around the visible button.
          return ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Center(
                  widthFactor: expand ? null : 1,
                  heightFactor: 1,
                  child: visual));
        });
  }
}

/// Square icon-only action. [tooltip] doubles as the accessible name.
class NlIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;
  final Color? color;

  /// Draws the bordered ghost style instead of a bare icon.
  final bool outlined;
  final double? iconSize;

  const NlIconButton(
      {super.key,
      required this.icon,
      required this.tooltip,
      required this.onPressed,
      this.active = false,
      this.color,
      this.outlined = false,
      this.iconSize});

  /// Pointer-platform size; touch platforms use 44.
  static const size = 30.0;

  static double sizeOf(BuildContext context) =>
      NlLayout.touch(context) ? 44 : size;

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final enabled = onPressed != null;
    return Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: NlPressable(
            onTap: onPressed,
            semanticLabel: tooltip,
            selected: active,
            pressScale: .94,
            builder: (context, states) {
              final hovered = states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.pressed);
              final side = sizeOf(context);
              return AnimatedContainer(
                  duration: NlMotion.of(context, NlMotion.instant),
                  width: side,
                  height: side,
                  decoration: BoxDecoration(
                      color: active
                          ? nl.selected
                          : hovered
                              ? nl.hover
                              : outlined
                                  ? (nl.isDark ? nl.surface2 : nl.overlay)
                                  : Colors.transparent,
                      borderRadius: BorderRadius.circular(NlRadius.r2),
                      border: outlined ? Border.all(color: nl.line2) : null,
                      boxShadow: states.contains(WidgetState.focused)
                          ? nl.focusRing
                          : null),
                  child: Icon(icon,
                      size: iconSize ?? (NlLayout.touch(context) ? 20 : 16),
                      color: !enabled
                          ? nl.fg3.withOpacity(.5)
                          : color ?? (active || hovered ? nl.fg : nl.fg2)));
            }));
  }
}

class NlSegment<T> {
  final T value;
  final String label;
  final IconData? icon;

  /// Small figure after the label, e.g. a filter's item count.
  final String? count;

  /// Key of the segment's button, for callers that address one segment.
  final Key? key;

  /// Hides the label and uses it as the tooltip.
  final bool iconOnly;
  const NlSegment(
      {required this.value,
      required this.label,
      this.icon,
      this.count,
      this.key,
      this.iconOnly = false});
}

/// One-of-many switcher on a single track. Segments share the widest
/// segment's width and a raised thumb slides to the selected one.
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
    final index = segments.indexWhere((s) => s.value == selected);
    final count = segments.length;
    final height = (small ? 24.0 : 28.0) + (NlLayout.touch(context) ? 6 : 0);
    final row = Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            Expanded(
                child: _SegmentButton<T>(
                    key: segments[i].key,
                    segment: segments[i],
                    selected: i == index,
                    small: small,
                    height: height,
                    onTap: onChanged == null
                        ? null
                        : () => onChanged!(segments[i].value))),
        ]);
    final track = Stack(children: [
      if (index >= 0)
        Positioned.fill(
            child: AnimatedAlign(
                duration: NlMotion.of(context, NlMotion.base),
                curve: NlMotion.ease,
                alignment: Alignment(
                    count == 1 ? 0 : -1 + 2 * index / (count - 1), 0),
                child: FractionallySizedBox(
                    widthFactor: 1 / count,
                    child: Container(
                        decoration: BoxDecoration(
                            color: nl.isDark ? nl.line2 : nl.overlay,
                            borderRadius: BorderRadius.circular(NlRadius.r2 - 2),
                            boxShadow: nl.isDark
                                ? null
                                : const [
                                    BoxShadow(
                                        color: Color(0x1F000000),
                                        offset: Offset(0, 1),
                                        blurRadius: 3),
                                    BoxShadow(
                                        color: Color(0x0A000000),
                                        spreadRadius: .5),
                                  ]))))),
      row,
    ]);
    return Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
            color: nl.isDark ? nl.surface : nl.surface2,
            borderRadius: BorderRadius.circular(NlRadius.r2)),
        child: expand ? track : IntrinsicWidth(child: track));
  }
}

class _SegmentButton<T> extends StatelessWidget {
  final NlSegment<T> segment;
  final bool selected;
  final bool small;
  final double height;
  final VoidCallback? onTap;
  const _SegmentButton(
      {super.key,
      required this.segment,
      required this.selected,
      required this.small,
      required this.height,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final button = NlPressable(
        onTap: onTap,
        selected: selected,
        semanticLabel: segment.iconOnly ? segment.label : null,
        pressScale: 1,
        builder: (context, states) {
          final ink = selected || states.contains(WidgetState.hovered)
              ? nl.fg
              : nl.fg2;
          return AnimatedContainer(
              duration: NlMotion.of(context, NlMotion.instant),
              height: height,
              padding: EdgeInsets.symmetric(
                  horizontal: segment.iconOnly
                      ? NlSpace.s2
                      : (small ? NlSpace.s2 : NlSpace.s3)),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(NlRadius.r2 - 2),
                  boxShadow: states.contains(WidgetState.focused)
                      ? nl.focusRing
                      : null),
              child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (segment.icon != null) ...[
                      Icon(segment.icon, size: small ? 13 : 14, color: ink),
                      if (!segment.iconOnly) const SizedBox(width: 5),
                    ],
                    if (!segment.iconOnly)
                      Flexible(
                          child: Text(segment.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NlType.text(
                                  small ? NlType.s1 : NlType.s2,
                                  weight: FontWeight.w500,
                                  color: ink))),
                    if (segment.count != null) ...[
                      const SizedBox(width: NlSpace.s1),
                      Text(segment.count!,
                          style: NlType.monoText(NlType.s1,
                              color: selected ? nl.fg2 : nl.fg3)),
                    ],
                  ]));
        });
    return Semantics(
        inMutuallyExclusiveGroup: true,
        child: segment.iconOnly
            ? Tooltip(
                message: segment.label,
                excludeFromSemantics: true,
                child: button)
            : button);
  }
}

/// Toggleable chip. With [strikeWhenOff] an unselected chip reads as
/// "revoked", as permission chips do in the connection manager.
class NlChip extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final on = selected;
    return Semantics(
        toggled: on,
        child: NlPressable(
            onTap: onChanged == null ? null : () => onChanged!(!on),
            pressScale: .97,
            builder: (context, states) {
              final hovered = states.contains(WidgetState.hovered);
              final ink = on ? nl.accentText : (hovered ? nl.fg : nl.fg2);
              return AnimatedContainer(
                  duration: NlMotion.of(context, NlMotion.fast),
                  curve: NlMotion.standard,
                  height: 28 + (NlLayout.touch(context) ? 4 : 0),
                  padding: const EdgeInsets.symmetric(horizontal: NlSpace.s3),
                  decoration: BoxDecoration(
                      color: on
                          ? nl.accentSoft
                          : hovered
                              ? nl.hover
                              : Colors.transparent,
                      borderRadius: BorderRadius.circular(NlRadius.r2),
                      border: Border.all(
                          color: on ? nl.accent.withOpacity(.4) : nl.line2),
                      boxShadow: states.contains(WidgetState.focused)
                          ? nl.focusRing
                          : null),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (icon != null) ...[
                      Icon(icon, size: 14, color: ink),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                        child: Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NlType.text(NlType.s2,
                                    weight: FontWeight.w500, color: ink)
                                .copyWith(
                                    decoration: !on && strikeWhenOff
                                        ? TextDecoration.lineThrough
                                        : null,
                                    decorationColor: nl.fg3.withOpacity(.6)))),
                  ]));
            }));
  }
}

/// Resting surface for grouped content. Elevation 1 is a hairline and, in
/// light mode, a faint shadow; 2 and 3 are for floating layers.
class NlPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final int elevation;
  final Color? color;
  final double radius;

  const NlPanel(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.symmetric(
          horizontal: NlSpace.s4, vertical: NlSpace.s3),
      this.elevation = 1,
      this.color,
      this.radius = NlRadius.r3});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Container(
        padding: padding,
        decoration: BoxDecoration(
            color: color ?? (elevation > 1 ? nl.overlay : nl.surface),
            borderRadius: BorderRadius.circular(radius),
            border: elevation > 1 ? null : Border.all(color: nl.ring),
            boxShadow: nl.shadow(elevation)),
        child: child);
  }
}

/// Settings-style row: title, optional detail, trailing control. Rows in a
/// group share one [NlPanel]; [divider] draws the hairline above the row,
/// inset to the text when there is a leading widget.
class NlListRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool divider;
  final bool dense;

  /// Adds a trailing chevron for rows that open a page or sheet.
  final bool chevron;
  final bool destructive;

  const NlListRow(
      {super.key,
      required this.title,
      this.subtitle,
      this.leading,
      this.trailing,
      this.onTap,
      this.divider = true,
      this.dense = false,
      this.chevron = false,
      this.destructive = false});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    final minHeight = dense ? (touch ? 44.0 : 32.0) : (touch ? 52.0 : 44.0);
    Widget row(Set<WidgetState> states) => AnimatedContainer(
        duration: NlMotion.of(context, NlMotion.instant),
        constraints: BoxConstraints(minHeight: minHeight),
        color: states.contains(WidgetState.pressed)
            ? nl.selected
            : states.contains(WidgetState.hovered)
                ? nl.hover
                : Colors.transparent,
        child: Stack(children: [
          if (divider)
            Positioned(
                top: 0,
                right: 0,
                left: leading == null ? 0 : NlSpace.s8 + NlSpace.s1,
                child: Container(height: 1, color: nl.line)),
          Padding(
              padding: EdgeInsets.symmetric(
                  vertical: dense ? NlSpace.s1 : NlSpace.s2),
              child: Row(children: [
                if (leading != null) ...[
                  SizedBox(width: 24, child: Center(child: leading!)),
                  const SizedBox(width: NlSpace.s3),
                ],
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                      Text(title,
                          style: NlType.text(touch ? NlType.s4 : NlType.s3,
                              color: destructive ? nl.dangerText : nl.fg)),
                      if (subtitle != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(subtitle!,
                                style: NlType.text(NlType.s2, color: nl.fg3))),
                    ])),
                if (trailing != null) ...[
                  const SizedBox(width: NlSpace.s3),
                  trailing!,
                ],
                if (chevron) ...[
                  const SizedBox(width: NlSpace.s2),
                  Icon(NlIcons.chevronRight, size: 16, color: nl.fg3),
                ],
              ])),
        ]));
    if (onTap == null) return row(const {});
    return NlPressable(
        onTap: onTap,
        pressScale: 1,
        builder: (context, states) => DecoratedBox(
            decoration: BoxDecoration(
                boxShadow:
                    states.contains(WidgetState.focused) ? nl.focusRing : null),
            child: row(states)));
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
        // A minimum rather than a height, so large text grows the key.
        constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
            color: color == null ? nl.solid(nl.hover, nl.bg) : null,
            borderRadius: BorderRadius.circular(NlRadius.r1),
            border: Border.all(color: color?.withOpacity(.35) ?? nl.line)),
        // Centred inside the minimum size without stretching to the parent.
        child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(keys,
                style: NlType.text(NlType.s1,
                        weight: FontWeight.w500, color: ink)
                    .copyWith(height: 1, letterSpacing: .2))));
  }
}

enum NlLedState { off, ok, warn, danger, live }

/// Status light. [NlLedState.live] sends out a soft ring unless motion is
/// reduced.
class NlLed extends StatefulWidget {
  final NlLedState state;
  final String? semanticLabel;
  final double size;
  const NlLed(this.state, {super.key, this.semanticLabel, this.size = NlLed.dotSize});

  static const dotSize = 7.0;

  @override
  State<NlLed> createState() => _NlLedState();
}

class _NlLedState extends State<NlLed> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1800));

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
      _pulse.repeat();
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
    final size = widget.size;
    final dot = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border:
                color == null ? Border.all(color: nl.fg3, width: 1.25) : null));
    return Semantics(
        label: widget.semanticLabel,
        child: SizedBox(
            width: size,
            height: size,
            child: widget.state != NlLedState.live
                ? dot
                : Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
                    AnimatedBuilder(
                        animation: _pulse,
                        builder: (context, _) {
                          final t = Curves.easeOut.transform(_pulse.value);
                          return Transform.scale(
                              scale: 1 + 1.6 * t,
                              child: Container(
                                  width: size,
                                  height: size,
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: color!.withOpacity(.45 * (1 - t)))));
                        }),
                    dot,
                  ])));
  }
}

enum NlTone { neutral, accent, ok, warn, danger }

/// A short state or unit label, e.g. "已就绪" or "fps", in the body face.
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
    // Sentence case in the body face: tracked capitals read as generated.
    final label = Text(text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: NlType.text(NlType.s2, weight: FontWeight.w500, color: color));
    if (leading == null) return label;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      leading!,
      const SizedBox(width: NlSpace.s2),
      Flexible(child: label),
    ]);
  }
}

/// Sentence-case section heading for lists, groups and the sidebar.
class NlSectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  const NlSectionLabel(this.text,
      {super.key,
      this.trailing,
      this.padding = const EdgeInsets.only(bottom: NlSpace.s2)});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Padding(
        padding: padding,
        child: Row(children: [
          Expanded(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NlType.text(NlType.s2,
                      weight: FontWeight.w500, color: nl.fg3))),
          if (trailing != null) trailing!,
        ]));
  }
}

/// The NikoDesk app icon, as in the Dock.
class NlMark extends StatelessWidget {
  final double size;
  const NlMark({super.key, this.size = 36});

  @override
  Widget build(BuildContext context) => Semantics(
      label: 'NikoDesk',
      image: true,
      child: SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(size * .23),
                  boxShadow: [
                    BoxShadow(
                        color: const Color(0xFF0A6CFF).withOpacity(.22),
                        offset: Offset(0, size * .06),
                        blurRadius: size * .22),
                  ]),
              child: ClipRRect(
                  borderRadius: BorderRadius.circular(size * .23),
                  child: Image.asset('assets/nikodesk.png',
                      width: size,
                      height: size,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, __, ___) => const ColoredBox(
                          color: Color(0xFF0A84FF)))))));
}

/// Thin indeterminate spinner that matches the text it sits next to.
class NlSpinner extends StatelessWidget {
  final double size;
  final Color? color;
  const NlSpinner({super.key, this.size = 16, this.color});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
            strokeWidth: size < 14 ? 1.5 : 2,
            strokeCap: StrokeCap.round,
            color: color ?? nl.fg2,
            backgroundColor: (color ?? nl.fg2).withOpacity(.18)));
  }
}
