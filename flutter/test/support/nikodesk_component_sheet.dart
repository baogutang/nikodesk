// The design-system component sheet rendered by
// test/nightline_screenshots_test.dart for visual review.
import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';

class NikoComponentSheet extends StatefulWidget {
  const NikoComponentSheet({super.key});

  /// The device card whose menu the screenshot opens.
  static const menuKey = Key('sheet-device-menu');

  @override
  State<NikoComponentSheet> createState() => _NikoComponentSheetState();
}

class _NikoComponentSheetState extends State<NikoComponentSheet> {
  String _filter = 'online';
  String _view = 'grid';
  String _quality = 'balanced';
  final _chips = {'Screen': true, 'Input': true, 'Files': false, 'Audio': true};
  final _switches = {'Force relay': false, 'Remember password': true};
  final _search = TextEditingController(text: '');
  final _id = TextEditingController(text: '418 223 905');
  final _password = TextEditingController(text: 'k7x2m9qa');
  final _wrong = TextEditingController(text: '418 22');
  final _focused = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focused.requestFocus());
  }

  @override
  void dispose() {
    _search.dispose();
    _id.dispose();
    _password.dispose();
    _wrong.dispose();
    _focused.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final presetName = nl.preset == NlPreset.orbit ? 'Orbit' : 'Clay';
    return ColoredBox(
        color: nl.bg,
        child: Padding(
            padding: const EdgeInsets.fromLTRB(
                NlSpace.s10, NlSpace.s8, NlSpace.s10, NlSpace.s8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    const NlMark(size: 40),
                    const SizedBox(width: NlSpace.s3),
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('NikoDesk design system',
                              style: NlType.text(NlType.s6,
                                  weight: FontWeight.w600, color: nl.fg)),
                          Text(
                              '$presetName · ${nl.isDark ? 'Dark' : 'Light'} · '
                              'UI 2.1',
                              style: NlType.text(NlType.s3, color: nl.fg3)),
                        ]),
                    const Spacer(),
                    const NlBadge('Preview', tone: NlTone.accent),
                  ]),
                  const SizedBox(height: NlSpace.s8),
                  Expanded(
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Expanded(flex: 10, child: _controls(nl)),
                        const SizedBox(width: NlSpace.s10),
                        Expanded(flex: 11, child: _content(nl)),
                        const SizedBox(width: NlSpace.s10),
                        Expanded(flex: 10, child: _surfaces(nl)),
                      ])),
                ])));
  }

  Widget _section(String label, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: NlSpace.s6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        NlSectionLabel(label),
        child,
      ]));

  Widget _controls(NlColors nl) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _section(
                'Buttons',
                Wrap(spacing: NlSpace.s2, runSpacing: NlSpace.s2, children: [
                  NlButton(
                      onPressed: () {},
                      icon: NlIcons.cable,
                      label: 'Connect',
                      shortcut: '⏎'),
                  NlButton.ghost(
                      onPressed: () {}, label: 'Cancel', shortcut: 'esc'),
                  NlButton.quiet(onPressed: () {}, label: 'Details'),
                  NlButton.danger(onPressed: () {}, label: 'End session'),
                  const NlButton(onPressed: null, label: 'Disabled'),
                  // Spinners freeze so the screenshot can settle.
                  TickerMode(
                      enabled: false,
                      child: NlButton.ghost(
                          onPressed: () {}, loading: true, label: 'Connecting')),
                ])),
            _section(
                'Sizes and icon buttons',
                Wrap(
                    spacing: NlSpace.s2,
                    runSpacing: NlSpace.s2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      NlButton(
                          large: true,
                          onPressed: () {},
                          icon: NlIcons.arrowRight,
                          label: 'Continue'),
                      NlButton.ghost(
                          small: true,
                          onPressed: () {},
                          icon: NlIcons.keyRound,
                          label: 'Password'),
                      NlIconButton(
                          icon: NlIcons.copy, tooltip: 'Copy', onPressed: () {}),
                      NlIconButton(
                          icon: NlIcons.ellipsis,
                          tooltip: 'More',
                          active: true,
                          onPressed: () {}),
                      NlIconButton(
                          icon: NlIcons.settings,
                          tooltip: 'Settings',
                          outlined: true,
                          onPressed: () {}),
                    ])),
            _section(
                'Segmented controls',
                Wrap(spacing: NlSpace.s3, runSpacing: NlSpace.s3, children: [
                  NlSegmented<String>(
                      segments: const [
                        NlSegment(value: 'all', label: 'All', count: '8'),
                        NlSegment(value: 'online', label: 'Online', count: '5'),
                        NlSegment(value: 'fav', label: 'Starred', count: '3'),
                      ],
                      selected: _filter,
                      onChanged: (value) => setState(() => _filter = value)),
                  NlSegmented<String>(
                      segments: const [
                        NlSegment(
                            value: 'grid',
                            label: 'Grid',
                            icon: NlIcons.layoutGrid,
                            iconOnly: true),
                        NlSegment(
                            value: 'list',
                            label: 'List',
                            icon: NlIcons.list,
                            iconOnly: true),
                      ],
                      selected: _view,
                      onChanged: (value) => setState(() => _view = value)),
                  NlSegmented<String>(
                      small: true,
                      segments: const [
                        NlSegment(value: 'speed', label: 'Speed'),
                        NlSegment(value: 'balanced', label: 'Balanced'),
                        NlSegment(value: 'quality', label: 'Quality'),
                      ],
                      selected: _quality,
                      onChanged: (value) => setState(() => _quality = value)),
                ])),
            _section(
                'Chips and switches',
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: NlSpace.s2, runSpacing: NlSpace.s2, children: [
                    for (final entry in _chips.entries)
                      NlChip(
                          label: entry.key,
                          icon: entry.value ? NlIcons.check : null,
                          selected: entry.value,
                          strikeWhenOff: true,
                          onChanged: (value) =>
                              setState(() => _chips[entry.key] = value)),
                  ]),
                  const SizedBox(height: NlSpace.s4),
                  Wrap(spacing: NlSpace.s6, runSpacing: NlSpace.s2, children: [
                    for (final entry in _switches.entries)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        NlSwitch(
                            value: entry.value,
                            semanticLabel: entry.key,
                            onChanged: (value) =>
                                setState(() => _switches[entry.key] = value)),
                        const SizedBox(width: NlSpace.s2),
                        Text(entry.key,
                            style: NlType.text(NlType.s3, color: nl.fg)),
                      ]),
                    const NlSwitch(value: true, onChanged: null),
                  ]),
                ])),
            _section(
                'Fields',
                Column(children: [
                  NlSearchField(
                      controller: _search,
                      hint: 'Search devices and history',
                      shortcut: '⌘K'),
                  const SizedBox(height: NlSpace.s4),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                        child: NlTextField(
                            controller: _id,
                            focusNode: _focused,
                            label: 'Device ID',
                            mono: true,
                            prefixIcon: NlIcons.monitor)),
                    const SizedBox(width: NlSpace.s3),
                    Expanded(
                        child: NlTextField(
                            controller: _password,
                            label: 'Password',
                            obscure: true,
                            helper: 'Saved in the keychain')),
                  ]),
                  const SizedBox(height: NlSpace.s3),
                  NlTextField(
                      controller: _wrong,
                      label: 'Connect to',
                      mono: true,
                      error: 'An ID has nine digits'),
                ])),
          ]);

  Widget _content(NlColors nl) {
    Widget device(String id, String name, NlDeviceKind kind, bool? online,
            {bool selected = false, Key? menuKey, String? note}) =>
        NlCard(
            selected: selected,
            onTap: () {},
            padding: const EdgeInsets.all(NlSpace.s4),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    NlDeviceGlyph(id: id, kind: kind, online: online),
                    const Spacer(),
                    Builder(
                        builder: (context) => NlIconButton(
                            key: menuKey,
                            icon: NlIcons.ellipsis,
                            tooltip: 'More',
                            onPressed: () => showNlMenu(context,
                                    anchor: nlAnchorOf(context),
                                    entries: [
                                      const NlMenuHeader('Studio Mac'),
                                      const NlMenuItem(
                                          label: 'Connect',
                                          icon: NlIcons.monitor,
                                          shortcut: '⏎'),
                                      const NlMenuItem(
                                          label: 'Transfer files',
                                          icon: NlIcons.folder,
                                          shortcut: '⌘F'),
                                      const NlMenuItem(
                                          label: 'Open terminal',
                                          icon: NlIcons.terminal),
                                      const NlMenuDivider(),
                                      const NlMenuItem(
                                          label: 'Rename',
                                          icon: NlIcons.pencil,
                                          shortcut: '⌘R'),
                                      const NlMenuItem(
                                          label: 'Add to starred',
                                          icon: NlIcons.star),
                                      const NlMenuDivider(),
                                      const NlMenuItem(
                                          label: 'Forget device',
                                          icon: NlIcons.trash2,
                                          danger: true),
                                    ]))),
                  ]),
                  const SizedBox(height: NlSpace.s3),
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NlType.text(NlType.s4,
                          weight: FontWeight.w600, color: nl.fg)),
                  const SizedBox(height: 2),
                  Text(id,
                      style: NlType.monoText(NlType.s2, color: nl.fg3)),
                  const SizedBox(height: NlSpace.s3),
                  Row(children: [
                    if (online == true)
                      const NlBadge('Online', tone: NlTone.ok)
                    else if (online == false)
                      const NlBadge('Offline')
                    else
                      const NlBadge('Unknown'),
                    if (note != null) ...[
                      const SizedBox(width: NlSpace.s2),
                      Flexible(
                          child: Text(note,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NlType.text(NlType.s2, color: nl.fg3))),
                    ],
                  ]),
                ]));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _section(
          'Device cards',
          Column(children: [
            Row(children: [
              Expanded(
                  child: device(
                      '418 223 905', 'Studio Mac', NlDeviceKind.desktop, true,
                      selected: true,
                      menuKey: NikoComponentSheet.menuKey,
                      note: '2 h ago')),
              const SizedBox(width: NlSpace.s3),
              Expanded(
                  child: device('731 004 562', 'Office Workstation',
                      NlDeviceKind.laptop, true,
                      note: 'Yesterday')),
            ]),
            const SizedBox(height: NlSpace.s3),
            Row(children: [
              Expanded(
                  child: device(
                      '205 118 377', 'NAS', NlDeviceKind.server, false)),
              const SizedBox(width: NlSpace.s3),
              Expanded(
                  child: device(
                      '987 650 021', 'iPad Pro', NlDeviceKind.tablet, null)),
            ]),
          ])),
      _section(
          'Grouped rows',
          NlPanel(
              padding: const EdgeInsets.symmetric(horizontal: NlSpace.s4),
              child: Column(children: [
                NlListRow(
                    divider: false,
                    leading: NlIconTile(icon: NlIcons.server, color: nl.accent),
                    title: 'Private server',
                    subtitle: 'desk.example.net · 18 ms',
                    trailing: const NlBadge('Connected', tone: NlTone.ok)),
                NlListRow(
                    leading: NlIconTile(icon: NlIcons.mic, color: nl.tiles[3]),
                    title: 'Voice chat',
                    subtitle: 'Ask before turning the microphone on',
                    trailing: NlSwitch(value: true, onChanged: (_) {})),
                NlListRow(
                    leading: NlIconTile(icon: NlIcons.palette, color: nl.tiles[2]),
                    title: 'Appearance',
                    trailing: Text('Orbit',
                        style: NlType.text(NlType.s3, color: nl.fg3)),
                    chevron: true,
                    onTap: () {}),
                NlListRow(
                    leading: NlIconTile(icon: NlIcons.logOut, color: nl.danger),
                    title: 'Sign out of all sessions',
                    destructive: true,
                    onTap: () {}),
              ]))),
      _section(
          'Badges and status',
          Wrap(
              spacing: NlSpace.s2,
              runSpacing: NlSpace.s2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: const [
                NlBadge('12'),
                NlBadge('Direct', tone: NlTone.accent),
                NlBadge('Relay', tone: NlTone.warn, icon: NlIcons.triangleAlert),
                NlBadge('Encrypted', tone: NlTone.ok, icon: NlIcons.circleCheck),
                NlBadge('Failed', tone: NlTone.danger),
                SizedBox(width: NlSpace.s2),
                NlLed(NlLedState.live),
                NlLed(NlLedState.ok),
                NlLed(NlLedState.warn),
                NlLed(NlLedState.danger),
                NlLed(NlLedState.off),
                SizedBox(width: NlSpace.s2),
                TickerMode(enabled: false, child: NlSpinner()),
              ])),
    ]);
  }

  Widget _surfaces(NlColors nl) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _section(
            'Sidebar',
            ClipRRect(
                borderRadius: BorderRadius.circular(NlRadius.r3),
                child: Container(
                    height: 300,
                    decoration: BoxDecoration(
                        border: Border.all(color: nl.line),
                        borderRadius: BorderRadius.circular(NlRadius.r3)),
                    child: Row(children: [
                      NlSidebar(
                          width: 220,
                          header: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  NlSpace.s3, NlSpace.s3, NlSpace.s3, NlSpace.s2),
                              child: Row(children: [
                                const NlMark(size: 22),
                                const SizedBox(width: NlSpace.s2),
                                Text('NikoDesk',
                                    style: NlType.text(NlType.s4,
                                        weight: FontWeight.w600, color: nl.fg)),
                              ])),
                          footer: Container(
                              padding: const EdgeInsets.all(NlSpace.s3),
                              decoration: BoxDecoration(
                                  border:
                                      Border(top: BorderSide(color: nl.line))),
                              child: Row(children: [
                                const NlLed(NlLedState.ok),
                                const SizedBox(width: NlSpace.s2),
                                Text('590 216 734',
                                    style: NlType.monoText(NlType.s2,
                                        color: nl.fg2)),
                              ])),
                          children: [
                            NlSidebarSection(children: [
                              NlSidebarItem(
                                  icon: NlIcons.monitor,
                                  label: 'Devices',
                                  count: '5',
                                  selected: true,
                                  onTap: () {}),
                              NlSidebarItem(
                                  icon: NlIcons.history,
                                  label: 'Sessions',
                                  onTap: () {}),
                              NlSidebarItem(
                                  icon: NlIcons.share2,
                                  label: 'Temporary access',
                                  onTap: () {}),
                            ]),
                            NlSidebarSection(title: 'Groups', children: [
                              NlSidebarItem(
                                  leading: Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                          color: nl.tiles[0],
                                          shape: BoxShape.circle)),
                                  label: 'Home',
                                  count: '3',
                                  onTap: () {}),
                              NlSidebarItem(
                                  leading: Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                          color: nl.tiles[4],
                                          shape: BoxShape.circle)),
                                  label: 'Work',
                                  count: '1',
                                  onTap: () {}),
                            ]),
                          ]),
                      Expanded(
                          child: ColoredBox(
                              color: nl.bg,
                              child: const NlEmptyState(
                                  compact: true,
                                  icon: NlIcons.history,
                                  title: 'No sessions yet',
                                  message:
                                      'Sessions you start appear here.'))),
                    ])))),
        _section(
            'Dialog',
            SizedBox(
                height: 260,
                child: ClipRRect(
                    borderRadius: BorderRadius.circular(NlRadius.r3),
                    child: ColoredBox(
                        color: Color.alphaBlend(nl.scrim, nl.bg2),
                        child: NlDialog(
                            width: 380,
                            icon: NlIconTile(
                                icon: NlIcons.trash2,
                                color: nl.danger,
                                size: 40),
                            title: 'Forget Studio Mac?',
                            message:
                                'Its saved password and history are removed '
                                'from this computer.',
                            actions: [
                              NlButton.ghost(onPressed: () {}, label: 'Cancel'),
                              NlButton.danger(onPressed: () {}, label: 'Forget'),
                            ]))))),
        _section(
            'Type · Inter',
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final size in NlType.scale.reversed.take(5))
                Text('${size.toInt()} · Remote desktop 远程桌面',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NlType.text(size,
                        weight: size >= NlType.s5
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: nl.fg)),
              const SizedBox(height: NlSpace.s1),
              Text('590 216 734 · 60 fps · 18 ms',
                  style: NlType.monoText(NlType.s4,
                      weight: FontWeight.w500, color: nl.fg2)),
            ])),
        _section(
            'Colour tokens',
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final color in [
                nl.page, nl.bg, nl.bg2, nl.surface, nl.surface2, nl.line2,
                nl.fg3, nl.fg2, nl.fg, nl.accent, nl.accentFill, nl.accent2,
                nl.ok, nl.warn, nl.danger, ...nl.tiles,
              ])
                Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: nl.line))),
            ])),
      ]);
}
