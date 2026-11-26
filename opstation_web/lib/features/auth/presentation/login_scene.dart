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
/// form. The wheels turn. Only on wide screens; it stands still when the device asks for less motion.
class LoginRoadTruck extends StatefulWidget {
  const LoginRoadTruck({super.key, this.minWidth = 700});

  /// The truck is left out when the space is narrower than this (the sign-in page needs 700; the narrower sign-up panel uses less).
  final double minWidth;

  @override
  State<LoginRoadTruck> createState() => _LoginRoadTruckState();
}

class _LoginRoadTruckState extends State<LoginRoadTruck> with SingleTickerProviderStateMixin {
  // One hour per cycle; the time in seconds is read from the value, so nothing visibly restarts.
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(hours: 1));

  static const _imgW = 1100.0, _imgH = 742.0;
  static const _speed = 200.0; // pixels per second the road moves

  // The two wheels you can see, in the truck picture's own pixels: centre, half-width and half-height of the
  // rim as it appears (the truck is seen at an angle, so the rim is an ellipse), and the tyre's radius.
  static const _wheels = [
    (file: 'truck_rim_r.png', cx: 199.0, cy: 590.0, a: 20.0, b: 40.0, tire: 72.0),
    (file: 'truck_rim_f.png', cx: 672.0, cy: 618.0, a: 34.0, b: 52.0, tire: 88.0),
  ];

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
        if (h < 520 || c.maxWidth < widget.minWidth) return const SizedBox.shrink();
        // The truck lives mostly inside the road band so it never climbs into the headline or the feature chips.
        // Laptop screens (up to 1440 px wide) keep the size they have always had; wider screens grow the
        // whole scene in proportion (truck, road, dashes, speed), up to 1.8 times.
        final k = (c.maxWidth / 1440.0).clamp(1.0, 1.8);
        final roadH = (h * 0.22).clamp(100.0, 170.0) * k;
        final truckH = roadH * 1.1;
        final w = truckH * _imgW / _imgH;
        final s = w / _imgW;
        final bottom = roadH * 0.5;
        final speed = _speed * k;
        return AnimatedBuilder(
          animation: _c,
          builder: (_, __) {
            final sec = _c.value * 3600.0;
            final bob = math.sin(sec * 7) * 0.9 * k;
            return Stack(children: [
              Positioned(left: 0, right: 0, bottom: 0, height: roadH, child: CustomPaint(painter: _RoadPainter(sec * speed, scale: k))),
              Positioned(
                left: 40 * k,
                bottom: bottom - 2 * k,
                width: w * 0.9,
                height: 6 * k,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(40),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 12, spreadRadius: 0)],
                  ),
                ),
              ),
              Positioned(
                left: 40 * k,
                bottom: bottom + bob,
                width: w,
                height: truckH,
                child: Stack(children: [
                  Positioned.fill(
                    child: Image.network('truck_peacock.png', fit: BoxFit.fill, filterQuality: FilterQuality.medium, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                  ),
                  // The rims turn at the speed of the road. Each is a round picture turned in its own plane, then
                  // squeezed to the oval it shows on the truck.
                  for (final wh in _wheels)
                    Positioned(
                      left: (wh.cx - wh.b) * s,
                      top: (wh.cy - wh.b) * s,
                      width: wh.b * 2 * s,
                      height: wh.b * 2 * s,
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.diagonal3Values(wh.a / wh.b, 1, 1),
                        child: Transform.rotate(
                          angle: sec * speed / (wh.tire * s),
                          child: Image.network(wh.file, fit: BoxFit.fill, filterQuality: FilterQuality.medium, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                        ),
                      ),
                    ),
                ]),
              ),
            ]);
          },
        );
      }),
    );
  }
}

/// The sign-up page's scene: the godown in the background and the three vehicles of the distribution chain
/// (the painted truck, the pickup, the salesman on his bike) side by side on the road. The vehicles stay put (with a
/// slight sway), the road slides under them and all the wheels turn. It stands still when the device asks for less motion.
class LoginFleetScene extends StatefulWidget {
  const LoginFleetScene({super.key, this.minWidth = 400});

  final double minWidth;

  /// Height the scene needs at the bottom of a panel [h] high, so the words above it can stay clear.
  static double reserve(double h, double w) {
    if (h < 520 || w < 400) return 0;
    final roadH = (h * 0.22).clamp(100.0, 170.0);
    final whH = _whHeight(h, roadH);
    final u = _unit(w, roadH);
    final vehicles = roadH * 0.5 + 107 * u + 10;
    final godown = whH > 0 ? roadH * 0.62 + whH + 16 : 0.0;
    return math.max(vehicles, godown);
  }

  static double _whHeight(double h, double roadH) => h >= 880 ? roadH * 1.9 : (h >= 700 ? roadH * 1.15 : 0);
  static double _unit(double w, double roadH) => math.min((w - 96) / 386.0, roadH * 1.15 / 107.0);

  @override
  State<LoginFleetScene> createState() => _LoginFleetSceneState();
}

class _LoginFleetSceneState extends State<LoginFleetScene> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(hours: 1));
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

  Widget _img(String f) => Image.network(f, fit: BoxFit.fill, filterQuality: FilterQuality.medium, errorBuilder: (_, __, ___) => const SizedBox.shrink());

  /// A vehicle [wUnits] wide (the unit [u] is the same for all three), whose picture is [srcW] x [srcH] pixels.
  Widget _vehicle(double u, double left, double ground, double wUnits, double srcW, double srcH, String file,
      {List<Widget> Function(double s)? behind, List<Widget> Function(double s)? over, double bob = 0}) {
    final w = wUnits * u;
    final s = w / srcW;
    final h = srcH * s;
    return Stack(clipBehavior: Clip.none, children: [
      Positioned(
        left: left,
        bottom: ground - 2,
        width: w,
        height: 7,
        child: DecoratedBox(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(40), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 10)]),
        ),
      ),
      Positioned(
        left: left,
        bottom: ground - 6 * u + bob,
        width: w,
        height: h,
        child: Stack(clipBehavior: Clip.none, children: [
          if (behind != null) ...behind(s),
          Positioned.fill(child: _img(file)),
          if (over != null) ...over(s),
        ]),
      ),
    ]);
  }

  Widget _rim(String file, double cx, double cy, double a, double b, double tire, double s, double dist) => Positioned(
        left: (cx - b) * s,
        top: (cy - b) * s,
        width: b * 2 * s,
        height: b * 2 * s,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(a / b, 1, 1),
          child: Transform.rotate(angle: dist / (tire * s), child: _img(file)),
        ),
      );

  Widget _disc(String file, double cx, double cy, double r, double tire, double s, double dist) => Positioned(
        left: (cx - r) * s,
        top: (cy - r) * s,
        width: r * 2 * s,
        height: r * 2 * s,
        child: Transform.rotate(angle: dist / (tire * s), child: _img(file)),
      );

  Widget _spokes(double cx, double cy, double a, double b, double tire, double s, double dist) => Positioned(
        left: (cx - a) * s,
        top: (cy - b) * s,
        width: a * 2 * s,
        height: b * 2 * s,
        child: CustomPaint(painter: _SpokePainter(dist / (tire * s))),
      );

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, c) {
        final h = c.maxHeight, w = c.maxWidth;
        if (h < 520 || w < widget.minWidth) return const SizedBox.shrink();
        final roadH = (h * 0.22).clamp(100.0, 170.0);
        final whH = LoginFleetScene._whHeight(h, roadH);
        final u = LoginFleetScene._unit(w, roadH);
        final total = 386 * u;
        final x0 = (w - total) / 2;
        final ground = roadH * 0.5;
        return ClipRect(child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) {
            final sec = _c.value * 3600.0;
            final dist = sec * _speed;
            double bob(double ph) => math.sin(sec * 7 + ph) * 0.8;
            return Stack(clipBehavior: Clip.none, children: [
              if (whH > 0)
                Positioned(
                  left: (w - whH * 722 / 513) / 2,
                  bottom: roadH * 0.62,
                  height: whH,
                  width: whH * 722 / 513,
                  child: Opacity(opacity: 0.94, child: _img('fleet_warehouse.png')),
                ),
              Positioned(left: 0, right: 0, bottom: 0, height: roadH, child: CustomPaint(painter: _RoadPainter(dist))),
              // The painted truck (picture cut to 1023 x 698 px).
              _vehicle(u, x0, ground, 128, 1023, 698, 'fleet_truck.webp', bob: bob(0), over: (s) => [
                    _rim('fleet_rim_r.webp', 141, 579, 20, 40, 72, s, dist),
                    _rim('fleet_rim_f.webp', 614, 607, 34, 52, 88, s, dist),
                  ]),
              // The pickup (1169 x 800 px): the rim of each wheel turns.
              _vehicle(u, x0 + (128 + 14) * u, ground, 132, 1169, 800, 'fleet_pickup.webp', bob: bob(1.7), over: (s) => [
                    _disc('fleet_pw_r.webp', 253, 587, 57, 98, s, dist),
                    _disc('fleet_pw_f.webp', 897, 585, 57, 98, s, dist),
                  ]),
              // The salesman's bike (723 x 788 px): its spokes turn behind the frame.
              _vehicle(u, x0 + (128 + 14 + 132 + 14) * u, ground, 98, 723, 788, 'fleet_bike.webp', bob: bob(3.1), behind: (s) => [
                    _spokes(161, 604, 67, 90, 100, s, dist),
                    _spokes(613, 640, 82, 82, 114, s, dist),
                  ]),
            ]);
          },
        ));
      }),
    );
  }
}

class _SpokePainter extends CustomPainter {
  const _SpokePainter(this.angle);
  final double angle;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.height / 2 * 0.94;
    final r0 = r * 0.28;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(size.width / size.height, 1);
    canvas.rotate(angle);
    final p = Paint()
      ..color = const Color(0xD9E4E8EF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.7, size.height * 0.012);
    const n = 36;
    for (var i = 0; i < n; i++) {
      final th = 2 * math.pi * i / n;
      final dl = 0.62 * (i.isOdd ? 1 : -1);
      canvas.drawLine(Offset(r0 * math.cos(th), r0 * math.sin(th)), Offset(r * math.cos(th + dl), r * math.sin(th + dl)), p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SpokePainter old) => old.angle != angle;
}

class _RoadPainter extends CustomPainter {
  const _RoadPainter(this.dist, {this.scale = 1.0});
  final double dist;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), const [Color(0xFF18223C), Color(0xFF0C1324)]),
    );
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, 3 * scale), Paint()..color = const Color(0xFF2A3A63));
    final period = 240.0 * scale, dashW = 90.0 * scale;
    final dashPaint = Paint()..color = const Color(0xFFE8C46A).withOpacity(0.7);
    final y = size.height * 0.62;
    final shift = dist % period;
    for (var x = -period - shift + period; x < size.width + period; x += period) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, dashW, 5 * scale), Radius.circular(3 * scale)), dashPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RoadPainter old) => old.dist != dist || old.scale != scale;
}
