import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart'
    show startDragging, setMovable, toggleMaximize;

import 'home_board.dart';
import 'nightline.dart';
import 'ui.dart';

/// Width of the macOS traffic lights plus their margins, kept clear on the
/// left of whatever sits under them.
const double nikoTrafficLightsWidth = 78;

/// Height of the strip the macOS traffic lights sit in.
const double nikoTitleStripHeight = 28;

class NikoHomeDestination {
  final IconData icon;
  final String label;
  final String? count;
  const NikoHomeDestination(
      {required this.icon, required this.label, this.count});
}

/// What the frame tells the pages inside it: the control that opens the
/// navigation when the sidebar is hidden, and how far a page header must
/// stay clear of the traffic lights.
class NikoHomeFrame extends InheritedWidget {
  final Widget? leading;
  final double insetLeft;
  final bool macTitleBar;
  final bool phone;

  const NikoHomeFrame(
      {super.key,
      required super.child,
      this.leading,
      this.insetLeft = 0,
      this.macTitleBar = false,
      this.phone = false});

  static NikoHomeFrame? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NikoHomeFrame>();

  @override
  bool updateShouldNotify(NikoHomeFrame oldWidget) =>
      leading != oldWidget.leading ||
      insetLeft != oldWidget.insetLeft ||
      macTitleBar != oldWidget.macTitleBar ||
      phone != oldWidget.phone;
}

/// Drags the window from empty space and zooms it on a double click, as a
/// macOS title bar does. Outside a native macOS home it is a plain child.
class NikoWindowDrag extends StatefulWidget {
  final Widget child;
  const NikoWindowDrag({super.key, required this.child});

  @override
  State<NikoWindowDrag> createState() => _NikoWindowDragState();
}

class _NikoWindowDragState extends State<NikoWindowDrag> {
  int _lastTap = 0;

  @override
  Widget build(BuildContext context) {
    if (NikoHomeFrame.maybeOf(context)?.macTitleBar != true) {
      return widget.child;
    }
    // A double-tap recognizer would hold every tap on the buttons inside
    // until it timed out, so the second click is timed by hand.
    return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastTap < 500) toggleMaximize(true);
          _lastTap = now;
        },
        onPanStart: (_) => startDragging(true),
        onPanCancel: () => setMovable(true, false),
        onPanEnd: (_) => setMovable(true, false),
        child: widget.child);
  }
}

/// The macOS title strip on its own, for full-window pages outside the home
/// chrome: room for the traffic lights and a handle to drag the window by.
class NikoTitleStrip extends StatelessWidget {
  final Widget child;
  final bool enabled;
  const NikoTitleStrip({super.key, required this.child, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return ColoredBox(
        color: NlColors.of(context).page,
        child: Column(children: [
          const NikoHomeFrame(
              macTitleBar: true,
              child: NikoWindowDrag(
                  child: SizedBox(
                      height: nikoTitleStripHeight, width: double.infinity))),
          Expanded(child: child),
        ]));
  }
}

/// Page header shared by every home destination: the frame's navigation
/// control, a title with an optional subtitle and actions on the right. The
/// hairline under it appears once the page below has scrolled.
class NikoPageBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final bool divider;

  const NikoPageBar(
      {super.key,
      required this.title,
      this.subtitle,
      this.actions = const [],
      this.divider = false});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final frame = NikoHomeFrame.maybeOf(context);
    final phone = frame?.phone == true;
    final leading = frame?.leading;
    final heading = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
              header: true,
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NlType.text(phone ? NlType.s6 : NlType.s5,
                      weight: FontWeight.w600, color: nl.fg))),
          if (subtitle != null)
            Text(subtitle!,
                maxLines: phone ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: NlType.text(NlType.s2, color: nl.fg3)),
        ]);
    return NikoWindowDrag(
        child: LayoutBuilder(builder: (context, constraints) {
      final side =
          constraints.maxWidth < NlLayout.compactMax ? NlSpace.s4 : NlSpace.s6;
      return AnimatedContainer(
          duration: NlMotion.of(context, NlMotion.base),
          constraints: BoxConstraints(minHeight: phone ? 56 : 52),
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.fromLTRB(
              (frame?.insetLeft ?? 0) + (leading == null ? side : NlSpace.s3),
              NlSpace.s2,
              side - NlSpace.s1,
              NlSpace.s2),
          decoration: BoxDecoration(
              color: nl.bg,
              border: Border(
                  bottom: BorderSide(
                      color: divider ? nl.line : nl.line.withOpacity(0)))),
          // Actions wrap under the title when they would squeeze it out,
          // as on phones or at large text sizes.
          child: SizedBox(
              width: double.infinity,
              child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: NlSpace.s3,
              runSpacing: NlSpace.s2,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (leading != null) ...[
                    leading,
                    const SizedBox(width: NlSpace.s2),
                  ],
                  Flexible(child: heading),
                ]),
                if (actions.isNotEmpty)
                  Wrap(
                      spacing: NlSpace.s2,
                      runSpacing: NlSpace.s2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: actions),
              ])));
    }));
  }
}

/// Window frame of the home: a source-list sidebar beside the page on wide
/// windows, a drawer on narrow pointer windows and a tab bar on phones.
class NikoHomeChrome extends StatefulWidget {
  final List<NikoHomeDestination> destinations;
  final int selected;
  final ValueChanged<int> onSelect;
  final Widget body;

  /// Sidebar sections after the destinations, e.g. favourites and groups.
  final List<Widget> sections;
  final Widget? footer;

  /// Extra content at the end of the narrow-window drawer.
  final Widget? drawerExtra;
  final VoidCallback? onQuickConnect;
  final VoidCallback? onSearch;
  final String quickConnectShortcut;
  final String searchShortcut;
  final bool macTitleBar;

  /// Touch platforms: a tab bar instead of a drawer on narrow screens.
  final bool touch;

  const NikoHomeChrome(
      {super.key,
      required this.destinations,
      required this.selected,
      required this.onSelect,
      required this.body,
      this.sections = const [],
      this.footer,
      this.drawerExtra,
      this.onQuickConnect,
      this.onSearch,
      this.quickConnectShortcut = '',
      this.searchShortcut = '',
      this.macTitleBar = false,
      this.touch = false});

  @override
  State<NikoHomeChrome> createState() => _NikoHomeChromeState();
}

class _NikoHomeChromeState extends State<NikoHomeChrome> {
  final _scaffold = GlobalKey<ScaffoldState>();
  bool _open = true;

  void _closeDrawer() => _scaffold.currentState?.closeDrawer();

  Widget _sidebar(NlColors nl, {required bool drawer}) {
    final touch = widget.touch;
    final toggle = drawer
        ? null
        : NlIconButton(
            icon: NlIcons.panelLeftClose,
            tooltip: nikoText('隐藏侧边栏', 'Hide sidebar'),
            onPressed: () => setState(() => _open = false));
    void pick(VoidCallback action) {
      if (drawer) _closeDrawer();
      action();
    }

    return NlSidebar(
        width: drawer ? 300 : (touch ? 300 : 252),
        header: NikoWindowDrag(
            child: Padding(
                padding: EdgeInsets.fromLTRB(
                    NlSpace.s3,
                    drawer
                        ? NlSpace.s3
                        : MediaQuery.paddingOf(context).top +
                            (touch ? NlSpace.s2 : 0),
                    NlSpace.s2,
                    NlSpace.s2),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.macTitleBar && !drawer)
                        SizedBox(
                            height: nikoTitleStripHeight + 4,
                            child: Row(children: [
                              const Spacer(),
                              if (toggle != null) toggle,
                            ])),
                      SizedBox(
                          height: touch ? 48 : 40,
                          child: Row(children: [
                            const SizedBox(width: NlSpace.s1),
                            NlMark(size: touch ? 26 : 22),
                            const SizedBox(width: NlSpace.s2 + 2),
                            Expanded(
                                child: Text('NikoDesk',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: NlType.text(
                                        touch ? NlType.s5 : NlType.s4,
                                        weight: FontWeight.w600,
                                        color: nl.fg))),
                            if (!widget.macTitleBar && toggle != null) toggle,
                          ])),
                      const SizedBox(height: NlSpace.s2),
                      if (widget.onQuickConnect != null)
                        _PrimaryRow(
                            label: nikoText('快速连接', 'Quick connect'),
                            shortcut: widget.quickConnectShortcut,
                            onTap: () => pick(widget.onQuickConnect!)),
                      if (widget.onSearch != null)
                        NlSidebarItem(
                            icon: NlIcons.search,
                            label: nikoText('搜索与命令', 'Search and commands'),
                            trailing: widget.searchShortcut.isEmpty
                                ? null
                                : NlKbd(widget.searchShortcut),
                            onTap: () => pick(widget.onSearch!)),
                    ]))),
        footer: widget.footer == null
            ? null
            : SafeArea(top: false, right: false, child: widget.footer!),
        children: [
          NlSidebarSection(children: [
            for (var i = 0; i < widget.destinations.length; i++)
              NlSidebarItem(
                  icon: widget.destinations[i].icon,
                  label: widget.destinations[i].label,
                  count: widget.destinations[i].count,
                  selected: i == widget.selected,
                  onTap: () => pick(() => widget.onSelect(i))),
          ]),
          ...widget.sections,
          if (drawer && widget.drawerExtra != null)
            Padding(
                padding: const EdgeInsets.fromLTRB(
                    NlSpace.s2, NlSpace.s2, NlSpace.s2, NlSpace.s4),
                child: widget.drawerExtra),
        ]);
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(1);
      final compact =
          constraints.maxWidth < 840 || constraints.maxWidth / scale < 640;
      if (compact && widget.touch) {
        return NikoHomeFrame(
            phone: true,
            child: ColoredBox(
                color: nl.bg,
                child: Column(children: [
                  Expanded(
                      child: SafeArea(bottom: false, child: widget.body)),
                  NlTabBar(
                      items: [
                        for (final destination in widget.destinations)
                          NlTabItem(
                              icon: destination.icon, label: destination.label),
                      ],
                      index: widget.selected,
                      onChanged: widget.onSelect),
                ])));
      }
      if (compact) {
        return Scaffold(
            key: _scaffold,
            backgroundColor: nl.bg,
            drawer: Drawer(
                width: 300,
                backgroundColor: nl.bg2,
                shape: const RoundedRectangleBorder(),
                child: SafeArea(child: _sidebar(nl, drawer: true))),
            body: NikoHomeFrame(
                macTitleBar: widget.macTitleBar,
                insetLeft: widget.macTitleBar ? nikoTrafficLightsWidth : 0,
                leading: NlIconButton(
                    icon: NlIcons.panelLeftOpen,
                    tooltip: nikoText('打开导航', 'Open navigation'),
                    onPressed: () => _scaffold.currentState?.openDrawer()),
                child: widget.body));
      }
      final closed = !_open;
      return ColoredBox(
          color: nl.bg,
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            NlSidePanel(
                open: _open,
                left: true,
                width: widget.touch ? 300 : 252,
                child: _sidebar(nl, drawer: false)),
            Expanded(
                child: NikoHomeFrame(
                    macTitleBar: widget.macTitleBar,
                    insetLeft: closed && widget.macTitleBar
                        ? nikoTrafficLightsWidth
                        : 0,
                    leading: closed
                        ? NlIconButton(
                            icon: NlIcons.panelLeftOpen,
                            tooltip: nikoText('显示侧边栏', 'Show sidebar'),
                            onPressed: () => setState(() => _open = true))
                        : null,
                    child: SafeArea(
                        left: closed, bottom: false, child: widget.body))),
          ]));
    });
  }
}

/// The sidebar's one accent row, like a "new" action in a source list.
class _PrimaryRow extends StatelessWidget {
  final String label;
  final String shortcut;
  final VoidCallback onTap;
  const _PrimaryRow(
      {required this.label, required this.shortcut, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    return NlPressable(
        onTap: onTap,
        pressScale: .98,
        builder: (context, states) {
          final hovered = states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.pressed);
          return AnimatedContainer(
              duration: NlMotion.of(context, NlMotion.instant),
              height: touch ? 44 : 32,
              margin: const EdgeInsets.only(bottom: 2),
              padding: const EdgeInsets.symmetric(horizontal: NlSpace.s2),
              decoration: BoxDecoration(
                  color: hovered ? nl.hover : Colors.transparent,
                  borderRadius: BorderRadius.circular(NlRadius.r2),
                  boxShadow: states.contains(WidgetState.focused)
                      ? nl.focusRing
                      : null),
              child: Row(children: [
                Container(
                    width: touch ? 24 : 20,
                    height: touch ? 24 : 20,
                    decoration: BoxDecoration(
                        color: hovered ? nl.accentHover : nl.accentFill,
                        shape: BoxShape.circle),
                    child: Icon(NlIcons.zap,
                        size: touch ? 13 : 11, color: nl.onAccent)),
                const SizedBox(width: NlSpace.s2 + 2),
                Expanded(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NlType.text(touch ? NlType.s4 : NlType.s3,
                            weight: FontWeight.w500, color: nl.fg))),
                if (shortcut.isNotEmpty) NlKbd(shortcut),
              ]));
        });
  }
}

/// "⌘" on Apple platforms, "Ctrl " elsewhere, for shortcut hints.
String nikoShortcut(String key) =>
    Platform.isMacOS || Platform.isIOS ? '⌘$key' : 'Ctrl $key';

/// Palette commands every home offers: quick connect, adding a device and
/// one entry per saved device. [onDevices] shows the device page before
/// handing it the request.
List<NlCommand> nikoDeviceCommands(NikoDeviceBoard board,
    {required void Function(bool Function() request) onDevices}) {
  final actions = nikoText('操作', 'Actions');
  return [
    NlCommand(
        title: nikoText('快速连接', 'Quick connect'),
        icon: NlIcons.zap,
        group: actions,
        shortcut: nikoShortcut('N'),
        keywords: const ['connect', 'id', '连接'],
        run: () => onDevices(board.requestQuickConnect)),
    NlCommand(
        title: nikoText('添加设备', 'Add device'),
        icon: NlIcons.plus,
        group: actions,
        run: () => onDevices(board.requestAddDevice)),
    for (final device in board.devices)
      NlCommand(
          title: device.title,
          subtitle: nikoGroupedId(device.id),
          leading: NlDeviceGlyph(
              id: device.id, size: 20, online: board.online[device.id]),
          group: nikoText('连接设备', 'Connect to'),
          keywords: [device.id, device.group],
          run: () => onDevices(() => board.requestConnect(device.id))),
  ];
}

/// Favourites and groups from [board] as sidebar sections. [onDevices]
/// shows the device page before handing it the request.
List<Widget> nikoBoardSections(BuildContext context, NikoDeviceBoard board,
    {required bool devicesShown,
    required void Function(bool Function() request) onDevices}) {
  final favorites = board.favorites;
  final groups = board.groups;
  final online = board.online;
  return [
    if (favorites.isNotEmpty)
      NlSidebarSection(title: nikoText('收藏', 'Favorites'), children: [
        for (final device in favorites.take(8))
          NlSidebarItem(
              leading: _NikoPresenceDot(online: online[device.id]),
              label: device.title,
              tooltip: '${device.title} · ${nikoGroupedId(device.id)}',
              onTap: () => onDevices(() {
                    board.select(device.id);
                    return true;
                  }),
              onContextMenu: (at) => showNlMenu(context, position: at, entries: [
                    NlMenuItem(
                        label: nikoText('远程控制', 'Remote control'),
                        icon: NlIcons.monitor,
                        enabled: board.canConnect,
                        onSelected: () =>
                            onDevices(() => board.requestConnect(device.id))),
                    NlMenuItem(
                        label: nikoText('文件传输', 'File transfer'),
                        icon: NlIcons.folder,
                        enabled: board.canConnect,
                        onSelected: () => onDevices(() =>
                            board.requestConnect(device.id, fileTransfer: true))),
                  ])),
      ]),
    if (groups.isNotEmpty)
      NlSidebarSection(title: nikoText('分组', 'Groups'), children: [
        for (final entry in groups.entries)
          NlSidebarItem(
              icon: NlIcons.tag,
              label: entry.key,
              count: '${entry.value}',
              selected: devicesShown && board.filter == 'group:${entry.key}',
              onTap: () {
                final filter = 'group:${entry.key}';
                board.filter =
                    board.filter == filter && devicesShown ? 'all' : filter;
                onDevices(() => true);
              }),
      ]),
  ];
}

class _NikoPresenceDot extends StatelessWidget {
  final bool? online;
  const _NikoPresenceDot({required this.online});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: online == true ? nl.ok : Colors.transparent,
            border: online == true
                ? null
                : Border.all(
                    color: online == false ? nl.fg3 : nl.line2, width: 1.2)));
  }
}
