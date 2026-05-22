import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Generic "coming soon" placeholder for tiles whose backing feature
/// isn't built yet but is on the roadmap. Gives the user a clear
/// message instead of a dead tap target.
class ComingSoonScreen extends StatelessWidget {
  /// Appears in the app bar.
  final String title;

  /// Big heading inside the body.
  final String heading;

  /// Couple of sentences explaining what the feature will do and why
  /// it isn't built yet.
  final String description;

  /// Small dotted list of what's planned.
  final List<String> bullets;

  /// Icon shown above the heading. Defaults to a clock.
  final IconData icon;

  const ComingSoonScreen({
    super.key,
    required this.title,
    required this.heading,
    required this.description,
    this.bullets = const [],
    this.icon = Icons.schedule_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 28, color: AppColors.primary),
              ),
              const SizedBox(height: 18),
              Text(
                heading,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.warningLight,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'Coming soon',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: AppColors.warningDark,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                description,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: AppColors.textSecondaryLight,
                ),
              ),
              if (bullets.isNotEmpty) ...[
                const SizedBox(height: 20),
                const Text(
                  "What's planned:",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
                const SizedBox(height: 8),
                for (final b in bullets)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 6, right: 10),
                          child: Icon(Icons.circle,
                              size: 5, color: AppColors.textTertiaryLight),
                        ),
                        Expanded(
                          child: Text(
                            b,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
