import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart' show CustomAlertDialog;

import 'nightline.dart';
import 'theme.dart' show nikoSessionTheme;

/// The frame of a panel opened over a session through the dialog manager:
/// a floating card in the middle of a wide window, a sheet along the bottom
/// edge of a phone, dark in both modes as all session chrome is. It eases
/// in, takes the keyboard from the session as the stock dialog does, closes
/// on Escape, and its child decides what scrolls, so a header and footer
/// can stay in place.
class NikoSessionSheet extends CustomAlertDialog {
  final double width;

  const NikoSessionSheet(
      {Key? key, this.width = 600, required Widget child, Function()? onCancel})
      : super(key: key, content: child, onCancel: onCancel);

  @override
  Widget build(BuildContext context) => Theme(
      data: nikoSessionTheme(context),
      child: _SheetFrame(width: width, onCancel: onCancel, child: content));
}

/// Opens a [NikoSessionSheet] as a route over [context], for a session
/// panel that a page opens rather than the dialog manager. The frame moves
/// in by itself; the route fades the scrim, and the sheet on the way out.
Future<T?> showNikoSessionSheet<T>(BuildContext context,
    {required WidgetBuilder builder, double width = 600}) {
  return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black45,
      transitionDuration: NlMotion.of(context, NlMotion.base),
      pageBuilder: (route, _, __) => NikoSessionSheet(
          width: width,
          onCancel: () => Navigator.pop(route),
          child: Builder(builder: builder)));
}

class _SheetFrame extends StatefulWidget {
  final double width;
  final Function()? onCancel;
  final Widget child;
  const _SheetFrame(
      {required this.width, required this.onCancel, required this.child});

  @override
  State<_SheetFrame> createState() => _SheetFrameState();
}

class _SheetFrameState extends State<_SheetFrame> {
  final _scope = FocusScopeNode(debugLabel: 'nikodesk-session-sheet');

  @override
  void initState() {
    super.initState();
    // The session keeps focus for remote input; the sheet takes it so keys
    // stay local while it is open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_scope.hasFocus) _scope.requestFocus();
    });
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final media = MediaQuery.of(context);
    final compact = media.size.width < NlLayout.compactMax;
    final radius = compact
        ? const BorderRadius.vertical(top: Radius.circular(NlRadius.r4))
        : BorderRadius.circular(NlRadius.r4);
    final card = Material(
        type: MaterialType.transparency,
        child: Container(
            decoration: BoxDecoration(
                color: nl.overlay,
                borderRadius: radius,
                border: nl.isDark ? Border.all(color: nl.line) : null,
                boxShadow: nl.shadow3),
            child: ClipRRect(
                borderRadius: radius,
                child: Padding(
                    padding: EdgeInsets.fromLTRB(
                        compact ? NlSpace.s5 : NlSpace.s6,
                        compact ? NlSpace.s3 : NlSpace.s5,
                        compact ? NlSpace.s5 : NlSpace.s6,
                        NlSpace.s5 + (compact ? media.padding.bottom : 0)),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (compact)
                        // The grabber says this is a sheet; the scrim or the
                        // close button dismisses it.
                        Container(
                            width: 36,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: NlSpace.s3),
                            decoration: BoxDecoration(
                                color: nl.line2,
                                borderRadius:
                                    BorderRadius.circular(NlRadius.pill))),
                      Flexible(child: widget.child),
                    ])))));
    final duration = NlMotion.of(context, NlMotion.slow);
    final moving = duration != Duration.zero;
    final Widget frame = compact
        ? Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: 640,
                    maxHeight: (media.size.height - media.padding.top) * .9),
                child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: moving ? 1 : 0, end: 0),
                    duration: duration,
                    curve: NlMotion.ease,
                    builder: (context, t, child) => FractionalTranslation(
                        translation: Offset(0, t), child: child),
                    child: card)))
        : Center(
            child: Padding(
                padding: const EdgeInsets.all(NlSpace.s6),
                child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: widget.width,
                        maxHeight: media.size.height - 2 * NlSpace.s6),
                    child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: moving ? 0 : 1, end: 1),
                        duration: duration,
                        curve: NlMotion.ease,
                        builder: (context, t, child) => Opacity(
                            opacity: t,
                            child: Transform.scale(
                                scale: .97 + .03 * t, child: child)),
                        child: card))));
    return FocusScope(
        node: _scope,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            widget.onCancel?.call();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: frame);
  }
}
