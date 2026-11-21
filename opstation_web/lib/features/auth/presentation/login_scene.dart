import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The still background of the login page: deep blue with soft light trails, the same look as the video.
/// It is what shows on phones, slow connections, with reduced motion, while the video loads and if it
/// cannot play, so the page always looks finished.
class LoginScenePainter extends CustomPainter {
  const LoginScenePainter({this.seed = 11, this.density = 34});

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
      final y0 = between(0.40 * h, 1.12 * h);
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
            const [0, 0.5, 1],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant LoginScenePainter old) => old.seed != seed || old.density != density;
}
