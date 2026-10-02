import 'package:flutter/material.dart';

enum NikoToolbarTone { action, inactive, danger }

ButtonStyle _buttonStyle(BuildContext context, NikoToolbarTone tone) {
  final colors = Theme.of(context).colorScheme;
  final background = switch (tone) {
    NikoToolbarTone.action => colors.primary,
    NikoToolbarTone.inactive => colors.surfaceContainerHighest,
    NikoToolbarTone.danger => colors.error,
  };
  final foreground = switch (tone) {
    NikoToolbarTone.action => colors.onPrimary,
    NikoToolbarTone.inactive => colors.onSurfaceVariant,
    NikoToolbarTone.danger => colors.onError,
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
    NikoToolbarTone.danger => colors.onError,
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
    final content = SizedBox(
        width: width == null ? 24 : (width! - 12).clamp(24.0, double.infinity),
        height: 24, child: _icon(context, icon, tone, disabled: onPressed == null));
    final button = Semantics(
      label: label, button: true, enabled: onPressed != null, toggled: selected,
      child: Tooltip(message: label, excludeFromSemantics: true,
        child: topLevel
            ? IconButton(style: _buttonStyle(context, tone), isSelected: selected,
                onPressed: onPressed, icon: content)
            : MenuItemButton(style: _buttonStyle(context, tone),
                onPressed: onPressed, child: content),
      ),
    );
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
    child: MenuBar(children: [
      Semantics(label: label, button: true, child: Tooltip(
        message: label, excludeFromSemantics: true,
        child: SubmenuButton(
          menuStyle: menuStyle, style: _buttonStyle(context, tone),
          menuChildren: children,
          child: SizedBox(width: width == null ? 24 : (width! - 12).clamp(24.0, double.infinity),
              height: 24, child: _icon(context, icon, tone)),
        ),
      )),
    ]),
  );
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
}
