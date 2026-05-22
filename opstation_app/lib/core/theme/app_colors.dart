import 'package:flutter/material.dart';

/// Opstation color tokens — extracted from existing app screenshots.
/// All values intentionally flat (no gradients) to match the app's look.
class AppColors {
  AppColors._();

  // Primary — royal blue used for CTAs, active states
  static const Color primary = Color(0xFF2563EB);
  static const Color primaryDark = Color(0xFF1E40AF);
  static const Color primaryLight = Color(0xFFDBEAFE);

  // Success — green used for start actions, verified states
  static const Color success = Color(0xFF10B981);
  static const Color successDark = Color(0xFF059669);
  static const Color successLight = Color(0xFFD1FAE5);

  // Warning — amber for pending, below-range, skipped
  static const Color warning = Color(0xFFF59E0B);
  static const Color warningDark = Color(0xFFB45309);
  static const Color warningLight = Color(0xFFFEF3C7);

  // Danger — red for alerts, below-threshold scores, errors
  static const Color danger = Color(0xFFEF4444);
  static const Color dangerDark = Color(0xFFB91C1C);
  static const Color dangerLight = Color(0xFFFEE2E2);

  // Info / secondary accents
  static const Color info = Color(0xFF3B82F6);
  static const Color infoLight = Color(0xFFEFF6FF);

  // Purple — used for live-monitoring last-visit pins
  static const Color accent = Color(0xFF8B5CF6);
  static const Color accentLight = Color(0xFFF3E8FF);

  // Neutrals (light mode)
  static const Color scaffoldLight = Color(0xFFF8F9FB);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color borderLight = Color(0xFFE5E7EB);
  static const Color textPrimaryLight = Color(0xFF0F172A);
  static const Color textSecondaryLight = Color(0xFF64748B);
  static const Color textTertiaryLight = Color(0xFF94A3B8);

  // Neutrals (dark mode)
  static const Color scaffoldDark = Color(0xFF0B1120);
  static const Color surfaceDark = Color(0xFF111827);
  static const Color borderDark = Color(0xFF1F2937);
  static const Color textPrimaryDark = Color(0xFFF8FAFC);
  static const Color textSecondaryDark = Color(0xFFCBD5E1);
  static const Color textTertiaryDark = Color(0xFF94A3B8);
}
