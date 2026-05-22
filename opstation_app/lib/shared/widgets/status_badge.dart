import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

enum StatusBadgeTone { info, success, warning, danger, neutral }

class StatusBadge extends StatelessWidget {
  final String label;
  final StatusBadgeTone tone;
  final IconData? icon;

  const StatusBadge({
    super.key,
    required this.label,
    this.tone = StatusBadgeTone.neutral,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _colors(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  (Color, Color) _colors(StatusBadgeTone t) {
    switch (t) {
      case StatusBadgeTone.info:
        return (AppColors.primaryLight, AppColors.primaryDark);
      case StatusBadgeTone.success:
        return (AppColors.successLight, AppColors.successDark);
      case StatusBadgeTone.warning:
        return (AppColors.warningLight, AppColors.warningDark);
      case StatusBadgeTone.danger:
        return (AppColors.dangerLight, AppColors.dangerDark);
      case StatusBadgeTone.neutral:
        return (AppColors.borderLight, AppColors.textSecondaryLight);
    }
  }
}
