import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The still background of the login page: deep blue with soft light trails, the same look as the video.
/// It is what shows on phones, slow connections, with reduced motion, while the video loads and if it
/// cannot play, so the page always looks finished.
class LoginScenePainter extends CustomPainter {
  const LoginScenePainter({this.seed = 11, this.density = 34, this.t = 0});

  /// Position in the slow loop, 0 to 1. 0 is the still picture.
  final double t;
  final int seed;
  final int density;

  static const _blue = Color(0xFF4B84F5);
  static const _lightBlue = Color(0xFF9DBBFA);
  static const _white = Color(0xFFFFFFFF);
  static const _amber = Color(0xFFFFB020);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(w, h), const [Color(0xFF0B1220), Color(0xFF111B33), Color(0xFF16234A)], const [0, 0.55, 1]),
    );
    canvas.drawRect(
      rect,
      Paint()..shader = ui.Gradient.radial(Offset(w * 0.74, h * 0.3), math.max(w, h) * 0.55, [const Color(0xFF2F6FED).withOpacity(0.5), const Color(0x002F6FED)]),
    );
    canvas.drawRect(
      rect,
      Paint()..shader = ui.Gradient.radial(Offset(w * 0.15, h * 0.95), math.max(w, h) * 0.5, [_amber.withOpacity(0.22), const Color(0x00FFB020)]),
    );

    final r = math.Random(seed);
    const palette = [_blue, _blue, _blue, _blue, _blue, _blue, _blue, _blue, _blue, _lightBlue, _lightBlue, _lightBlue, _lightBlue, _lightBlue, _white, _white, _white, _amber, _amber, _amber];
    double between(double a, double b) => a + r.nextDouble() * (b - a);
    for (var i = 0; i < density; i++) {
      final ph = 2 * math.pi * (t + i * 0.37);
      final y0 = between(0.40 * h, 1.12 * h) + math.sin(ph) * 0.025 * h;
      final rise = between(0.22 * h, 0.62 * h);
      const x0 = -120.0;
      final x1 = w + 120.0;
      final c1x = x0 + between(0.25, 0.4) * w, c1y = y0 + between(-0.08, 0.1) * h;
      final c2x = x0 + between(0.6, 0.78) * w, c2y = y0 - rise * between(0.7, 1.0);
      final y1 = y0 - rise;
      final color = palette[r.nextInt(palette.length)];
      final width = between(0.8, 3.4);
      final opacity = between(0.25, 0.8);
      final path = Path()
        ..moveTo(x0, y0)
        ..cubicTo(c1x, c1y, c2x, c2y, x1, y1);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = width
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6)
          ..shader = ui.Gradient.linear(
            Offset(x0, y0),
            Offset(x1, y1),
            [color.withOpacity(0), color.withOpacity(opacity), color.withOpacity(0)],
            [0, 0.5 + 0.22 * math.sin(ph + 1.3), 1],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant LoginScenePainter old) => old.seed != seed || old.density != density || old.t != t;
}

/// The login background: the same trails, drifting slowly. One loop is 40 seconds.
/// It stands still when the device asks for less motion.
class LoginTrails extends StatefulWidget {
  const LoginTrails({super.key});

  @override
  State<LoginTrails> createState() => _LoginTrailsState();
}

class _LoginTrailsState extends State<LoginTrails> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 40));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(painter: LoginScenePainter(t: _c.value)),
      ),
    );
  }
}

/// A truck-art truck driving along the road at the bottom of the login page, on and on. The truck itself stays
/// put (with a slight sway) and the road slides under it, so it never leaves the picture or covers the sign-in
/// form. Only on wide screens; it stands still when the device asks for less motion.
class LoginRoadTruck extends StatefulWidget {
  const LoginRoadTruck({super.key});

  @override
  State<LoginRoadTruck> createState() => _LoginRoadTruckState();
}

class _LoginRoadTruckState extends State<LoginRoadTruck> with SingleTickerProviderStateMixin {
  // One hour per cycle; the time in seconds is read from the value, so nothing visibly restarts.
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(hours: 1));

  static const _imgW = 1100.0, _imgH = 742.0;
  static const _speed = 200.0; // pixels per second the road moves

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, c) {
        final h = c.maxHeight;
        if (h < 520 || c.maxWidth < 700) return const SizedBox.shrink();
        // The truck lives mostly inside the road band so it never climbs into the headline or the feature chips.
        final roadH = (h * 0.22).clamp(100.0, 170.0);
        final truckH = roadH * 1.1;
        final w = truckH * _imgW / _imgH;
        final bottom = roadH * 0.5;
        return AnimatedBuilder(
          animation: _c,
          builder: (_, __) {
            final sec = _c.value * 3600.0;
            final bob = math.sin(sec * 7) * 0.9;
            return Stack(children: [
              Positioned(left: 0, right: 0, bottom: 0, height: roadH, child: CustomPaint(painter: _RoadPainter(sec * _speed))),
              Positioned(
                left: 40,
                bottom: bottom - 2,
                width: w * 0.9,
                height: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(40),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 12, spreadRadius: 0)],
                  ),
                ),
              ),
              Positioned(
                left: 40,
                bottom: bottom + bob,
                width: w,
                height: truckH,
                child: Image.network('truck_art.png', fit: BoxFit.fill, filterQuality: FilterQuality.medium, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              ),
            ]);
          },
        );
      }),
    );
  }
}

class _RoadPainter extends CustomPainter {
  const _RoadPainter(this.dist);
  final double dist;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), const [Color(0xFF18223C), Color(0xFF0C1324)]),
    );
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, 3), Paint()..color = const Color(0xFF2A3A63));
    const period = 240.0, dashW = 90.0;
    final dashPaint = Paint()..color = const Color(0xFFE8C46A).withOpacity(0.7);
    final y = size.height * 0.62;
    final shift = dist % period;
    for (var x = -period - shift + period; x < size.width + period; x += period) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, dashW, 5), const Radius.circular(3)), dashPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RoadPainter old) => old.dist != dist;
}
