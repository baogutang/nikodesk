import 'package:flutter/material.dart';

import 'components.dart';
import 'tokens.dart';

/// Source-list sidebar: a fixed header, scrolling sections and a footer.
class NlSidebar extends StatelessWidget {
  final Widget? header;
  final List<Widget> children;
  final Widget? footer;
  final double width;

  const NlSidebar(
      {super.key,
      this.header,
      required this.children,
      this.footer,
      this.width = 248});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Container(
        width: width,
        // The sidebar sits on the window canvas itself; the page beside it
        // separates by its raised surfaces, not by a rule.
        color: nl.bg2,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (header != null) header!,
          Expanded(
              child: FocusTraversalGroup(
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(
                          NlSpace.s2, NlSpace.s1, NlSpace.s2, NlSpace.s3),
                      children: children))),
          if (footer != null) footer!,
        ]));
  }
}

/// A titled group of [NlSidebarItem]s.
class NlSidebarSection extends StatelessWidget {
  final String? title;
  final Widget? action;
  final List<Widget> children;
  const NlSidebarSection(
      {super.key, this.title, this.action, required this.children});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Padding(
        padding: const EdgeInsets.only(bottom: NlSpace.s3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (title != null)
            Padding(
                padding: const EdgeInsets.fromLTRB(
                    NlSpace.s2 + 2, NlSpace.s2, NlSpace.s1, NlSpace.s1),
                child: SizedBox(
                    height: 20,
                    child: Row(children: [
                      Expanded(
                          child: Text(title!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NlType.text(NlType.s1,
                                  weight: FontWeight.w500, color: nl.fg3))),
                      if (action != null) action!,
                    ]))),
          ...children,
        ]));
  }
}

/// One sidebar row: an icon or [leading] mark, the label and an optional
/// count. Selected rows carry a neutral wash and a medium label.
class NlSidebarItem extends StatelessWidget {
  final IconData? icon;
  final Widget? leading;
  final String label;
  final String? count;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onContextMenu;
  final String? tooltip;

  const NlSidebarItem(
      {super.key,
      this.icon,
      this.leading,
      required this.label,
      this.count,
      this.trailing,
      this.selected = false,
      this.onTap,
      this.onContextMenu,
      this.tooltip});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    final item = NlPressable(
        onTap: onTap,
        onContextMenu: onContextMenu,
        selected: selected,
        pressScale: 1,
        builder: (context, states) {
          final hovered = states.contains(WidgetState.hovered);
          final pressed = states.contains(WidgetState.pressed);
          // The current place is a raised chip on the canvas, its icon in
          // the accent; other rows only wash on hover.
          return AnimatedContainer(
              duration: NlMotion.of(context, NlMotion.instant),
              height: touch ? 44 : 36,
              margin: const EdgeInsets.only(bottom: 2),
              padding: const EdgeInsets.symmetric(horizontal: NlSpace.s3),
              decoration: BoxDecoration(
                  color: selected
                      ? nl.surface
                      : pressed
                          ? nl.selected
                          : hovered
                              ? nl.hover
                              : Colors.transparent,
                  borderRadius: BorderRadius.circular(NlRadius.r2),
                  border: Border.all(
                      color: selected ? nl.ring : Colors.transparent),
                  boxShadow: states.contains(WidgetState.focused)
                      ? nl.focusRing
                      : selected
                          ? nl.shadow1
                          : null),
              child: Row(children: [
                if (leading != null)
                  SizedBox(width: 18, child: Center(child: leading))
                else if (icon != null)
                  Icon(icon,
                      size: touch ? 20 : 18,
                      color: selected ? nl.accentText : nl.fg2),
                if (leading != null || icon != null)
                  const SizedBox(width: NlSpace.s2 + 2),
                Expanded(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NlType.text(touch ? NlType.s5 : NlType.s4,
                            weight: selected ? FontWeight.w600 : FontWeight.w400,
                            color: selected || hovered ? nl.fg : nl.fg2))),
                if (count != null)
                  Text(count!,
                      style: NlType.monoText(NlType.s1,
                          color: selected ? nl.fg2 : nl.fg3)),
                if (trailing != null) trailing!,
              ]));
        });
    return tooltip == null
        ? item
        : Tooltip(message: tooltip!, excludeFromSemantics: true, child: item);
  }
}

/// Page header: title, optional subtitle and leading control, actions on
/// the right. The hairline under it appears once the page scrolls.
class NlPageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final bool divider;
  final double height;
  final EdgeInsetsGeometry padding;

  const NlPageHeader(
      {super.key,
      required this.title,
      this.subtitle,
      this.leading,
      this.actions = const [],
      this.divider = false,
      this.height = 52,
      this.padding = const EdgeInsets.symmetric(horizontal: NlSpace.s6)});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return AnimatedContainer(
        duration: NlMotion.of(context, NlMotion.base),
        height: height,
        padding: padding,
        decoration: BoxDecoration(
            color: nl.bg,
            border: Border(
                bottom: BorderSide(
                    color: divider ? nl.line : nl.line.withOpacity(0)))),
        child: Row(children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: NlSpace.s2),
          ],
          Expanded(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Semantics(
                    header: true,
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NlType.text(NlType.s5,
                            weight: FontWeight.w600, color: nl.fg))),
                if (subtitle != null)
                  Text(subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NlType.text(NlType.s2, color: nl.fg3)),
              ])),
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: NlSpace.s2),
            actions[i],
          ],
        ]));
  }
}

/// Reports whether its scrollable child has scrolled off the top, for a
/// [NlPageHeader] divider.
class NlScrollWatcher extends StatefulWidget {
  final Widget Function(BuildContext context, bool scrolled) header;
  final Widget child;
  const NlScrollWatcher({super.key, required this.header, required this.child});

  @override
  State<NlScrollWatcher> createState() => _NlScrollWatcherState();
}

class _NlScrollWatcherState extends State<NlScrollWatcher> {
  bool _scrolled = false;

  @override
  Widget build(BuildContext context) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            widget.header(context, _scrolled),
            Expanded(
                child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification.depth == 0) {
                        final scrolled = notification.metrics.pixels >
                            notification.metrics.minScrollExtent + .5;
                        if (scrolled != _scrolled) {
                          setState(() => _scrolled = scrolled);
                        }
                      }
                      return false;
                    },
                    child: widget.child)),
          ]);
}

class NlTabItem {
  final IconData icon;
  final String label;
  final Key? key;
  const NlTabItem({required this.icon, required this.label, this.key});
}

/// Bottom tab bar for phones.
class NlTabBar extends StatelessWidget {
  final List<NlTabItem> items;
  final int index;
  final ValueChanged<int> onChanged;
  const NlTabBar(
      {super.key,
      required this.items,
      required this.index,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
        padding: EdgeInsets.only(bottom: bottom),
        decoration: BoxDecoration(
            color: nl.bg2, border: Border(top: BorderSide(color: nl.line))),
        child: SizedBox(
            height: 52,
            child: Row(children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                    child: NlPressable(
                        key: items[i].key,
                        onTap: () => onChanged(i),
                        selected: i == index,
                        pressScale: .92,
                        builder: (context, states) {
                          final ink = i == index ? nl.accentText : nl.fg3;
                          return Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(items[i].icon, size: 22, color: ink),
                                const SizedBox(height: 3),
                                Text(items[i].label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: NlType.text(10,
                                            weight: FontWeight.w500, color: ink)
                                        .copyWith(height: 1.2)),
                              ]);
                        })),
            ])));
  }
}

/// A side panel that slides open to [width] and closed to nothing. The
/// child keeps its full width while the panel animates, so nothing reflows
/// inside it; a closed panel leaves focus and semantics.
class NlSidePanel extends StatelessWidget {
  final bool open;
  final double width;
  final Widget child;

  /// The edge the panel is attached to.
  final bool left;

  const NlSidePanel(
      {super.key,
      required this.open,
      required this.width,
      required this.child,
      this.left = false});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
      tween: Tween(end: open ? 1 : 0),
      duration: NlMotion.of(context, NlMotion.slow),
      curve: NlMotion.ease,
      child: child,
      builder: (context, t, child) {
        if (t == 0) return const SizedBox.shrink();
        return SizedBox(
            width: width * t,
            child: ClipRect(
                child: OverflowBox(
                    alignment: left ? Alignment.centerRight : Alignment.centerLeft,
                    minWidth: width,
                    maxWidth: width,
                    child: ExcludeFocus(
                        excluding: !open,
                        child: Opacity(opacity: t.clamp(0, 1), child: child)))));
      });
}
