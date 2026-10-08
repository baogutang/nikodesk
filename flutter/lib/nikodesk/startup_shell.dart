import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'startup_failure.dart';

/// A one-shot shell; neither its waiting UI nor animation accesses the core.
class NikoStartupShell extends StatefulWidget {
  final Future<void> ready;
  final Future<void> visible;
  final Widget Function() buildReady;

  const NikoStartupShell(
      {super.key,
      required this.ready,
      required this.visible,
      required this.buildReady});

  @override
  State<NikoStartupShell> createState() => _NikoStartupShellState();
}

class _NikoStartupShellState extends State<NikoStartupShell>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _motion = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1220))
    ..addStatusListener((status) {
      if (_readyChild != null && status == AnimationStatus.completed) {
        setState(() => _finished = true);
      }
    });
  Timer? _slowTimer;
  Widget? _readyChild;
  bool _visible = false;
  bool _slow = false;
  bool _finished = false;
  double _exitEntryProgress = 1;

  bool get _reducedMotion => WidgetsBinding
      .instance.platformDispatcher.accessibilityFeatures.disableAnimations;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _slowTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _readyChild == null) setState(() => _slow = true);
    });
    widget.visible.then((_) {
      if (!mounted || _readyChild != null) return;
      setState(() => _visible = true);
      if (!_reducedMotion) _motion.forward();
    });
    widget.ready.then((_) {
      if (!mounted) return;
      _slowTimer?.cancel();
      _exitEntryProgress = _motion.value;
      _motion.stop();
      setState(() {
        _readyChild = widget.buildReady();
        _finished = !_visible || _reducedMotion;
      });
      if (!_finished) {
        // Readiness interrupts entry immediately; there is no minimum wait.
        _motion.duration = const Duration(milliseconds: 240);
        _motion.forward(from: 0);
      }
    });
  }

  @override
  void didChangeAccessibilityFeatures() {
    if (_reducedMotion) {
      _motion.stop();
      setState(() {
        if (_readyChild != null) _finished = true;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _slowTimer?.cancel();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: _motion,
        builder: (context, _) {
          final exiting = _readyChild != null;
          final entry = _reducedMotion
              ? 1.0
              : exiting
                  ? _exitEntryProgress
                  : _motion.value;
          return Stack(textDirection: TextDirection.ltr, children: [
            if (exiting) _readyChild!,
            if (!_finished)
              AbsorbPointer(
                absorbing: exiting,
                child: Opacity(
                  key: const Key('nikodesk-startup-opacity'),
                  opacity: exiting ? 1 - _motion.value : 1,
                  child: _StartupVisual(
                      progress: entry, slow: _slow, reduced: _reducedMotion),
                ),
              ),
          ]);
        });
  }
}

double _stage(double progress, double start, double end) =>
    ((progress * 1220 - start) / (end - start)).clamp(0.0, 1.0);

class _StartupVisual extends StatelessWidget {
  final double progress;
  final bool slow;
  final bool reduced;
  const _StartupVisual(
      {required this.progress, required this.slow, required this.reduced});

  @override
  Widget build(BuildContext context) {
    final chinese =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'zh';
    final logo = _stage(progress, 80, 830);
    final text = Curves.easeOut.transform(_stage(progress, 400, 950));
    return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
            backgroundColor: const Color(0xfff6f8fb),
            body: SafeArea(
                child: Center(
                    child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          const SizedBox(height: 100),
                          SizedBox(
                              width: 300,
                              height: 86,
                              child: Stack(
                                  clipBehavior: Clip.none,
                                  alignment: Alignment.center,
                                  children: [
                                    if (!reduced)
                                      Positioned.fill(
                                          child: CustomPaint(
                                              key: const Key(
                                                  'nikodesk-startup-orbits'),
                                              painter:
                                                  _OrbitPainter(progress))),
                                    Opacity(
                                        opacity: logo,
                                        child: Transform.scale(
                                            key: const Key(
                                                'nikodesk-startup-logo'),
                                            scale: .75 +
                                                .25 *
                                                    Curves.easeOutBack
                                                        .transform(logo),
                                            child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(22),
                                                child: Image.asset(
                                                    'assets/nikodesk.png',
                                                    width: 86,
                                                    height: 86,
                                                    excludeFromSemantics:
                                                        true))))
                                  ])),
                          const SizedBox(height: 22),
                          Opacity(
                              opacity: text,
                              child: Transform.translate(
                                  offset: Offset(0, 8 * (1 - text)),
                                  child: Column(children: [
                                    const Text('NikoDesk',
                                        style: TextStyle(
                                            fontSize: 21,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xff252c31))),
                                    const SizedBox(height: 10),
                                    Text(
                                        chinese
                                            ? '你的电脑，就在这里。'
                                            : 'Your computer, right here.',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xff667587))),
                                  ]))),
                          const SizedBox(height: 28),
                          Semantics(
                              liveRegion: true,
                              child: Text(
                                  slow
                                      ? chinese
                                          ? '正在准备工作空间…'
                                          : 'Preparing your workspace…'
                                      : '',
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xff667587)))),
                          if (slow)
                            TextButton(
                                key: const Key('nikodesk-startup-slow-quit'),
                                onPressed: quitNikoStartupWindow,
                                child: Text(
                                    chinese ? '退出 NikoDesk' : 'Quit NikoDesk')),
                        ]))))));
  }
}

class _OrbitPainter extends CustomPainter {
  final double progress;
  const _OrbitPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final fade = Curves.easeInOut.transform(_stage(progress, 720, 1220));
    final appear = Curves.easeOut.transform(_stage(progress, 0, 180));
    final opacity = appear * (1 - fade);
    for (var index = 0; index < 2; index++) {
      final move =
          Curves.easeOut.transform(_stage(progress, index == 0 ? 0 : 80, 1000));
      final radius = (index == 0 ? 90.0 : 119.0) *
          (1 + (index == 0 ? .3 : .15) * (1 - move) - .35 * fade);
      final angle =
          ((index == 0 ? -140 : 50) + (index == 0 ? 170 : 155) * move) *
              math.pi /
              180;
      final color = const Color(0xff328be4)
          .withOpacity(opacity * (index == 0 ? .21 : .11));
      canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
      canvas.drawCircle(
          center + Offset(math.sin(angle), -math.cos(angle)) * radius,
          2.5,
          Paint()..color = const Color(0xff4ac8e2).withOpacity(opacity * .8));
    }
  }

  @override
  bool shouldRepaint(_OrbitPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
