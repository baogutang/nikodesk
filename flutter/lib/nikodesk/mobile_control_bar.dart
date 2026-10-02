import 'package:flutter/material.dart';

class NikoMobileControlBar extends StatelessWidget {
  final Widget actions;
  final Widget collapse;
  final Widget endSession;

  const NikoMobileControlBar({super.key, required this.actions,
      required this.collapse, required this.endSession});

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: SingleChildScrollView(
        key: const Key('nikodesk-mobile-control-scroll'),
        scrollDirection: Axis.horizontal, child: actions)),
    collapse,
    SizedBox(height: 24, child: VerticalDivider(
        width: 8, color: Theme.of(context).colorScheme.onPrimary.withOpacity(.35))),
    endSession,
  ]);
}
