import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A lightweight, app-wide "processing" overlay shown while a voucher is being
/// saved or posted. It dims the screen, blocks input (so a user can't double-
/// submit), and shows a fast-moving animation so it's obvious something is
/// happening.
///
/// Usage — bracket the async work:
///   SavingOverlay.show(context);
///   try { ...await save/post... } finally { SavingOverlay.hide(); }
///
/// show()/hide() are reference-counted, so nested or sequential calls are safe
/// and the overlay only disappears once every caller has released it.
class SavingOverlay {
  SavingOverlay._();

  static OverlayEntry? _entry;
  static int _count = 0;

  static void show(BuildContext context, {String label = 'Saving…'}) {
    _count++;
    if (_entry != null) return; // already visible
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      _count--; // no overlay to attach to — nothing to show
      return;
    }
    _entry = OverlayEntry(builder: (_) => _SavingBarrier(label: label));
    overlay.insert(_entry!);
  }

  static void hide() {
    if (_count > 0) _count--;
    if (_count == 0) {
      _entry?.remove();
      _entry = null;
    }
  }
}

class _SavingBarrier extends StatelessWidget {
  const _SavingBarrier({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        children: [
          // Dim + swallow all pointer events (prevents double-submit).
          const ModalBarrier(dismissible: false, color: Color(0x33101729)),
          // Fast indeterminate bar pinned to the very top.
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SizedBox(
              height: 3,
              child: LinearProgressIndicator(
                minHeight: 3,
                backgroundColor: Color(0x1A2F6FED),
                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primary),
              ),
            ),
          ),
          // Centered card with a fast spinner + label.
          Center(
            child: Material(
              color: Colors.white,
              elevation: 12,
              shadowColor: const Color(0x332F6FED),
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _FastSpinner(size: 40),
                    const SizedBox(height: 14),
                    Text(
                      label,
                      style: const TextStyle(
                        color: Color(0xFF0F1729),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Please wait',
                      style: TextStyle(
                        color: const Color(0xFF0F1729).withOpacity(0.45),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A fast-spinning gradient ring — reads as "actively processing" more clearly
/// than the default (slower) CircularProgressIndicator.
class _FastSpinner extends StatefulWidget {
  const _FastSpinner({this.size = 40});
  final double size;

  @override
  State<_FastSpinner> createState() => _FastSpinnerState();
}

class _FastSpinnerState extends State<_FastSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650), // fast
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
          painter: _RingPainter(_c.value),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.t);
  final double t; // 0..1

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    const stroke = 4.0;
    final inner = rect.deflate(stroke / 2);

    // Track.
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = const Color(0x142F6FED);
    canvas.drawArc(inner, 0, 6.28318, false, track);

    // Moving arc (sweep gradient so it looks like it's whipping around).
    final sweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke
      ..shader = SweepGradient(
        colors: const [Color(0x002F6FED), AppTheme.primary],
        stops: const [0.0, 1.0],
        transform: GradientRotation(t * 6.28318),
      ).createShader(inner);
    final start = t * 6.28318;
    canvas.drawArc(inner, start, 4.2, false, sweep);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.t != t;
}
