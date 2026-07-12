import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';

const _kLastRoleKey = 'opstation_last_login_role';

/// Remembers which door the person came through last, so the picker is a
/// one-time cost per device rather than a tap every staff member pays daily.
Future<String?> lastLoginRole() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kLastRoleKey);
}

Future<void> setLastLoginRole(String? role) async {
  final prefs = await SharedPreferences.getInstance();
  if (role == null) {
    await prefs.remove(_kLastRoleKey);
  } else {
    await prefs.setString(_kLastRoleKey, role);
  }
}

class RolePickerScreen extends ConsumerWidget {
  const RolePickerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RetailerLocaleScope(
      child: Builder(builder: (context) {
        final t = T.of(context);
        return Scaffold(
          body: Container(
            // A soft wash rather than a flat white void — the previous screen
            // read as "unfinished" mostly because nothing occupied the space.
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.primary.withValues(alpha: 0.07),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.45],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  // Language sits top-right, reachable before anything else.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: const LanguageToggle(),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(height: 34),
                            // Fixed square. Previously this sat inside a
                            // stretch-aligned Column, so it was pulled to full
                            // width and read as a big blue slab, not a logo.
                            Center(
                              child: Container(
                                height: 76,
                                width: 76,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: AppColors.primary,
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.primary
                                          .withValues(alpha: 0.30),
                                      blurRadius: 22,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: const Text(
                                  'O',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 40,
                                    fontWeight: FontWeight.w800,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            const Text(
                              'Opstation',
                              style: TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 30),
                            Text(
                              t.whoAreYou,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondaryLight,
                              ),
                            ),
                            const SizedBox(height: 16),
                            _RoleCard(
                              icon: Icons.badge_outlined,
                              title: t.staff,
                              subtitle: t.staffSub,
                              onTap: () async {
                                await setLastLoginRole('staff');
                                if (context.mounted) context.go('/login');
                              },
                            ),
                            const SizedBox(height: 12),
                            _RoleCard(
                              icon: Icons.storefront_outlined,
                              title: t.retailer,
                              subtitle: t.retailerSub,
                              onTap: () async {
                                await setLastLoginRole('retailer');
                                if (context.mounted) context.go('/r/login');
                              },
                            ),
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(children: [
            Container(
              height: 48,
              width: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: AppColors.primary, size: 23),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          color: AppColors.textSecondaryLight)),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 20, color: AppColors.textSecondaryLight),
          ]),
        ),
      ),
    );
  }
}
