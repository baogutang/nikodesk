import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'privacy_style_model.dart';
import 'ui.dart';

String? nikoPrivacyAsset(NikoPrivacyPreset preset) => switch (preset) {
      NikoPrivacyPreset.snow => 'assets/privacy/snow-ridge.webp',
      NikoPrivacyPreset.paper => 'assets/privacy/paper-light.webp',
      NikoPrivacyPreset.rain => 'assets/privacy/pixel-rain.webp',
      NikoPrivacyPreset.custom => null,
    };

/// Local selection preview. Native cover windows draw the same fog/light/rain
/// over the full-resolution image; this widget never blocks or captures a screen.
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
        widget.style.effect != NikoPrivacyEffect.none;
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
    return ClipRect(
        child: Stack(fit: StackFit.expand, children: [
      const ColoredBox(color: Colors.black),
      picture,
      CustomPaint(painter: _Motion(style, motion ? _time : null)),
      if (widget.passwordExit)
        Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Align(
                alignment: Alignment.bottomLeft,
                child: DecoratedBox(
                    decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.72),
                        borderRadius: BorderRadius.circular(8)),
                    child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 9),
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(nikoText('本机已开启隐私屏', 'Privacy screen is on'),
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600)),
                              Text(
                                  nikoText(
                                      widget.mac
                                          ? '⌃⌥⇧ Esc 退出 · 需系统登录密码'
                                          : 'Esc 退出 · 需系统登录密码',
                                      '${widget.mac ? '⌃⌥⇧ Esc' : 'Esc'} to exit · System login password required'),
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.white70)),
                            ]))))),
      if (!widget.passwordExit && style.hint)
        Positioned(
            left: 12,
            bottom: 10,
            child: Text(widget.mac ? '⌃⌥⇧ Esc 恢复' : 'Esc 恢复',
                style: const TextStyle(fontSize: 10, color: Colors.white70,
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
