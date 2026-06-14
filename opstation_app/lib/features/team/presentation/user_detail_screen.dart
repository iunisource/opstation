import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/initial_avatar.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../models/team_user.dart';
import '../providers/team_controller.dart';
import 'widgets/route_assignments_card.dart';

class UserDetailScreen extends ConsumerWidget {
  final String userId;
  const UserDetailScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actor = ref.watch(authControllerProvider).valueOrNull;
    final async = ref.watch(teamControllerProvider);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('User',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          _EditButton(userId: userId),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (state) {
          final match = state.all.where((u) => u.id == userId).toList();
          if (match.isEmpty) {
            return const Center(child: Text('User not found.'));
          }
          final canEdit = canEditTargetUser(
            actor: actor?.role,
            targetRole: match.first.role,
          );
          return _Body(user: match.first, canManage: canEdit);
        },
      ),
    );
  }
}

class _EditButton extends ConsumerWidget {
  final String userId;
  const _EditButton({required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actor = ref.watch(authControllerProvider).valueOrNull;
    final async = ref.watch(teamControllerProvider);
    final matches = async.valueOrNull?.all
            .where((u) => u.id == userId)
            .toList() ??
        const [];
    if (matches.isEmpty) return const SizedBox.shrink();
    final target = matches.first;
    final canEdit = canEditTargetUser(
      actor: actor?.role,
      targetRole: target.role,
    );
    if (!canEdit) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(Icons.edit_outlined),
      tooltip: 'Edit',
      onPressed: () => context.push('/admin/team/$userId/edit'),
    );
  }
}

class _Body extends ConsumerWidget {
  final TeamUser user;
  final bool canManage;

  const _Body({required this.user, required this.canManage});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _HeaderCard(user: user),
        const SizedBox(height: 16),
        _InfoCard(user: user),
        if (user.role == UserRole.salesperson) ...[
          const SizedBox(height: 16),
          RouteAssignmentsCard(user: user, canManage: canManage),
        ],
        if (canManage) ...[
          const SizedBox(height: 16),
          _PasswordCard(user: user),
          const SizedBox(height: 16),
          _DangerZone(user: user),
        ],
        const SizedBox(height: 32),
      ],
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final TeamUser user;
  const _HeaderCard({required this.user});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        children: [
          InitialAvatar(initials: user.initials),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user.name,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  user.email,
                  style: const TextStyle(
                    color: AppColors.textSecondaryLight,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    StatusBadge(
                      label: user.isActive ? 'Active' : 'Inactive',
                      tone: user.isActive
                          ? StatusBadgeTone.success
                          : StatusBadgeTone.neutral,
                    ),
                    _RolePill(text: user.role.label),
                    if (user.passwordTemporary)
                      const StatusBadge(
                        label: 'Temp password',
                        tone: StatusBadgeTone.warning,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final TeamUser user;
  const _InfoCard({required this.user});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('Profile'),
          const SizedBox(height: 10),
          _row(Icons.phone, user.phone.isEmpty ? '—' : user.phone),
          _row(
            Icons.calendar_today_outlined,
            'Joined ${DateFormat('d MMM yyyy').format(user.createdAt)}',
          ),
          if (user.updatedAt != null)
            _row(
              Icons.update,
              'Last updated ${DateFormat('d MMM yyyy · HH:mm').format(user.updatedAt!)}',
            ),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textSecondaryLight),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 14)),
          ),
        ],
      ),
    );
  }
}

class _PasswordCard extends ConsumerWidget {
  final TeamUser user;
  const _PasswordCard({required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('Password'),
          const SizedBox(height: 8),
          Text(
            user.passwordTemporary
                ? 'User is on a temporary password. Ask them to log in and change it.'
                : 'User has set their own password.',
            style: const TextStyle(
              color: AppColors.textSecondaryLight,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _promptReset(context, ref),
              icon: const Icon(Icons.lock_reset, size: 18),
              label: const Text('Reset password'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 44),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _promptReset(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final newPw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Set a new password for ${user.name}.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'New password (min 6 chars)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final v = ctrl.text.trim();
              if (v.length >= 6) Navigator.of(ctx).pop(v);
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (newPw != null && newPw.length >= 6) {
      try {
        await ref
            .read(teamControllerProvider.notifier)
            .resetPassword(user.id, newPw);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Password updated. The user can sign in with it now.'),
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: AppColors.danger,
              content: Text(e is StateError ? e.message : 'Reset failed: $e'),
            ),
          );
        }
      }
    }
  }
}

class _DangerZone extends ConsumerWidget {
  final TeamUser user;
  const _DangerZone({required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actor = ref.watch(authControllerProvider).valueOrNull;
    // Don't let a user deactivate themselves.
    final isSelf = actor?.id == user.id;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.dangerLight.withOpacity(0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.danger.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Danger zone',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.dangerDark,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isSelf
                ? 'You cannot deactivate your own account.'
                : (user.isActive
                    ? 'Deactivating blocks this user from signing in but preserves all their history.'
                    : 'Activating restores this user\'s access.'),
            style: const TextStyle(
              color: AppColors.textSecondaryLight,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: isSelf
                  ? null
                  : () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: Text(user.isActive
                              ? 'Deactivate user?'
                              : 'Activate user?'),
                          content: Text(user.name),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(context).pop(false),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              onPressed: () =>
                                  Navigator.of(context).pop(true),
                              child: Text(user.isActive
                                  ? 'Deactivate'
                                  : 'Activate'),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        await ref
                            .read(teamControllerProvider.notifier)
                            .setActive(user.id, !user.isActive);
                      }
                    },
              icon: Icon(user.isActive ? Icons.block : Icons.check),
              label: Text(user.isActive ? 'Deactivate' : 'Activate'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.dangerDark,
                side: BorderSide(color: AppColors.danger.withOpacity(0.4)),
                minimumSize: const Size(0, 44),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  final String text;
  const _RolePill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.borderLight,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: AppColors.textSecondaryLight,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: AppColors.textSecondaryLight,
      ),
    );
  }
}
