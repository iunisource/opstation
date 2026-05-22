import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Bottom sheet shown after a trip is completed — picker between
/// Visit Report and Trip Summary. Both are Slice 7 stubs for now.
class ExportReportSheet extends StatelessWidget {
  const ExportReportSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: AppColors.borderLight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Export report',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            _ExportOption(
              icon: Icons.fact_check_outlined,
              iconBg: AppColors.primaryLight,
              iconFg: AppColors.primary,
              title: 'Visit report',
              subtitle: 'Detailed visit log with GPS and collections',
              onTap: () {
                Navigator.of(context).pop();
                _showStubToast(context, 'Visit report');
              },
            ),
            const SizedBox(height: 10),
            _ExportOption(
              icon: Icons.map_outlined,
              iconBg: AppColors.successLight,
              iconFg: AppColors.successDark,
              title: 'Trip summary',
              subtitle: 'Distance chain between verified stops',
              onTap: () {
                Navigator.of(context).pop();
                _showStubToast(context, 'Trip summary');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showStubToast(BuildContext context, String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$name — PDF generation is built in Slice 7.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

class _ExportOption extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final Color iconFg;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ExportOption({
    required this.icon,
    required this.iconBg,
    required this.iconFg,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: iconFg),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppColors.textSecondaryLight,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
