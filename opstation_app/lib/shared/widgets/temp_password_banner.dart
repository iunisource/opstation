import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../features/auth/providers/auth_controller.dart';
import '../../features/team/data/team_repository.dart';

/// Tappable banner shown on any role home when the current user is on a
/// temporary (admin-reset) password. Tapping opens the Change Password
/// screen. Auto-hides once the user changes their password.
class TempPasswordBanner extends ConsumerWidget {
  const TempPasswordBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider).valueOrNull;
    if (auth == null) return const SizedBox.shrink();

    final repo = ref.watch(teamRepositoryProvider);
    return FutureBuilder(
      future: repo.byId(auth.id),
      builder: (context, snap) {
        final user = snap.data;
        if (user == null || !user.passwordTemporary) {
          return const SizedBox.shrink();
        }
        return InkWell(
          onTap: () => context.push('/account/password'),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.warningLight,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.warningDark.withOpacity(0.3)),
            ),
            child: Row(
              children: const [
                Icon(Icons.lock_reset,
                    color: AppColors.warningDark, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Set your own password',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.warningDark,
                        ),
                      ),
                      Text(
                        'You are using a temporary password set by your administrator.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.warningDark,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: AppColors.warningDark),
              ],
            ),
          ),
        );
      },
    );
  }
}
