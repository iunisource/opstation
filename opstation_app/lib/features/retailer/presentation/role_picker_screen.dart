import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';

const _kLastRoleKey = 'opstation_last_login_role';

/// Remembers which door the person came through last, so the picker is a
/// one-time cost per device rather than a tap every staff member pays daily.
/// Read by the router: if a choice is stored, boot straight to that login.
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
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Align(
                        alignment: Alignment.centerRight,
                        child: LanguageToggle(),
                      ),
                      const SizedBox(height: 28),
                      Container(
                        height: 56,
                        width: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Text('O',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        t.whoAreYou,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 24),
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
                    ],
                  ),
                ),
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
        ),
        child: Row(children: [
          Container(
            height: 44,
            width: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: AppColors.primary, size: 22),
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
                        fontSize: 13, color: AppColors.textSecondaryLight)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, size: 20),
        ]),
      ),
    );
  }
}
