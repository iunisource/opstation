import 'package:flutter/material.dart';

/// Small uppercase label used above sections on dashboards
/// (e.g. "TODAY'S ROUTES", "ALWAYS AVAILABLE").
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7);
    return Row(
      children: [
        Text(
          text.toUpperCase(),
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}
