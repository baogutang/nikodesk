import 'package:flutter/material.dart';

import 'nightline.dart';
import 'ui.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Today", "Yesterday" or the date, as the history lists head each day.
String nikoDayLabel(DateTime day, {DateTime? now}) {
  final today = now ?? DateTime.now();
  // Whole days between the two dates; UTC so a DST change is not a day.
  final days = DateTime.utc(today.year, today.month, today.day)
      .difference(DateTime.utc(day.year, day.month, day.day))
      .inDays;
  if (days == 0) return nikoText('今天', 'Today');
  if (days == 1) return nikoText('昨天', 'Yesterday');
  final month = _months[day.month - 1];
  if (day.year == today.year) {
    return nikoText('${day.month}月${day.day}日', '$month ${day.day}');
  }
  return nikoText(
      '${day.year}年${day.month}月${day.day}日', '$month ${day.day}, ${day.year}');
}

/// Items grouped by their local day, in the order they came.
List<(DateTime, List<T>)> nikoByDay<T>(
    Iterable<T> items, DateTime Function(T item) at) {
  final days = <DateTime, List<T>>{};
  for (final item in items) {
    final local = at(item).toLocal();
    days
        .putIfAbsent(DateTime(local.year, local.month, local.day), () => [])
        .add(item);
  }
  return [for (final day in days.entries) (day.key, day.value)];
}

/// Local time of day as HH:MM:SS.
String nikoClock(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// The heading over one day of a history list.
class NikoHistoryDay extends StatelessWidget {
  final String label;
  final bool first;
  const NikoHistoryDay(this.label, {super.key, this.first = false});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Padding(
        padding: EdgeInsets.only(
            top: first ? NlSpace.s2 : NlSpace.s6, bottom: NlSpace.s1),
        child: Semantics(
            header: true,
            child: Text(label,
                style: NlType.text(NlType.s2,
                    weight: FontWeight.w600, color: nl.fg2))));
  }
}

/// What became of a session or request, as a dot and a short phrase.
class NikoHistoryStatus extends StatelessWidget {
  final String label;
  final NlLedState state;
  final Key? textKey;
  const NikoHistoryStatus(this.label,
      {super.key, required this.state, this.textKey});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      NlLed(state, size: 6),
      const SizedBox(width: NlSpace.s2),
      Flexible(
          child: Text(label,
              key: textKey, style: NlType.text(NlType.s2, color: nl.fg2))),
    ]);
  }
}

/// One entry of a history list: when, what kind, with whom, and what can be
/// done with it again. Rows sit flat with hairlines between them. On a
/// narrow page the time joins the second line, and the actions move under
/// the text when the row is too tight to keep them beside it.
class NikoHistoryRow extends StatefulWidget {
  final IconData icon;
  final String? time;
  final Widget title;
  final Widget? subtitle;
  final Widget? footer;
  final List<Widget> actions;
  final bool first;

  const NikoHistoryRow(
      {super.key,
      required this.icon,
      required this.title,
      this.time,
      this.subtitle,
      this.footer,
      this.actions = const [],
      this.first = false});

  @override
  State<NikoHistoryRow> createState() => _NikoHistoryRowState();
}

class _NikoHistoryRowState extends State<NikoHistoryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth / MediaQuery.textScalerOf(context).scale(1);
      final narrow = width < 520;
      final tight = width < 340;
      final time = widget.time == null
          ? null
          : Text(widget.time!,
              style: NlType.monoText(NlType.s2, color: nl.fg3));
      final second = narrow && time != null
          ? Wrap(
              spacing: NlSpace.s2,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [time, if (widget.subtitle != null) widget.subtitle!])
          : widget.subtitle;
      final text = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.title,
            if (second != null)
              Padding(padding: const EdgeInsets.only(top: 2), child: second),
            if (widget.footer != null)
              Padding(
                  padding: const EdgeInsets.only(top: NlSpace.s1),
                  child: widget.footer!),
          ]);
      final actions = widget.actions.isEmpty
          ? null
          : Wrap(
              spacing: NlSpace.s1,
              runSpacing: NlSpace.s1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: widget.actions);
      const tileSize = 28.0;
      final tile = NlIconTile(icon: widget.icon, color: nl.fg2, size: tileSize);
      final content = tight
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                tile,
                const SizedBox(width: NlSpace.s3),
                Expanded(child: text),
              ]),
              if (actions != null) ...[
                const SizedBox(height: NlSpace.s2),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            ])
          : narrow
              ? Row(children: [
                  tile,
                  const SizedBox(width: NlSpace.s3),
                  Expanded(child: text),
                  if (actions != null) ...[
                    const SizedBox(width: NlSpace.s2),
                    actions,
                  ],
                ])
              : Row(children: [
              if (time != null) ...[time, const SizedBox(width: NlSpace.s4)],
              tile,
              const SizedBox(width: NlSpace.s3),
              Expanded(child: text),
              if (actions != null) ...[
                const SizedBox(width: NlSpace.s3),
                actions,
              ],
            ]);
      return MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned(
                left: -NlSpace.s2,
                right: -NlSpace.s2,
                top: 1,
                bottom: 0,
                child: AnimatedContainer(
                    duration: NlMotion.of(context, NlMotion.instant),
                    decoration: BoxDecoration(
                        color: _hovered ? nl.hover : Colors.transparent,
                        borderRadius: BorderRadius.circular(NlRadius.r2)))),
            Container(
                constraints: const BoxConstraints(minHeight: 52),
                padding: const EdgeInsets.symmetric(vertical: NlSpace.s3),
                alignment: Alignment.centerLeft,
                child: content),
            // On a narrow page the hairline starts under the text, so the
            // icons read as one column.
            if (!widget.first)
              Positioned(
                  top: 0,
                  left: narrow ? tileSize + NlSpace.s3 : 0,
                  right: 0,
                  child: Container(height: 1, color: nl.line)),
          ]));
    });
  }
}
