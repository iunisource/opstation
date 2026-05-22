import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/initial_avatar.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../models/team_user.dart';
import '../providers/team_controller.dart';

class TeamListScreen extends ConsumerStatefulWidget {
  /// If set, the role filter is pre-selected when the screen opens.
  /// Used by the Drivers stat tile on the admin dashboard to jump
  /// straight to the filtered driver list.
  final UserRole? initialRoleFilter;
  const TeamListScreen({super.key, this.initialRoleFilter});

  @override
  ConsumerState<TeamListScreen> createState() => _TeamListScreenState();
}

class _TeamListScreenState extends ConsumerState<TeamListScreen> {
  final _searchCtrl = TextEditingController();
  bool _filterApplied = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialRoleFilter != null) {
      // Apply the pre-selected role filter after the first frame so the
      // provider is ready.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_filterApplied && mounted) {
          _filterApplied = true;
          final filters = ref.read(teamControllerProvider).valueOrNull?.filters;
          if (filters != null) {
            ref.read(teamControllerProvider.notifier).updateFilters(
                  filters.copyWith(roleFilter: widget.initialRoleFilter),
                );
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = canManageTeam(user?.role);
    final async = ref.watch(teamControllerProvider);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Team',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/admin/team/new'),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('New user'),
            )
          : null,
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (state) => _buildBody(state, canManage),
      ),
    );
  }

  Widget _buildBody(TeamState state, bool canManage) {
    final filtered = state.filtered;
    final filters = state.filters;

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) {
              ref.read(teamControllerProvider.notifier).updateFilters(
                  filters.copyWith(query: v));
            },
            decoration: InputDecoration(
              hintText: 'Search name, email, phone...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: filters.query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        ref
                            .read(teamControllerProvider.notifier)
                            .updateFilters(filters.copyWith(query: ''));
                      },
                    ),
            ),
          ),
        ),
        // Role filter chips
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _RoleFilterChip(
                label: 'All',
                selected: filters.roleFilter == null,
                onTap: () => ref
                    .read(teamControllerProvider.notifier)
                    .updateFilters(filters.copyWith(clearRole: true)),
              ),
              for (final r in [
                UserRole.admin,
                UserRole.salesperson,
                UserRole.surveyor,
                UserRole.dispatchManager,
                UserRole.driver,
              ])
                _RoleFilterChip(
                  label: r.label,
                  selected: filters.roleFilter == r,
                  count: state.countByRole[r] ?? 0,
                  onTap: () => ref
                      .read(teamControllerProvider.notifier)
                      .updateFilters(filters.copyWith(roleFilter: r)),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
          child: Row(
            children: [
              Text(
                '${filtered.length} of ${state.all.where((u) => u.isActive).length} active',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondaryLight,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  ref.read(teamControllerProvider.notifier).updateFilters(
                      filters.copyWith(
                          includeInactive: !filters.includeInactive));
                },
                icon: Icon(
                  filters.includeInactive
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 16,
                ),
                label: Text(
                  filters.includeInactive ? 'Hide inactive' : 'Show inactive',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No users match your filters.'))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => _UserTile(user: filtered[i]),
                ),
        ),
      ],
    );
  }
}

class _UserTile extends StatelessWidget {
  final TeamUser user;
  const _UserTile({required this.user});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.push('/admin/team/${user.id}'),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Row(
          children: [
            InitialAvatar(initials: user.initials),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          user.name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!user.isActive)
                        const StatusBadge(
                            label: 'Inactive', tone: StatusBadgeTone.neutral),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user.email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondaryLight,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _MiniChip(text: user.role.label),
                      if (user.passwordTemporary) ...[
                        const SizedBox(width: 6),
                        const _MiniChip(
                          text: 'Temp password',
                          color: AppColors.warningDark,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                size: 20, color: AppColors.textTertiaryLight),
          ],
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String text;
  final Color? color;
  const _MiniChip({required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textSecondaryLight;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: c,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _RoleFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final int? count;
  final VoidCallback onTap;

  const _RoleFilterChip({
    required this.label,
    required this.selected,
    this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.borderLight,
            ),
          ),
          child: Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? Colors.white
                      : Theme.of(context).textTheme.bodyMedium?.color,
                ),
              ),
              if (count != null && count! > 0) ...[
                const SizedBox(width: 4),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? Colors.white.withOpacity(0.8)
                        : AppColors.textSecondaryLight,
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
