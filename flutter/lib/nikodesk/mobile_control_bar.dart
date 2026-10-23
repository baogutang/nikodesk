import 'package:flutter/material.dart';

import 'nightline/tokens.dart';

/// The session controls of the phone and iPad app: a dark capsule centred
/// in the bar under the remote picture, styled as the desktop dock. On a
/// narrow screen the actions scroll inside it, fading at the edge that has
/// more, while [more], collapsing and ending the session stay at its end.
class NikoMobileControlBar extends StatefulWidget {
  final Widget actions;
  final Widget? more;
  final Widget collapse;
  final Widget endSession;

  const NikoMobileControlBar(
      {super.key,
      required this.actions,
      this.more,
      required this.collapse,
      required this.endSession});

  /// Icon colour of the bar's buttons; the bar is dark in both modes.
  static Color get ink => NlColors.dark.fg;

  /// Side of a button: the 44 pt touch target, so eight fit a phone.
  static const button = 44.0;

  @override
  State<NikoMobileControlBar> createState() => _NikoMobileControlBarState();
}

class _NikoMobileControlBarState extends State<NikoMobileControlBar> {
  final _scroll = ScrollController();
  var _before = false;
  var _after = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _measure(ScrollMetrics metrics) {
    final before = metrics.extentBefore > .5;
    final after = metrics.extentAfter > .5;
    if (before != _before || after != _after) {
      // Metrics arrive during layout; repaint the fade after it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _before = before;
            _after = after;
          });
        }
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    const fade = 16.0;
    Widget actions = NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) => _measure(n.metrics),
        child: NotificationListener<ScrollNotification>(
            onNotification: (n) => _measure(n.metrics),
            child: SingleChildScrollView(
                key: const Key('nikodesk-mobile-control-scroll'),
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: widget.actions)));
    if (_before || _after) {
      actions = ShaderMask(
          key: const Key('nikodesk-mobile-control-fade'),
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => LinearGradient(colors: [
                if (_before) Colors.transparent,
                Colors.white,
                Colors.white,
                if (_after) Colors.transparent,
              ], stops: [
                if (_before) 0,
                fade / bounds.width,
                1 - fade / bounds.width,
                if (_after) 1,
              ]).createShader(bounds),
          child: actions);
    }
    const side = Size.square(NikoMobileControlBar.button);
    return Center(
        child: DecoratedBox(
            key: const Key('nikodesk-mobile-control-dock'),
            decoration: BoxDecoration(
                color: NlDock.background,
                borderRadius: BorderRadius.circular(NlRadius.r4),
                border: Border.all(color: NlDock.line),
                boxShadow: NlColors.dark.shadow3),
            child: Padding(
                padding: const EdgeInsets.all(NlSpace.s1),
                child: IconButtonTheme(
                    data: IconButtonThemeData(
                        style: IconButton.styleFrom(
                            minimumSize: side,
                            fixedSize: side,
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap)),
                    child: IconTheme.merge(
                        data: IconThemeData(
                            color: NikoMobileControlBar.ink, size: 20),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Flexible(child: actions),
                          if (widget.more != null) widget.more!,
                          widget.collapse,
                          Container(
                              width: 1,
                              height: 24,
                              margin: const EdgeInsets.symmetric(
                                  horizontal: NlSpace.s1),
                              color: NlDock.separator),
                          widget.endSession,
                        ]))))));
  }
}
