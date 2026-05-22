import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Compact stat cell used in the Verified/Outside/Skipped/Pending row
/// at the top of the route-in-progress screen.
class StatusCountCell extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final int count;
  final String label;

  const StatusCountCell({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.count,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: iconColor, size: 22),
        const SizedBox(height: 6),
        Text(
          count.toString(),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondaryLight,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
