import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'components.dart';
import 'icons.dart';
import 'tokens.dart';

/// Interactive card: lifts on hover, settles on press, and carries an accent
/// outline when [selected].
class NlCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onContextMenu;
  final bool selected;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;
  final double radius;
  final Color? color;

  const NlCard(
      {super.key,
      required this.child,
      this.onTap,
      this.onContextMenu,
      this.selected = false,
      this.padding = const EdgeInsets.all(NlSpace.s4),
      this.semanticLabel,
      this.radius = NlRadius.r3,
      this.color});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return NlPressable(
        onTap: onTap,
        onContextMenu: onContextMenu,
        selected: selected,
        semanticLabel: semanticLabel,
        pressScale: .985,
        builder: (context, states) {
          final hovered = states.contains(WidgetState.hovered);
          final focused = states.contains(WidgetState.focused);
          final base = color ?? nl.surface;
          return AnimatedContainer(
              duration: NlMotion.of(context, NlMotion.base),
              curve: NlMotion.ease,
              transform: Matrix4.translationValues(
                  0, hovered && !selected ? -1.5 : 0, 0),
              padding: padding,
              decoration: BoxDecoration(
                  color: selected
                      ? nl.solid(nl.accentSoft, base)
                      : hovered && nl.isDark
                          ? nl.solid(nl.hover, base)
                          : base,
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                      color: selected
                          ? nl.accent
                          : hovered
                              ? nl.line2
                              : nl.ring,
                      width: selected ? 1.5 : 1),
                  boxShadow: [
                    if (focused) ...nl.focusRing,
                    if (!nl.isDark && hovered && !selected) ...const [
                      BoxShadow(
                          color: Color(0x14000000),
                          offset: Offset(0, 6),
                          blurRadius: 18,
                          spreadRadius: -4),
                      BoxShadow(
                          color: Color(0x0A000000),
                          offset: Offset(0, 1),
                          blurRadius: 3),
                    ] else
                      ...nl.shadow1,
                  ]),
              child: child);
        });
  }
}

/// Shows [builder] as a centred dialog that fades and scales in from 96 %.
Future<T?> showNlDialog<T>(
    {required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    bool useRootNavigator = true}) {
  final nl = NlColors.of(context);
  final theme = Theme.of(context);
  return showGeneralDialog<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: nl.scrim,
      transitionDuration: NlMotion.of(context, NlMotion.base),
      pageBuilder: (context, _, __) =>
          Theme(data: theme, child: SafeArea(child: Builder(builder: builder))),
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
            parent: animation, curve: NlMotion.ease, reverseCurve: NlMotion.exit);
        return FadeTransition(
            opacity: CurvedAnimation(
                parent: animation, curve: const Interval(0, .6)),
            child: ScaleTransition(
                scale: Tween<double>(begin: .96, end: 1).animate(curved),
                child: child));
      });
}

/// Dialog body: optional icon, title, message, custom content and actions.
/// Actions run right to left with the primary one last; on a narrow screen
/// they stack, primary first.
class NlDialog extends StatelessWidget {
  final String? title;
  final String? message;
  final Widget? icon;
  final Widget? content;
  final List<Widget> actions;
  final double width;

  const NlDialog(
      {super.key,
      this.title,
      this.message,
      this.icon,
      this.content,
      this.actions = const [],
      this.width = 420});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final screen = MediaQuery.sizeOf(context);
    final narrow = screen.width < 440;
    return Center(
        child: Padding(
            padding: const EdgeInsets.all(NlSpace.s5),
            child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: math.min(width, screen.width - 2 * NlSpace.s5)),
                child: Material(
                    type: MaterialType.transparency,
                    child: Container(
                        decoration: BoxDecoration(
                            color: nl.overlay,
                            borderRadius: BorderRadius.circular(NlRadius.r4),
                            border: nl.isDark ? Border.all(color: nl.line) : null,
                            boxShadow: nl.shadow3),
                        child: ClipRRect(
                            borderRadius: BorderRadius.circular(NlRadius.r4),
                            child: SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(NlSpace.s6,
                                    NlSpace.s6, NlSpace.s6, NlSpace.s5),
                                child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (icon != null) ...[
                                        Align(
                                            alignment: Alignment.centerLeft,
                                            child: icon!),
                                        const SizedBox(height: NlSpace.s4),
                                      ],
                                      if (title != null)
                                        Text(title!,
                                            style: NlType.text(NlType.s5,
                                                weight: FontWeight.w600,
                                                color: nl.fg)),
                                      if (message != null) ...[
                                        const SizedBox(height: NlSpace.s2),
                                        Text(message!,
                                            style: NlType.text(NlType.s3,
                                                    color: nl.fg2)
                                                .copyWith(height: 20 / 13)),
                                      ],
                                      if (content != null) ...[
                                        SizedBox(
                                            height: title == null &&
                                                    message == null
                                                ? 0
                                                : NlSpace.s4),
                                        content!,
                                      ],
                                      if (actions.isNotEmpty) ...[
                                        const SizedBox(height: NlSpace.s6),
                                        narrow
                                            ? Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                                    for (final action
                                                        in actions.reversed) ...[
                                                      action,
                                                      if (action != actions.first)
                                                        const SizedBox(
                                                            height: NlSpace.s2),
                                                    ]
                                                  ])
                                            : Wrap(
                                                alignment: WrapAlignment.end,
                                                spacing: NlSpace.s2,
                                                runSpacing: NlSpace.s2,
                                                children: actions),
                                      ],
                                    ]))))))));
  }
}

/// Asks to confirm an action; resolves true only on the confirm button.
Future<bool> nlConfirm(BuildContext context,
    {required String title,
    String? message,
    required String confirm,
    required String cancel,
    bool destructive = false,
    IconData? icon}) async {
  final nl = NlColors.of(context);
  final result = await showNlDialog<bool>(
      context: context,
      builder: (dialog) => NlDialog(
              title: title,
              message: message,
              icon: icon == null
                  ? null
                  : NlIconTile(
                      icon: icon,
                      color: destructive ? nl.danger : nl.accent,
                      size: 40),
              actions: [
                NlButton.ghost(
                    onPressed: () => Navigator.pop(dialog, false),
                    label: cancel),
                destructive
                    ? NlButton.danger(
                        autofocus: true,
                        onPressed: () => Navigator.pop(dialog, true),
                        label: confirm)
                    : NlButton(
                        autofocus: true,
                        onPressed: () => Navigator.pop(dialog, true),
                        label: confirm),
              ]));
  return result == true;
}

/// A rounded tile holding one icon in a tint of [color].
class NlIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  /// Solid tile with a white glyph instead of a soft tint.
  final bool solid;
  const NlIconTile(
      {super.key,
      required this.icon,
      required this.color,
      this.size = 28,
      this.solid = false});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            color: solid ? null : color.withOpacity(nl.isDark ? .2 : .12),
            gradient: solid
                ? LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color.lerp(color, Colors.white, .14)!, color])
                : null,
            borderRadius: BorderRadius.circular(size * .28)),
        child: Icon(icon,
            size: size * .5,
            color: solid
                ? Colors.white
                : Color.lerp(color, nl.isDark ? Colors.white : Colors.black,
                    nl.isDark ? .15 : .12)));
  }
}

/// A sheet that slides up from the bottom on a phone and appears as a
/// centred dialog on wider screens.
Future<T?> showNlSheet<T>(
    {required BuildContext context,
    required WidgetBuilder builder,
    double width = 440,
    bool dismissible = true}) {
  final compact = MediaQuery.sizeOf(context).width < NlLayout.compactMax;
  if (!compact) {
    return showNlDialog<T>(
        context: context,
        barrierDismissible: dismissible,
        builder: (context) => _SheetFrame(width: width, child: builder(context)));
  }
  final nl = NlColors.of(context);
  return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: dismissible,
      enableDrag: dismissible,
      backgroundColor: nl.overlay,
      barrierColor: nl.scrim,
      builder: (context) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  NlSpace.s5, 0, NlSpace.s5, NlSpace.s5),
              child: builder(context))));
}

class _SheetFrame extends StatelessWidget {
  final double width;
  final Widget child;
  const _SheetFrame({required this.width, required this.child});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final screen = MediaQuery.sizeOf(context);
    return Center(
        child: Padding(
            padding: const EdgeInsets.all(NlSpace.s5),
            child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: math.min(width, screen.width - 2 * NlSpace.s5),
                    maxHeight: screen.height - 2 * NlSpace.s8),
                child: Material(
                    type: MaterialType.transparency,
                    child: Container(
                        decoration: BoxDecoration(
                            color: nl.overlay,
                            borderRadius: BorderRadius.circular(NlRadius.r4),
                            border: nl.isDark ? Border.all(color: nl.line) : null,
                            boxShadow: nl.shadow3),
                        child: ClipRRect(
                            borderRadius: BorderRadius.circular(NlRadius.r4),
                            child: SingleChildScrollView(
                                padding: const EdgeInsets.all(NlSpace.s6),
                                child: child)))))));
  }
}

sealed class NlMenuEntry {
  const NlMenuEntry();
}

class NlMenuItem extends NlMenuEntry {
  final String label;
  final IconData? icon;
  final String? shortcut;
  final bool danger;
  final bool enabled;

  /// Marks the current choice of a pop-up list, such as [NlSelect]'s.
  final bool checked;
  final VoidCallback? onSelected;
  final Key? key;
  const NlMenuItem(
      {required this.label,
      this.icon,
      this.shortcut,
      this.danger = false,
      this.enabled = true,
      this.checked = false,
      this.onSelected,
      this.key});
}

class NlMenuDivider extends NlMenuEntry {
  const NlMenuDivider();
}

class NlMenuHeader extends NlMenuEntry {
  final String label;
  const NlMenuHeader(this.label);
}

/// Opens a menu next to [anchor] (a global rectangle, e.g. the button that
/// opened it) or at [position] (a right click). It scales in from the corner
/// nearest the anchor, follows the arrow keys and closes on Escape. [theme]
/// replaces the one around [context], e.g. for session chrome.
Future<void> showNlMenu(BuildContext context,
    {Rect? anchor,
    Offset? position,
    required List<NlMenuEntry> entries,
    double width = 232,
    ThemeData? theme}) async {
  assert(anchor != null || position != null);
  final rect = anchor ?? Rect.fromLTWH(position!.dx, position.dy, 0, 0);
  final navigator = Navigator.of(context, rootNavigator: true);
  final selected = await navigator.push<NlMenuItem>(_NlMenuRoute(
      anchor: rect,
      entries: entries,
      width: width,
      theme: theme ?? Theme.of(context),
      reduced: NlMotion.reduced(context),
      label: MaterialLocalizations.of(context).popupMenuLabel));
  selected?.onSelected?.call();
}

/// The global rectangle of the widget behind [context], for [showNlMenu].
Rect nlAnchorOf(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Rect.zero;
  return box.localToGlobal(Offset.zero) & box.size;
}

class _NlMenuRoute extends PopupRoute<NlMenuItem> {
  final Rect anchor;
  final List<NlMenuEntry> entries;
  final double width;
  final ThemeData theme;
  final bool reduced;
  final String label;
  _NlMenuRoute(
      {required this.anchor,
      required this.entries,
      required this.width,
      required this.theme,
      required this.reduced,
      required this.label});

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => label;
  @override
  Duration get transitionDuration =>
      reduced ? Duration.zero : const Duration(milliseconds: 160);
  @override
  Duration get reverseTransitionDuration =>
      reduced ? Duration.zero : const Duration(milliseconds: 90);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    final screen = MediaQuery.sizeOf(context);
    final below = anchor.center.dy < screen.height * .6;
    final right = anchor.center.dx > screen.width * .6;
    final menu = Theme(
        data: theme,
        child: _NlMenuPanel(entries: entries, width: width, route: this));
    return CustomSingleChildLayout(
        delegate: _MenuLayout(anchor, MediaQuery.paddingOf(context)),
        child: FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: ScaleTransition(
                alignment: Alignment(right ? 1 : -1, below ? -1 : 1),
                scale: Tween<double>(begin: .95, end: 1).animate(
                    CurvedAnimation(parent: animation, curve: NlMotion.ease)),
                child: menu)));
  }
}

class _MenuLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  final EdgeInsets padding;
  _MenuLayout(this.anchor, this.padding);

  static const _gap = 4.0;
  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest)
          .deflate(const EdgeInsets.all(_margin) + padding);

  @override
  Offset getPositionForChild(Size size, Size child) {
    final top = padding.top + _margin;
    final bottom = size.height - padding.bottom - _margin;
    var y = anchor.bottom + _gap;
    if (y + child.height > bottom) y = anchor.top - _gap - child.height;
    y = y.clamp(top, math.max(top, bottom - child.height));
    // Menus of controls on the right edge line up with the control's right
    // edge, as the scale-in origin does.
    var x = anchor.width > 0 && anchor.center.dx > size.width * .6
        ? anchor.right - child.width
        : anchor.left;
    if (x + child.width > size.width - _margin) x = anchor.left - child.width;
    x = x.clamp(_margin, math.max(_margin, size.width - _margin - child.width));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding;
}

class _NlMenuPanel extends StatelessWidget {
  final List<NlMenuEntry> entries;
  final double width;
  final _NlMenuRoute route;
  const _NlMenuPanel(
      {required this.entries, required this.width, required this.route});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    var first = true;
    return Material(
        type: MaterialType.transparency,
        child: Container(
            width: width,
            padding: const EdgeInsets.all(NlSpace.s1),
            decoration: BoxDecoration(
                color: nl.overlay,
                borderRadius: BorderRadius.circular(NlRadius.r3),
                border: nl.isDark ? Border.all(color: nl.line) : null,
                boxShadow: nl.shadow2),
            child: FocusScope(
                autofocus: true,
                child: SingleChildScrollView(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                      for (final entry in entries)
                        switch (entry) {
                          NlMenuDivider() => Padding(
                              padding: const EdgeInsets.symmetric(
                                  vertical: NlSpace.s1),
                              child: Container(height: 1, color: nl.line)),
                          NlMenuHeader(:final label) => Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  NlSpace.s2, NlSpace.s2, NlSpace.s2, NlSpace.s1),
                              child: Text(label,
                                  style: NlType.text(NlType.s1,
                                      weight: FontWeight.w500, color: nl.fg3))),
                          NlMenuItem() => () {
                              final autofocus = first && entry.enabled;
                              if (autofocus) first = false;
                              return _MenuRow(
                                  key: entry.key,
                                  item: entry,
                                  autofocus: autofocus,
                                  onTap: entry.enabled
                                      ? () => Navigator.pop(context, entry)
                                      : null);
                            }(),
                        },
                    ])))));
  }
}

class _MenuRow extends StatelessWidget {
  final NlMenuItem item;
  final bool autofocus;
  final VoidCallback? onTap;
  const _MenuRow(
      {super.key, required this.item, required this.autofocus, this.onTap});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    return NlPressable(
        onTap: onTap,
        pressScale: 1,
        selected: item.checked,
        builder: (context, states) {
          final lit = states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed);
          final enabled = onTap != null;
          final ink = !enabled
              ? nl.fg3.withOpacity(.6)
              : item.danger
                  ? nl.dangerText
                  : nl.fg;
          return Container(
              height: touch ? 40 : 30,
              padding: const EdgeInsets.symmetric(horizontal: NlSpace.s2),
              decoration: BoxDecoration(
                  color: lit && enabled
                      ? (item.danger ? nl.dangerSoft : nl.hover)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(NlRadius.r2 - 2)),
              child: Row(children: [
                if (item.icon != null) ...[
                  Icon(item.icon,
                      size: 16,
                      color: item.danger && enabled ? nl.dangerText : (enabled ? nl.fg2 : ink)),
                  const SizedBox(width: NlSpace.s2 + 2),
                ],
                Expanded(
                    child: Text(item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NlType.text(touch ? NlType.s4 : NlType.s3,
                            color: ink))),
                if (item.shortcut != null)
                  Padding(
                      padding: const EdgeInsets.only(left: NlSpace.s3),
                      child: Text(item.shortcut!,
                          style: NlType.text(NlType.s2, color: nl.fg3))),
                if (item.checked)
                  Padding(
                      padding: const EdgeInsets.only(left: NlSpace.s2),
                      child: Icon(NlIcons.check,
                          size: 15, color: enabled ? nl.accentText : ink)),
              ]));
        },
        autofocus: autofocus);
  }
}

enum NlToastTone { neutral, ok, warn, danger }

/// Short confirmations and notices: a dark capsule near the bottom of the
/// window that rises in, waits and fades away. A new toast replaces the
/// current one, which fades out underneath it.
class NlToast {
  static _Shown? _current;

  /// Returns false when [context] has no overlay to draw into.
  static bool show(BuildContext context, String message,
      {IconData? icon,
      NlToastTone tone = NlToastTone.neutral,
      Duration? duration}) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return false;
    showIn(overlay, message, icon: icon, tone: tone, duration: duration);
    return true;
  }

  /// [show] into a known overlay, for callers that hold the app's own.
  static void showIn(OverlayState overlay, String message,
      {IconData? icon,
      NlToastTone tone = NlToastTone.neutral,
      Duration? duration}) {
    dismiss();
    final reduced = NlMotion.reduced(overlay.context);
    final wait = duration ??
        Duration(milliseconds: (2200 + message.length * 30).clamp(2200, 6000));
    final key = GlobalKey<_ToastViewState>();
    late final _Shown shown;
    final entry = OverlayEntry(
        builder: (context) => _ToastView(
            key: key,
            message: message,
            icon: icon,
            tone: tone,
            reduced: reduced,
            wait: wait,
            onExpired: () {
              if (identical(_current, shown)) dismiss();
            }));
    shown = _Shown(entry, key);
    _current = shown;
    overlay.insert(entry);
  }

  static void dismiss() {
    final shown = _current;
    if (shown == null) return;
    _current = null;
    final view = shown.key.currentState;
    void remove() {
      if (shown.entry.mounted) shown.entry.remove();
    }

    if (view == null || !view.mounted) {
      remove();
    } else {
      view.leave().whenComplete(remove);
    }
  }
}

class _Shown {
  final OverlayEntry entry;
  final GlobalKey<_ToastViewState> key;
  _Shown(this.entry, this.key);
}

class _ToastView extends StatefulWidget {
  final String message;
  final IconData? icon;
  final NlToastTone tone;
  final bool reduced;
  final Duration wait;
  final VoidCallback onExpired;
  const _ToastView(
      {super.key,
      required this.message,
      required this.icon,
      required this.tone,
      required this.reduced,
      required this.wait,
      required this.onExpired});

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
      vsync: this,
      duration: widget.reduced ? Duration.zero : NlMotion.slow,
      reverseDuration:
          widget.reduced ? Duration.zero : const Duration(milliseconds: 160))
    ..forward();

  // Owned by the view, as ScaffoldMessenger owns its snack bar timer, so a
  // window that closes takes the pending dismissal with it.
  late final Timer _timer;

  Future<void> leave() {
    _timer.cancel();
    return _controller.reverse();
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.wait, widget.onExpired);
  }

  @override
  void dispose() {
    _timer.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final accent = switch (widget.tone) {
      NlToastTone.neutral => null,
      NlToastTone.ok => const Color(0xFF4ADE80),
      NlToastTone.warn => const Color(0xFFFFB340),
      NlToastTone.danger => const Color(0xFFFF7A70),
    };
    final curved = CurvedAnimation(
        parent: _controller, curve: NlMotion.ease, reverseCurve: NlMotion.exit);
    return Positioned(
        left: NlSpace.s4,
        right: NlSpace.s4,
        bottom: padding.bottom + NlSpace.s6,
        child: IgnorePointer(
            child: Center(
                child: FadeTransition(
                    opacity: curved,
                    child: SlideTransition(
                        position: Tween<Offset>(
                                begin: const Offset(0, .35), end: Offset.zero)
                            .animate(curved),
                        child: Semantics(
                            liveRegion: true,
                            child: Material(
                                type: MaterialType.transparency,
                                child: Container(
                                    constraints:
                                        const BoxConstraints(maxWidth: 520),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: NlSpace.s4,
                                        vertical: NlSpace.s3 - 1),
                                    decoration: BoxDecoration(
                                        color: const Color(0xF21D1D1F),
                                        borderRadius:
                                            BorderRadius.circular(NlRadius.r3),
                                        border: Border.all(
                                            color: const Color(0x1AFFFFFF)),
                                        boxShadow: const [
                                          BoxShadow(
                                              color: Color(0x40000000),
                                              offset: Offset(0, 10),
                                              blurRadius: 30,
                                              spreadRadius: -6),
                                        ]),
                                    child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (widget.icon != null ||
                                              accent != null) ...[
                                            Icon(
                                                widget.icon ??
                                                    switch (widget.tone) {
                                                      NlToastTone.ok =>
                                                        NlIcons.circleCheck,
                                                      NlToastTone.warn =>
                                                        NlIcons.triangleAlert,
                                                      _ => NlIcons.circleAlert,
                                                    },
                                                size: 16,
                                                color: accent ?? Colors.white),
                                            const SizedBox(width: NlSpace.s2 + 2),
                                          ],
                                          Flexible(
                                              child: Text(widget.message,
                                                  style: NlType.text(NlType.s3,
                                                          weight:
                                                              FontWeight.w500,
                                                          color: Colors.white)
                                                      .copyWith(
                                                          height: 18 / 13))),
                                        ])))))))));
  }
}
