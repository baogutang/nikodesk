import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'components.dart';
import 'icons.dart';
import 'tokens.dart';

class NlCommand {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? leading;
  final String? group;
  final String? shortcut;
  final List<String> keywords;
  final VoidCallback run;
  const NlCommand(
      {required this.title,
      required this.run,
      this.subtitle,
      this.icon,
      this.leading,
      this.group,
      this.shortcut,
      this.keywords = const []});

  /// 0 when [query] does not match; higher is better.
  int score(String query) {
    if (query.isEmpty) return 1;
    final q = query.toLowerCase();
    final title = this.title.toLowerCase();
    if (title.startsWith(q)) return 400;
    if (title.split(RegExp(r'[\s·\-_]+')).any((w) => w.startsWith(q))) {
      return 300;
    }
    if (title.contains(q)) return 200;
    final rest = [subtitle ?? '', ...keywords].join(' ').toLowerCase();
    if (rest.contains(q)) return 100;
    return 0;
  }
}

/// ⌘K palette: type to filter [commands], arrows to move, Enter to run.
Future<void> showNlCommandPalette(BuildContext context,
    {required List<NlCommand> commands,
    required String hint,
    required String empty}) async {
  final nl = NlColors.of(context);
  final theme = Theme.of(context);
  final command = await showGeneralDialog<NlCommand>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: nl.isDark ? const Color(0x66000000) : const Color(0x1F000000),
      transitionDuration: NlMotion.of(context, NlMotion.base),
      pageBuilder: (context, _, __) => Theme(
          data: theme,
          child: _Palette(commands: commands, hint: hint, empty: empty)),
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
            parent: animation, curve: NlMotion.ease, reverseCurve: NlMotion.exit);
        return FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: const Interval(0, .7)),
            child: SlideTransition(
                position: Tween<Offset>(
                        begin: const Offset(0, -.012), end: Offset.zero)
                    .animate(curved),
                child: ScaleTransition(
                    scale: Tween<double>(begin: .98, end: 1).animate(curved),
                    child: child)));
      });
  command?.run();
}

class _Palette extends StatefulWidget {
  final List<NlCommand> commands;
  final String hint;
  final String empty;
  const _Palette(
      {required this.commands, required this.hint, required this.empty});

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  int _selected = 0;
  List<NlCommand> _results = const [];

  static const _rowHeight = 40.0;

  @override
  void initState() {
    super.initState();
    _filter();
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _filter() {
    final query = _query.text.trim();
    final scored = [
      for (var i = 0; i < widget.commands.length; i++)
        (widget.commands[i], widget.commands[i].score(query), i)
    ].where((entry) => entry.$2 > 0).toList()
      ..sort((a, b) => b.$2 != a.$2 ? b.$2 - a.$2 : a.$3 - b.$3);
    setState(() {
      _results = [for (final entry in scored) entry.$1];
      _selected = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _move(int delta) {
    if (_results.isEmpty) return;
    setState(() => _selected = (_selected + delta) % _results.length);
    if (!_scroll.hasClients) return;
    final top = _selected * _rowHeight;
    final view = _scroll.position.viewportDimension;
    final offset = _scroll.offset;
    if (top < offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > offset + view) {
      _scroll.jumpTo(top + _rowHeight - view);
    }
  }

  void _run([int? index]) {
    final i = index ?? _selected;
    if (i < 0 || i >= _results.length) return;
    Navigator.pop(context, _results[i]);
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(580.0, screen.width - 2 * NlSpace.s4);
    return Align(
        alignment: Alignment.topCenter,
        child: Padding(
            padding: EdgeInsets.only(
                top: math.max(NlSpace.s8, screen.height * .12)),
            child: Material(
                type: MaterialType.transparency,
                child: Container(
                    width: width,
                    constraints:
                        BoxConstraints(maxHeight: math.min(460, screen.height * .7)),
                    decoration: BoxDecoration(
                        color: nl.overlay,
                        borderRadius: BorderRadius.circular(NlRadius.r4),
                        border: nl.isDark ? Border.all(color: nl.line) : null,
                        boxShadow: nl.shadow3),
                    child: ClipRRect(
                        borderRadius: BorderRadius.circular(NlRadius.r4),
                        child: CallbackShortcuts(
                            bindings: {
                              const SingleActivator(LogicalKeyboardKey.arrowDown):
                                  () => _move(1),
                              const SingleActivator(LogicalKeyboardKey.arrowUp):
                                  () => _move(-1),
                              const SingleActivator(LogicalKeyboardKey.enter):
                                  _run,
                              const SingleActivator(
                                  LogicalKeyboardKey.numpadEnter): _run,
                            },
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(
                                      height: 52,
                                      child: Row(children: [
                                        const SizedBox(width: NlSpace.s4),
                                        Icon(NlIcons.search,
                                            size: 18, color: nl.fg3),
                                        const SizedBox(width: NlSpace.s3),
                                        Expanded(
                                            child: TextField(
                                                key: const Key(
                                                    'nikodesk-command-palette-query'),
                                                controller: _query,
                                                autofocus: true,
                                                onChanged: (_) => _filter(),
                                                onSubmitted: (_) => _run(),
                                                style: NlType.text(NlType.s5,
                                                    color: nl.fg),
                                                cursorColor: nl.accent,
                                                decoration: InputDecoration(
                                                    isCollapsed: true,
                                                    filled: false,
                                                    border: InputBorder.none,
                                                    enabledBorder:
                                                        InputBorder.none,
                                                    focusedBorder:
                                                        InputBorder.none,
                                                    hintText: widget.hint,
                                                    hintStyle: NlType.text(
                                                        NlType.s5,
                                                        color: nl.fg3)))),
                                        const Padding(
                                            padding: EdgeInsets.only(
                                                right: NlSpace.s4),
                                            child: NlKbd('esc')),
                                      ])),
                                  Container(height: 1, color: nl.line),
                                  Flexible(
                                      child: _results.isEmpty
                                          ? Padding(
                                              padding: const EdgeInsets.all(
                                                  NlSpace.s6),
                                              child: Text(widget.empty,
                                                  textAlign: TextAlign.center,
                                                  style: NlType.text(NlType.s3,
                                                      color: nl.fg3)))
                                          : ListView.builder(
                                              controller: _scroll,
                                              shrinkWrap: true,
                                              padding: const EdgeInsets.all(
                                                  NlSpace.s1 + 2),
                                              itemExtent: _rowHeight,
                                              itemCount: _results.length,
                                              itemBuilder: (context, i) =>
                                                  _row(nl, i))),
                                ])))))));
  }

  Widget _row(NlColors nl, int i) {
    final command = _results[i];
    final selected = i == _selected;
    return MouseRegion(
        onHover: (_) {
          if (_selected != i) setState(() => _selected = i);
        },
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
            onTap: () => _run(i),
            child: Semantics(
                button: true,
                selected: selected,
                label: command.title,
                child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: NlSpace.s3),
                    decoration: BoxDecoration(
                        color: selected ? nl.selected : Colors.transparent,
                        borderRadius: BorderRadius.circular(NlRadius.r2)),
                    child: Row(children: [
                      SizedBox(
                          width: 24,
                          child: command.leading ??
                              Icon(command.icon ?? NlIcons.arrowRight,
                                  size: 16,
                                  color: selected ? nl.fg : nl.fg2)),
                      const SizedBox(width: NlSpace.s3),
                      Expanded(
                          child: Text.rich(
                              TextSpan(children: [
                                TextSpan(
                                    text: command.title,
                                    style: NlType.text(NlType.s3,
                                        weight: FontWeight.w500, color: nl.fg)),
                                if (command.subtitle != null)
                                  TextSpan(
                                      text: '  ${command.subtitle}',
                                      style: NlType.text(NlType.s2,
                                          color: nl.fg3)),
                              ]),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis)),
                      if (command.group != null)
                        Text(command.group!,
                            style: NlType.text(NlType.s2, color: nl.fg3)),
                      if (command.shortcut != null) ...[
                        const SizedBox(width: NlSpace.s2),
                        NlKbd(command.shortcut!),
                      ],
                      if (selected) ...[
                        const SizedBox(width: NlSpace.s2),
                        Icon(NlIcons.cornerDownLeft, size: 14, color: nl.fg3),
                      ],
                    ])))));
  }
}
