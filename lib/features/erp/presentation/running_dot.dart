import 'package:flutter/material.dart';

/// A small pulsing dot that signals a job card is currently being processed
/// (driven by job_cards.is_running). Used in the job card drawer, the kanban
/// board, the table view, and the Production Floor dashboard.
class RunningDot extends StatefulWidget {
  final double size;
  final Color color;
  final bool withLabel;
  final String label;
  const RunningDot({
    super.key,
    this.size = 8,
    this.color = const Color(0xFF22C55E),
    this.withLabel = false,
    this.label = 'In progress',
  });

  @override
  State<RunningDot> createState() => _RunningDotState();
}

class _RunningDotState extends State<RunningDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 850))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = FadeTransition(
      opacity: Tween<double>(begin: 1.0, end: 0.2).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: widget.color.withOpacity(0.6), blurRadius: 5, spreadRadius: 1)],
        ),
      ),
    );
    if (!widget.withLabel) return dot;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      dot,
      const SizedBox(width: 5),
      Text(widget.label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: widget.color)),
    ]);
  }
}
