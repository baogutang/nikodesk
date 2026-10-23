import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'nightline.dart';
import 'ui.dart';

/// Nightline: the local keyboard type as two cards, each drawing the left
/// of a keyboard with the keys that tell the layouts apart marked. Null
/// outside the NikoDesk build or a Nightline theme, where the stock chooser
/// stays.
Widget? nikoKbLayoutChooser(BuildContext context, RxString chosenType,
    Future<bool> Function(String) choose) {
  if (!const bool.fromEnvironment('NIKODESK') ||
      NlColors.maybeOf(context) == null) {
    return null;
  }
  return NikoKbLayoutChooser(chosenType: chosenType, choose: choose);
}

class NikoKbLayoutChooser extends StatelessWidget {
  final RxString chosenType;

  /// Saves the type; true once the native side reports it back.
  final Future<bool> Function(String) choose;

  const NikoKbLayoutChooser(
      {super.key, required this.chosenType, required this.choose});

  // The stock chooser's values.
  static const iso = 'ISO';
  static const notIso = 'Not ISO';

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    Widget card(String type, String label, String detail) => Obx(() {
          final chosen = chosenType.value == type;
          return NlCard(
              key: Key('niko-kb-layout-$type'),
              selected: chosen,
              padding: const EdgeInsets.all(NlSpace.s3),
              onTap: () async {
                if (await choose(type)) chosenType.value = type;
              },
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The rows run on past the card's edge and fade out.
                    ExcludeSemantics(
                        child: ShaderMask(
                            blendMode: BlendMode.dstIn,
                            shaderCallback: (bounds) => const LinearGradient(
                                colors: [Colors.white, Colors.transparent],
                                stops: [.62, 1]).createShader(bounds),
                            child: ClipRect(
                                child: SizedBox(
                                    height: 112,
                                    child: CustomPaint(
                                        painter: _KeyboardPainter(
                                            iso: type == iso,
                                            key: nl.fg3.withOpacity(.22),
                                            mark: chosen
                                                ? nl.accent
                                                : nl.fg2.withOpacity(.8))))))),
                    const SizedBox(height: NlSpace.s3),
                    Row(children: [
                      Expanded(
                          child: Text(label,
                              style: NlType.text(NlType.s4,
                                  weight: FontWeight.w600, color: nl.fg))),
                      if (chosen)
                        Icon(NlIcons.circleCheck, size: 16, color: nl.accent),
                    ]),
                    const SizedBox(height: 2),
                    Text(detail, style: NlType.text(NlType.s2, color: nl.fg2)),
                  ]));
        });
    return SizedBox(
        width: 400,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: card(
                  iso,
                  'ISO',
                  nikoText('左 Shift 较短，旁边多一个键。',
                      'A short left Shift with an extra key beside it.'))),
          const SizedBox(width: NlSpace.s3),
          Expanded(
              child: card(
                  notIso,
                  nikoText('非 ISO', 'Not ISO'),
                  nikoText('左 Shift 较长，旁边没有多出的键。',
                      'A long left Shift with no extra key beside it.'))),
        ]));
  }
}

/// The left five rows of a keyboard in standard key units. The left Shift,
/// and on ISO the key beside it, are drawn in [mark].
class _KeyboardPainter extends CustomPainter {
  final bool iso;
  final Color key;
  final Color mark;
  const _KeyboardPainter(
      {required this.iso, required this.key, required this.mark});

  @override
  void paint(Canvas canvas, Size size) {
    final rows = [
      const [1.0, 1, 1, 1, 1, 1, 1],
      const [1.5, 1, 1, 1, 1, 1],
      const [1.75, 1, 1, 1, 1, 1],
      iso ? const [1.25, 1, 1, 1, 1, 1] : const [2.25, 1, 1, 1, 1],
      const [1.25, 1.25, 1.25, 6],
    ];
    final gap = size.height * .045;
    final unit = (size.height - gap * (rows.length - 1)) / rows.length;
    for (final (r, row) in rows.indexed) {
      var x = 0.0;
      for (final (k, width) in row.indexed) {
        final marked = r == 3 && (k == 0 || (iso && k == 1));
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(x, r * (unit + gap),
                    width * unit + (width - 1) * gap, unit),
                Radius.circular(unit * .22)),
            Paint()..color = marked ? mark : key);
        x += width * (unit + gap);
      }
    }
  }

  @override
  bool shouldRepaint(_KeyboardPainter old) =>
      old.iso != iso || old.key != key || old.mark != mark;
}
