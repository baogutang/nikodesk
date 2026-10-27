import 'package:flutter/material.dart';

import 'components.dart';
import 'icons.dart';
import 'tokens.dart';

/// Placeholder block for content that is loading. A soft highlight sweeps
/// across it unless motion is reduced.
class NlSkeleton extends StatefulWidget {
  final double? width;
  final double height;
  final double radius;
  const NlSkeleton(
      {super.key, this.width, this.height = 12, this.radius = NlRadius.r1});

  @override
  State<NlSkeleton> createState() => _NlSkeletonState();
}

class _NlSkeletonState extends State<NlSkeleton>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (NlMotion.reduced(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final base = nl.solid(nl.isDark ? const Color(0x14FFFFFF) : const Color(0x0D000000), nl.bg);
    final shine = nl.solid(nl.isDark ? const Color(0x24FFFFFF) : const Color(0x17000000), nl.bg);
    return AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value * 2 - .5;
          return Container(
              width: widget.width,
              height: widget.height,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.radius),
                  gradient: LinearGradient(
                      begin: Alignment(-1 + 2 * t - .6, 0),
                      end: Alignment(-1 + 2 * t + .6, 0),
                      colors: [base, shine, base])));
        });
  }
}

/// Empty or not-yet-set-up state: an icon tile, a title, one line and at
/// most one primary action.
class NlEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final Widget? secondary;
  final bool compact;

  const NlEmptyState(
      {super.key,
      required this.icon,
      required this.title,
      this.message,
      this.action,
      this.secondary,
      this.compact = false});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Center(
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: NlSpace.s6,
                    vertical: compact ? NlSpace.s6 : NlSpace.s12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: compact ? 44 : 56,
                      height: compact ? 44 : 56,
                      decoration: BoxDecoration(
                          color: nl.surface,
                          borderRadius:
                              BorderRadius.circular(compact ? 12 : 16),
                          border: Border.all(color: nl.ring),
                          boxShadow: nl.shadow1),
                      child: Icon(icon,
                          size: compact ? 20 : 24, color: nl.fg2)),
                  SizedBox(height: compact ? NlSpace.s3 : NlSpace.s5),
                  Text(title,
                      textAlign: TextAlign.center,
                      style: NlType.text(compact ? NlType.s4 : NlType.s5,
                          weight: FontWeight.w600, color: nl.fg)),
                  if (message != null) ...[
                    const SizedBox(height: NlSpace.s2),
                    Text(message!,
                        textAlign: TextAlign.center,
                        style: NlType.text(NlType.s3, color: nl.fg2)
                            .copyWith(height: 20 / 13)),
                  ],
                  if (action != null) ...[
                    SizedBox(height: compact ? NlSpace.s4 : NlSpace.s5),
                    action!,
                  ],
                  if (secondary != null) ...[
                    const SizedBox(height: NlSpace.s2),
                    secondary!,
                  ],
                ]))));
  }
}

/// Small count or status capsule.
class NlBadge extends StatelessWidget {
  final String label;
  final NlTone tone;
  final IconData? icon;
  const NlBadge(this.label, {super.key, this.tone = NlTone.neutral, this.icon});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final (Color fill, Color ink) = switch (tone) {
      NlTone.neutral => (nl.solid(nl.hover, nl.surface2), nl.fg2),
      NlTone.accent => (nl.accentSoft, nl.accentText),
      NlTone.ok => (nl.okSoft, nl.okText),
      NlTone.warn => (nl.warnSoft, nl.warnText),
      NlTone.danger => (nl.dangerSoft, nl.dangerText),
    };
    final style = NlType.text(NlType.s1, weight: FontWeight.w500, color: ink)
        .copyWith(height: 1.1);
    // Grows with large text instead of clipping it; a label alone ends in
    // an ellipsis where the badge has a width limit.
    return Container(
        constraints: const BoxConstraints(minHeight: 20),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
            color: fill, borderRadius: BorderRadius.circular(NlRadius.pill)),
        child: icon == null
            ? Align(
                widthFactor: 1,
                heightFactor: 1,
                child: Text(label,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: style))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 12, color: ink),
                const SizedBox(width: 4),
                Text(label, style: style),
              ]));
  }
}

enum NlDeviceKind { desktop, laptop, server, phone, tablet, tv, unknown }

/// A device's tile: a rounded square in the device's colour with a white
/// glyph, and an online mark in the corner when [online] is known.
class NlDeviceGlyph extends StatelessWidget {
  final String id;
  final NlDeviceKind kind;
  final double size;
  final bool? online;

  const NlDeviceGlyph(
      {super.key,
      required this.id,
      this.kind = NlDeviceKind.desktop,
      this.size = 40,
      this.online});

  static IconData iconFor(NlDeviceKind kind) => switch (kind) {
        NlDeviceKind.desktop => NlIcons.monitor,
        NlDeviceKind.laptop => NlIcons.laptop,
        NlDeviceKind.server => NlIcons.server,
        NlDeviceKind.phone => NlIcons.smartphone,
        NlDeviceKind.tablet => NlIcons.tablet,
        NlDeviceKind.tv => NlIcons.tv,
        NlDeviceKind.unknown => NlIcons.monitorSmartphone,
      };

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    // A neutral mark: devices are told apart by name and picture, not by
    // colour. Offline devices fade.
    final tile = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            color: nl.surface2,
            borderRadius: BorderRadius.circular(size * .24)),
        child: Icon(iconFor(kind),
            size: size * .5,
            color: online == false ? nl.fg3 : nl.fg2));
    if (online == null) return tile;
    final dot = size * .26;
    return SizedBox(
        width: size,
        height: size,
        child: Stack(clipBehavior: Clip.none, children: [
          tile,
          Positioned(
              right: -dot * .22,
              bottom: -dot * .22,
              child: Container(
                  width: dot,
                  height: dot,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: online! ? nl.ok : nl.fg3,
                      border: Border.all(
                          color: nl.isDark ? nl.surface : nl.bg,
                          width: dot * .2)))),
        ]));
  }
}
