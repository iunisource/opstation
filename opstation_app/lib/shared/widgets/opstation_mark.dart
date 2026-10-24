import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The Opstation app-icon tile: blue gradient rounded square with the white
/// ring and green dot. Drawn in code so it stays crisp at any size.
class OpstationLogoTile extends StatelessWidget {
  final double size;
  const OpstationLogoTile({super.key, this.size = 76});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.26),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3B82F6), Color(0xFF1D4ED8)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2563EB).withValues(alpha: 0.32),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(size * 0.16),
        child: const CustomPaint(painter: OpstationMarkPainter()),
      ),
    );
  }
}

/// White ring with a green "route stop" dot set in a small gap, top-right.
class OpstationMarkPainter extends CustomPainter {
  final Color ringColor;
  const OpstationMarkPainter({this.ringColor = Colors.white});

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    final c = Offset(size.width / 2, size.height / 2);
    final r = s * 0.36;
    final ring = s * 0.125;
    const a = -math.pi / 4;
    final dc = c + Offset(r * math.cos(a), r * math.sin(a));

    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = ringColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = ring,
    );
    canvas.drawCircle(dc, ring * 1.15, Paint()..blendMode = BlendMode.clear);
    canvas.drawCircle(dc, ring * 0.8, Paint()..color = const Color(0xFF34D399));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant OpstationMarkPainter old) => old.ringColor != ringColor;
}
