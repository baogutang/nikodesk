import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/file_pane.dart';

class MenuButton extends StatefulWidget {
  final GestureTapCallback? onPressed;
  final Color color;
  final Color hoverColor;
  final Color? splashColor;
  final Widget child;
  final String? tooltip;
  final EdgeInsetsGeometry padding;
  final bool enableFeedback;
  const MenuButton({
    super.key,
    required this.onPressed,
    required this.color,
    required this.hoverColor,
    required this.child,
    this.splashColor,
    this.tooltip = "",
    this.padding = const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
    this.enableFeedback = true,
  });

  @override
  State<MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<MenuButton> {
  bool _isHover = false;
  final double _borderRadius = 8.0;

  @override
  Widget build(BuildContext context) {
    if (const bool.fromEnvironment('NIKODESK')) {
      final niko = nikoMenuButton(context,
          child: widget.child,
          onPressed: widget.onPressed,
          tooltip: widget.tooltip,
          padding: widget.padding);
      if (niko != null) return niko;
    }
    return Padding(
      padding: widget.padding,
      child: Tooltip(
        waitDuration: Duration(milliseconds: 300),
        message: widget.tooltip,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_borderRadius),
              color: _isHover ? widget.hoverColor : widget.color,
            ),
            child: InkWell(
              hoverColor: widget.hoverColor,
              onHover: (val) {
                setState(() {
                  _isHover = val;
                });
              },
              borderRadius: BorderRadius.circular(_borderRadius),
              splashColor: widget.splashColor,
              enableFeedback: widget.enableFeedback,
              onTap: widget.onPressed,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
