import 'package:flutter/material.dart';

import 'nightline/tokens.dart';

/// [engaged] marks a mode that is on and changes the remote side, such as
/// the privacy screen.
enum NikoToolbarTone { action, inactive, danger, engaged }

/// The Nightline dock replaces the upstream toolbar frame whenever the
/// window runs on the Nightline theme.
bool nikoDockStyled(BuildContext context) => NlColors.maybeOf(context) != null;

ButtonStyle _dockStyle(NikoToolbarTone tone, bool selected) {
  const nl = NlColors.dark;
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
    padding: const WidgetStatePropertyAll(EdgeInsets.all(NlSpace.s2)),
    shape: const WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(NlRadius.r2)))),
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return Colors.transparent;
      final lit = states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused);
      return switch (tone) {
        NikoToolbarTone.engaged => lit ? const Color(0xFF5CE6F7) : nl.accent,
        NikoToolbarTone.danger =>
          lit ? nl.danger.withOpacity(.22) : Colors.transparent,
        _ when selected => nl.accent.withOpacity(lit ? .22 : .14),
        _ => lit ? NlDock.hover : Colors.transparent,
      };
    }),
    side: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.focused)
            ? BorderSide(color: nl.accent.withOpacity(.7))
            : selected && tone != NikoToolbarTone.engaged
                ? BorderSide(color: nl.accent.withOpacity(.35))
                : BorderSide.none),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    splashFactory: NoSplash.splashFactory,
  );
}

/// Icon colour of a dock button; the dock is dark in both modes.
Color nikoDockInk(NikoToolbarTone tone, bool selected, bool disabled) {
  const nl = NlColors.dark;
  if (disabled) return nl.fg3.withOpacity(.6);
  return switch (tone) {
    NikoToolbarTone.engaged => nl.onAccent,
    NikoToolbarTone.danger => nl.dangerText,
    _ when selected => nl.accentText,
    NikoToolbarTone.inactive => nl.fg2,
    _ => nl.fg,
  };
}

ButtonStyle _buttonStyle(BuildContext context, NikoToolbarTone tone) {
  final colors = Theme.of(context).colorScheme;
  final background = switch (tone) {
    NikoToolbarTone.action => colors.primary,
    NikoToolbarTone.inactive => colors.surfaceContainerHighest,
    NikoToolbarTone.danger || NikoToolbarTone.engaged => colors.error,
  };
  final foreground = switch (tone) {
    NikoToolbarTone.action => colors.onPrimary,
    NikoToolbarTone.inactive => colors.onSurfaceVariant,
    NikoToolbarTone.danger || NikoToolbarTone.engaged => colors.onError,
  };
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(36, 36)),
    padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8))),
    foregroundColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.disabled)
            ? colors.onSurface.withOpacity(.38) : foreground),
    backgroundColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.disabled)
            ? colors.surfaceContainerHighest : background),
    overlayColor: WidgetStatePropertyAll(foreground.withOpacity(.12)),
  );
}

Widget _icon(BuildContext context, Widget icon, NikoToolbarTone tone,
    {bool disabled = false}) {
  final colors = Theme.of(context).colorScheme;
  final foreground = disabled ? colors.onSurface.withOpacity(.38) : switch (tone) {
    NikoToolbarTone.action => colors.onPrimary,
    NikoToolbarTone.inactive => colors.onSurfaceVariant,
    NikoToolbarTone.danger || NikoToolbarTone.engaged => colors.onError,
  };
  return ExcludeSemantics(child: ColorFiltered(
      colorFilter: ColorFilter.mode(foreground, BlendMode.srcIn), child: icon));
}

class NikoToolbarButton extends StatelessWidget {
  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final NikoToolbarTone tone;
  final bool? selected;
  final bool topLevel;
  final double? width;

  const NikoToolbarButton({super.key, required this.icon, required this.label,
      required this.onPressed, this.tone = NikoToolbarTone.action,
      this.selected, this.topLevel = true, this.width});

  @override
  Widget build(BuildContext context) {
    final dock = nikoDockStyled(context);
    final glyph = dock
        ? ExcludeSemantics(child: ColorFiltered(
            colorFilter: ColorFilter.mode(
                nikoDockInk(tone, selected == true, onPressed == null),
                BlendMode.srcIn),
            child: icon))
        : _icon(context, icon, tone, disabled: onPressed == null);
    final style =
        dock ? _dockStyle(tone, selected == true) : _buttonStyle(context, tone);
    final content = SizedBox(
        width: width == null ? 24 : (width! - 12).clamp(24.0, double.infinity),
        height: 24, child: glyph);
    final button = Semantics(
      label: label, button: true, enabled: onPressed != null, toggled: selected,
      child: Tooltip(message: label, excludeFromSemantics: true,
        child: topLevel
            ? IconButton(style: style, isSelected: selected,
                onPressed: onPressed, icon: content)
            : MenuItemButton(style: style,
                onPressed: onPressed, child: content),
      ),
    );
    return Padding(
        padding: dock
            ? const EdgeInsets.all(1)
            : const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: button);
  }
}

class NikoToolbarMenu extends StatelessWidget {
  final Widget icon;
  final String label;
  final List<Widget> children;
  final MenuStyle? menuStyle;
  final NikoToolbarTone tone;
  final double? width;

  const NikoToolbarMenu({super.key, required this.icon, required this.label,
      required this.children, this.menuStyle, this.tone = NikoToolbarTone.action,
      this.width});

  @override
  Widget build(BuildContext context) {
    final dock = nikoDockStyled(context);
    return Padding(
    padding: dock
        ? const EdgeInsets.all(1)
        : const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
    child: MenuBar(
      style: dock
          ? const MenuStyle(
              backgroundColor: WidgetStatePropertyAll(Colors.transparent),
              elevation: WidgetStatePropertyAll(0),
              padding: WidgetStatePropertyAll(EdgeInsets.zero))
          : null,
      children: [
      Semantics(label: label, button: true, child: Tooltip(
        message: label, excludeFromSemantics: true,
        child: SubmenuButton(
          menuStyle: menuStyle,
          style: dock ? _dockStyle(tone, false) : _buttonStyle(context, tone),
          menuChildren: children,
          child: SizedBox(width: width == null ? 24 : (width! - 12).clamp(24.0, double.infinity),
              height: 24,
              child: dock
                  ? ExcludeSemantics(child: ColorFiltered(
                      colorFilter: ColorFilter.mode(
                          nikoDockInk(tone, false, false), BlendMode.srcIn),
                      child: icon))
                  : _icon(context, icon, tone)),
        ),
      )),
    ]),
  );
  }
}

class NikoSessionToolbar extends StatelessWidget {
  final Axis direction;
  final List<Widget> actions;
  final Widget endSession;

  const NikoSessionToolbar({super.key, required this.direction,
      required this.actions, required this.endSession});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final size = MediaQuery.sizeOf(context);
    final horizontal = direction == Axis.horizontal;
    if (nikoDockStyled(context)) return _dock(constraints, size, horizontal);
    return ConstrainedBox(
      constraints: horizontal
          ? BoxConstraints(maxWidth: constraints.hasBoundedWidth ? constraints.maxWidth : size.width)
          : BoxConstraints(maxHeight: constraints.hasBoundedHeight ? constraints.maxHeight : size.height),
      child: Flex(direction: direction, mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: SingleChildScrollView(
          key: const Key('nikodesk-session-toolbar-scroll'),
          scrollDirection: direction,
          child: Flex(direction: direction, mainAxisSize: MainAxisSize.min, children: actions),
        )),
        SizedBox(width: horizontal ? 8 : 24, height: horizontal ? 24 : 8,
            child: horizontal ? const VerticalDivider(width: 8) : const Divider(height: 8)),
        endSession,
      ]),
    );
  });

  /// The Nightline dock: dark glass panel, hairline separators, shadow 3.
  Widget _dock(BoxConstraints constraints, Size size, bool horizontal) =>
      ConstrainedBox(
        constraints: horizontal
            ? BoxConstraints(maxWidth: constraints.hasBoundedWidth ? constraints.maxWidth : size.width)
            : BoxConstraints(maxHeight: constraints.hasBoundedHeight ? constraints.maxHeight : size.height),
        child: DecoratedBox(
          key: const Key('nikodesk-session-dock'),
          decoration: BoxDecoration(
              color: NlDock.background,
              borderRadius: BorderRadius.circular(NlRadius.r3),
              border: Border.all(color: NlDock.line),
              boxShadow: NlColors.dark.shadow3),
          child: Padding(
            padding: const EdgeInsets.all(NlSpace.s1),
            child: Flex(direction: direction, mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: SingleChildScrollView(
                key: const Key('nikodesk-session-toolbar-scroll'),
                scrollDirection: direction,
                child: Flex(direction: direction, mainAxisSize: MainAxisSize.min, children: actions),
              )),
              Container(
                  width: horizontal ? 1 : 24,
                  height: horizontal ? 24 : 1,
                  margin: EdgeInsets.symmetric(
                      horizontal: horizontal ? NlSpace.s1 : 0,
                      vertical: horizontal ? 0 : NlSpace.s1),
                  color: NlDock.separator),
              endSession,
            ]),
          ),
        ),
      );
}
