import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'nightline/tokens.dart';
import 'privacy_style_model.dart';
import 'ui.dart';

/// A frame of the scene as the controlled Mac draws it (it animates there).
String? nikoPrivacyAsset(NikoPrivacyPreset preset) =>
    preset == NikoPrivacyPreset.custom
        ? null
        : 'assets/privacy/${preset.name}.webp';

/// Local selection preview. The controlled computer draws the scene itself;
/// this widget never blocks or captures a screen.
class NikoPrivacyWallpaper extends StatefulWidget {
  final NikoPrivacyStyle style;
  final bool animate;
  final bool mac;
  final bool passwordExit;
  const NikoPrivacyWallpaper(
      {super.key,
      required this.style,
      this.animate = true,
      this.mac = true,
      this.passwordExit = true});
  @override
  State<NikoPrivacyWallpaper> createState() => _WallpaperState();
}

class _WallpaperState extends State<NikoPrivacyWallpaper>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  double _time = 0;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker((elapsed) {
      if (mounted) setState(() => _time = elapsed.inMicroseconds / 1000000);
    });
  }

  void _sync() {
    final moving = widget.animate &&
        widget.style.motion &&
        _foreground &&
        TickerMode.of(context) &&
        !MediaQuery.of(context).disableAnimations &&
        (widget.style.effect != NikoPrivacyEffect.none ||
            widget.style.preset != NikoPrivacyPreset.custom);
    if (moving && !_ticker.isActive) {
      _ticker.start();
    }
    if (!moving && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant NikoPrivacyWallpaper oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final asset = nikoPrivacyAsset(style.preset);
    final picture = asset != null
        ? Image.asset(asset,
            fit: BoxFit.cover, filterQuality: FilterQuality.high)
        : style.image != null
            ? Image.memory(style.image!,
                fit: BoxFit.cover, filterQuality: FilterQuality.high)
            : const Center(
                child: Icon(Icons.add_photo_alternate_outlined,
                    color: Colors.white54));
    final motion = widget.animate &&
        style.motion &&
        !MediaQuery.of(context).disableAnimations;
    // The controlled Mac animates the scene itself; the preview drifts its
    // frame slowly so the choice reads as a moving one.
    final drift = motion && asset != null;
    final t = _time;
    return ClipRect(
        child: Stack(fit: StackFit.expand, children: [
      const ColoredBox(color: Colors.black),
      drift
          ? Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..translate(math.sin(t * .21) * 6, math.cos(t * .17) * 4)
                ..scale(1.05 + .03 * math.sin(t * .35)),
              child: picture)
          : picture,
      CustomPaint(painter: _Motion(style, motion ? _time : null)),
      if (widget.passwordExit)
        Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Align(
                alignment: Alignment.bottomCenter,
                child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _NikoPrivacyPill(
                        keys: widget.mac ? '⌃ ⌥ ⇧ esc' : 'esc')))),
      if (!widget.passwordExit && style.hint)
        Positioned(
            left: 12,
            bottom: 10,
            child: Text(widget.mac ? '⌃⌥⇧ Esc 恢复' : 'Esc 恢复',
                style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white70,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black54)]))),
      if (style.clock)
        Positioned(
            right: 12,
            top: 10,
            child: Text(
                '${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 12, color: Colors.white70))),
    ]));
  }
}

class _Motion extends CustomPainter {
  final NikoPrivacyStyle style;
  final double? time;
  const _Motion(this.style, this.time);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size,
        Paint()..color = Colors.black.withOpacity(1 - style.brightness / 100));
    if (time == null) return;
    final t = time!, strength = style.intensity / 100;
    switch (style.effect) {
      case NikoPrivacyEffect.fog:
        for (var i = 0; i < 6; i++) {
          final cx =
              ((i * .217 + t * (.035 + i * .003)) % 1.5 - .25) * size.width;
          final cy = (.64 + .035 * math.sin(i * 2 + t * .32)) * size.height;
          canvas.save();
          canvas.translate(cx, cy);
          canvas.scale(1, size.height / size.width * .44);
          final radius = size.width * .25;
          canvas.drawCircle(
              Offset.zero,
              radius,
              Paint()
                ..shader = RadialGradient(colors: [
                  const Color(0xffb5c2cf)
                      .withOpacity((.24 * strength).clamp(0, .48)),
                  Colors.transparent,
                ]).createShader(
                    Rect.fromCircle(center: Offset.zero, radius: radius)));
          canvas.restore();
        }
      case NikoPrivacyEffect.light:
        final center = .55 + .33 * math.sin(t * .62);
        final bounds = Offset.zero & size;
        canvas.drawRect(
            bounds,
            Paint()
              ..color = const Color(0xff30281b).withOpacity(.08 * strength));
        canvas.save();
        canvas.translate(center * size.width, 0);
        canvas.rotate(-.3);
        final beam = Rect.fromLTWH(
            -size.width * .24, -size.height, size.width * .48, size.height * 3);
        canvas.drawRect(
            beam,
            Paint()
              ..shader = LinearGradient(colors: [
                Colors.transparent,
                const Color(0xffffe8b5)
                    .withOpacity((.28 * strength).clamp(0, .56)),
                Colors.transparent
              ], stops: const [
                0,
                .5,
                1
              ]).createShader(beam));
        canvas.restore();
      case NikoPrivacyEffect.rain:
        final paint = Paint()
          ..color = const Color(0xffb0c9db)
              .withOpacity((.42 * strength).clamp(0, .84))
          ..strokeWidth = 1;
        for (var i = 0; i < 90; i++) {
          final x = (i * .618034 % 1) * size.width;
          final speed = 40 + math.sin(i * 1.73).abs() * 55;
          final y = (i * .411 + t * speed / size.height) % 1 * size.height;
          canvas.drawLine(Offset(x, y), Offset(x - 1, y + 3 + i % 5), paint);
        }
      case NikoPrivacyEffect.none:
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _Motion old) =>
      old.time != time || old.style != style;
}

/// The controlled computer's status pill, at preview size.
class _NikoPrivacyPill extends StatelessWidget {
  final String keys;
  const _NikoPrivacyPill({required this.keys});
  @override
  Widget build(BuildContext context) => DecoratedBox(
      decoration: BoxDecoration(
          color: const Color(0xB80B0D10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0x14FFFFFF))),
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            ...[
              Container(
                  width: 5,
                  height: 5,
                  decoration: const BoxDecoration(
                      color: Color(0xFF2FD8EE), shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(nikoText('隐私屏已开启', 'Privacy screen is on'),
                  style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFFE6EDF2),
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
            ],
            // The bundled mono face carries the modifier glyphs on every
            // platform; a generic 'monospace' may not.
            Text(keys,
                style: const TextStyle(
                    fontSize: 9,
                    fontFamily: NlType.mono,
                    fontFamilyFallback: NlType.monoFallback,
                    color: Color(0xFF93A1AD))),
            const SizedBox(width: 6),
            Text(nikoText('退出 · 需本机登录密码', 'to exit · local login password'),
                style: const TextStyle(fontSize: 9, color: Color(0xFF93A1AD))),
          ])));
}
