import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Cold-start splash overlay. Wraps the whole app and shows the brand for a
/// moment (logo eases in, then fades out to the app underneath).
///
/// flutter_native_splash / the Android 12 system splash only own the first
/// few hundred ms during process start; this Flutter overlay gives a
/// consistent brand moment on every phone. Drawn in code — no image asset —
/// so it is crisp at any size.
class StartupSplash extends StatefulWidget {
  final Widget child;
  const StartupSplash({super.key, required this.child});

  @override
  State<StartupSplash> createState() => _StartupSplashState();
}

class _StartupSplashState extends State<StartupSplash> with SingleTickerProviderStateMixin {
  bool _showSplash = true;
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..forward();

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _showSplash = false);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          ignoring: !_showSplash,
          child: AnimatedOpacity(
            opacity: _showSplash ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
            child: Material(type: MaterialType.transparency, child: _SplashView(anim: _c)),
          ),
        ),
      ],
    );
  }
}

class _SplashView extends StatelessWidget {
  final Animation<double> anim;
  const _SplashView({required this.anim});

  static const _top = Color(0xFF3B82F6);
  static const _bottom = Color(0xFF1D4ED8);

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final logo = (w * 0.32).clamp(96.0, 150.0);
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_top, _bottom]),
      ),
      child: Stack(children: [
        // Soft light shapes for depth.
        Positioned(top: -w * 0.35, right: -w * 0.3,
            child: _glow(w * 0.9, Colors.white.withOpacity(0.08))),
        Positioned(bottom: -w * 0.45, left: -w * 0.35,
            child: _glow(w * 1.0, Colors.white.withOpacity(0.06))),
        Center(
          child: AnimatedBuilder(
            animation: anim,
            builder: (_, __) {
              final t = Curves.easeOutCubic.transform(anim.value.clamp(0.0, 1.0));
              final dot = Curves.elasticOut.transform(((anim.value - 0.35) / 0.65).clamp(0.0, 1.0));
              final text = Curves.easeOut.transform(((anim.value - 0.3) / 0.7).clamp(0.0, 1.0));
              return Column(mainAxisSize: MainAxisSize.min, children: [
                Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: 0.85 + 0.15 * t,
                    child: SizedBox(
                      width: logo, height: logo,
                      child: CustomPaint(painter: _MarkPainter(sweep: t, dot: dot)),
                    ),
                  ),
                ),
                SizedBox(height: logo * 0.28),
                Opacity(
                  opacity: text,
                  child: Transform.translate(
                    offset: Offset(0, 12 * (1 - text)),
                    child: Column(children: [
                      const Text('Opstation',
                          style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800,
                              letterSpacing: 0.5, decoration: TextDecoration.none)),
                      const SizedBox(height: 6),
                      Text('Empowering Field Teams',
                          style: TextStyle(color: Colors.white.withOpacity(0.78), fontSize: 13.5,
                              fontWeight: FontWeight.w500, letterSpacing: 0.3, decoration: TextDecoration.none)),
                    ]),
                  ),
                ),
              ]);
            },
          ),
        ),
        Positioned(
          left: 0, right: 0, bottom: 48,
          child: Center(
            child: SizedBox(
              width: 22, height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white.withOpacity(0.85)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _glow(double size, Color c) => Container(
        width: size, height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: c),
      );
}

/// The Opstation mark: a white ring (drawn as it appears) with a green
/// "route stop" dot on its top-right, set in a small gap.
class _MarkPainter extends CustomPainter {
  final double sweep; // 0 … 1 how much of the ring is drawn
  final double dot;   // 0 … 1 dot scale
  _MarkPainter({required this.sweep, required this.dot});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = Offset(s / 2, s / 2);
    final r = s * 0.36;
    final ring = s * 0.125;
    final a = -math.pi / 4; // dot sits at 45°, top-right
    final dc = c + Offset(r * math.cos(a), r * math.sin(a));

    canvas.saveLayer(Offset.zero & size, Paint());
    final ringPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = ring
      ..strokeCap = StrokeCap.round;
    // Draw the ring growing clockwise from just after the dot.
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), a + 0.35, 2 * math.pi * sweep, false, ringPaint);
    if (dot > 0) {
      // Clear a small gap around the dot, then the dot itself.
      canvas.drawCircle(dc, ring * 1.15 * dot.clamp(0.0, 1.0),
          Paint()..blendMode = BlendMode.clear);
      canvas.drawCircle(dc, ring * 0.8 * dot, Paint()..color = const Color(0xFF34D399));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) => old.sweep != sweep || old.dot != dot;
}
