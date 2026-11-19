import 'package:flutter/material.dart';

/// Wraps a button with a slow, soft pulsing glow to draw the eye. It is a gentle
/// pulse (about one every 1.6 s), not a strobe. It stops when [active] is false
/// and whenever the device asks for reduced motion.
class PulseAttention extends StatefulWidget {
  final bool active;
  final Color color;
  final double radius;
  final Widget child;
  const PulseAttention({
    super.key,
    required this.active,
    required this.child,
    this.color = const Color(0xFFF59E0B),
    this.radius = 10,
  });

  @override
  State<PulseAttention> createState() => _PulseAttentionState();
}

class _PulseAttentionState extends State<PulseAttention> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant PulseAttention oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.active) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active || MediaQuery.of(context).disableAnimations) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (_, child) {
        final t = Curves.easeInOut.transform(_c.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            boxShadow: [
              BoxShadow(color: widget.color.withOpacity(0.15 + 0.45 * t), blurRadius: 4 + 10 * t, spreadRadius: 0.5 + 2.5 * t),
            ],
          ),
          child: child,
        );
      },
    );
  }
}
