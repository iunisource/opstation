import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Square avatar with initials, used widely in customer and user lists.
class InitialAvatar extends StatelessWidget {
  final String initials;
  final double size;
  final Color? background;
  final Color? foreground;

  const InitialAvatar({
    super.key,
    required this.initials,
    this.size = 44,
    this.background,
    this.foreground,
  });

  /// Derive a stable tinted background from the initials so different
  /// people/shops get visually distinct tiles.
  static (Color bg, Color fg) _tint(String initials) {
    final palettes = [
      (AppColors.primaryLight, AppColors.primaryDark),
      (AppColors.successLight, AppColors.successDark),
      (AppColors.warningLight, AppColors.warningDark),
      (AppColors.dangerLight, AppColors.dangerDark),
      (AppColors.accentLight, AppColors.accent),
      (AppColors.infoLight, AppColors.info),
    ];
    final seed = initials.codeUnits.fold<int>(0, (a, b) => a + b);
    return palettes[seed % palettes.length];
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = (background != null && foreground != null)
        ? (background!, foreground!)
        : _tint(initials);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.36,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
