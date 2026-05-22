import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/initial_avatar.dart';
import '../../../shared/widgets/role_home_scaffold.dart';
import '../../../shared/widgets/section_label.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../auth/providers/auth_controller.dart';
import '../../orgs/data/org_repository.dart';
import '../../orgs/models/org.dart';
import '../../team/data/team_repository.dart';
import '../../team/models/team_user.dart';

/// Super Admin home — app-level, not org-level.
///
/// Responsibilities:
///   - Create organizations (each with exactly one Master Admin at
///     creation time)
///   - Enable / disable organizations (disable blocks all login for
///     users in that org; data is preserved)
///   - Rename organizations
///   - View per-org stats (user count, master admin name)
///
/// Out of scope for this screen / this slice:
///   - Org-level data isolation (scoping customers/routes/trips by
///     org_id) — deferred until real sync backend lands
///   - Reassigning a master admin after creation — future slice
///   - Deleting orgs — intentionally not offered (disable is safer)
class SuperAdminHomeScreen extends ConsumerStatefulWidget {
  const SuperAdminHomeScreen({super.key});

  @override
  ConsumerState<SuperAdminHomeScreen> createState() =>
      _SuperAdminHomeScreenState();
}

class _SuperAdminHomeScreenState
    extends ConsumerState<SuperAdminHomeScreen> {
  Future<_SuperAdminData> _load() async {
    final orgRepo = ref.read(orgRepositoryProvider);
    final team = ref.read(teamRepositoryProvider);
    final orgs = await orgRepo.all();
    final allUsers = await team.all(includeInactive: true);
    // Group users by org for counts + master-admin name lookup.
    final usersByOrg = <String, List<TeamUser>>{};
    final userById = <String, TeamUser>{};
    for (final u in allUsers) {
      userById[u.id] = u;
    }
    final orgViews = <_OrgView>[];
    for (final org in orgs) {
      final count = await orgRepo.userCount(org.id);
      final adminName = org.masterAdminId == null
          ? 'Unassigned'
          : (userById[org.masterAdminId]?.name ?? 'Unassigned');
      orgViews.add(_OrgView(
        org: org,
        userCount: count,
        masterAdminName: adminName,
      ));
      usersByOrg[org.id] = [];
    }
    return _SuperAdminData(orgs: orgViews);
  }

  Future<void> _refresh() async {
    setState(() {});
  }

  Future<void> _openNewOrgSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _NewOrgSheet(),
    );
    if (created == true) await _refresh();
  }

  Future<void> _openOrgDetail(_OrgView view) async {
    final changed = await context.push<bool>(
      '/super-admin/org/${view.org.id}',
    );
    if (changed == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final firstName = user?.name.split(' ').first ?? 'Admin';

    return RoleHomeScaffold(
      appBarTitle: 'Opstation',
      body: FutureBuilder<_SuperAdminData>(
        future: _load(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data =
              snap.data ?? const _SuperAdminData(orgs: []);
          final activeCount =
              data.orgs.where((o) => o.org.isActive).length;
          final disabledCount = data.orgs.length - activeCount;

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                const SizedBox(height: 8),
                Text(
                  'Hi, $firstName',
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  data.orgs.isEmpty
                      ? 'App-level control · no organizations yet'
                      : 'App-level control · ${data.orgs.length} ${data.orgs.length == 1 ? "organization" : "organizations"}',
                  style: TextStyle(
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withOpacity(0.65),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 20),

                // Stat strip — real counts from real data.
                Row(
                  children: [
                    Expanded(
                      child: StatTile(
                        icon: Icons.apartment_outlined,
                        iconBg: AppColors.primaryLight,
                        iconFg: AppColors.primary,
                        value: data.orgs.length.toString(),
                        label: 'Total orgs',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: StatTile(
                        icon: Icons.power_outlined,
                        iconBg: AppColors.successLight,
                        iconFg: AppColors.successDark,
                        value: activeCount.toString(),
                        label: 'Active',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: StatTile(
                        icon: Icons.power_off_outlined,
                        iconBg: AppColors.dangerLight,
                        iconFg: AppColors.dangerDark,
                        value: disabledCount.toString(),
                        label: 'Disabled',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Organizations list + New button.
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SectionLabel('Organizations'),
                    TextButton.icon(
                      onPressed: _openNewOrgSheet,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('New'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (data.orgs.isEmpty)
                  _EmptyOrgsCard(onTap: _openNewOrgSheet)
                else
                  for (final v in data.orgs) ...[
                    _OrgCard(view: v, onTap: () => _openOrgDetail(v)),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SuperAdminData {
  final List<_OrgView> orgs;
  const _SuperAdminData({required this.orgs});
}

class _OrgView {
  final Org org;
  final int userCount;
  final String masterAdminName;

  const _OrgView({
    required this.org,
    required this.userCount,
    required this.masterAdminName,
  });

  String get initials {
    final parts = org.name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1))
        .toUpperCase();
  }
}

class _EmptyOrgsCard extends StatelessWidget {
  final VoidCallback onTap;
  const _EmptyOrgsCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.apartment_outlined,
                  color: AppColors.primary, size: 28),
            ),
            const SizedBox(height: 12),
            const Text(
              'No organizations yet',
              style: TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Text(
              'Create the first organization to get started.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withOpacity(0.65),
                  ),
            ),
            const SizedBox(height: 14),
            ElevatedButton.icon(
              onPressed: onTap,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New organization'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrgCard extends StatelessWidget {
  final _OrgView view;
  final VoidCallback onTap;

  const _OrgCard({required this.view, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final org = view.org;
    final unassigned = view.masterAdminName == 'Unassigned';
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              InitialAvatar(initials: view.initials),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            org.name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (org.isActive)
                          const StatusBadge(
                            label: 'Active',
                            tone: StatusBadgeTone.success,
                          )
                        else
                          const StatusBadge(
                            label: 'Disabled',
                            tone: StatusBadgeTone.danger,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          unassigned
                              ? Icons.person_off_outlined
                              : Icons.person_outline,
                          size: 14,
                          color: unassigned
                              ? AppColors.warningDark
                              : AppColors.textSecondaryLight,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            view.masterAdminName,
                            style: TextStyle(
                              fontSize: 12,
                              color: unassigned
                                  ? AppColors.warningDark
                                  : AppColors.textSecondaryLight,
                              fontWeight: unassigned
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Icon(
                          Icons.people_outline,
                          size: 14,
                          color: AppColors.textSecondaryLight,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${view.userCount} ${view.userCount == 1 ? "user" : "users"}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondaryLight,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: AppColors.textTertiaryLight,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet for creating a new organization + its master admin in
/// one step. Returns `true` when an org was created so the caller
/// knows to refresh.
class _NewOrgSheet extends ConsumerStatefulWidget {
  const _NewOrgSheet();

  @override
  ConsumerState<_NewOrgSheet> createState() => _NewOrgSheetState();
}

class _NewOrgSheetState extends ConsumerState<_NewOrgSheet> {
  final _orgNameCtrl = TextEditingController();
  final _adminNameCtrl = TextEditingController();
  final _adminEmailCtrl = TextEditingController();
  final _adminPhoneCtrl = TextEditingController();
  final _adminPasswordCtrl = TextEditingController();
  bool _saving = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _orgNameCtrl.dispose();
    _adminNameCtrl.dispose();
    _adminEmailCtrl.dispose();
    _adminPhoneCtrl.dispose();
    _adminPasswordCtrl.dispose();
    super.dispose();
  }

  String? _validate() {
    if (_orgNameCtrl.text.trim().isEmpty) return 'Organization name required.';
    if (_adminNameCtrl.text.trim().isEmpty) {
      return 'Master admin name required.';
    }
    final email = _adminEmailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      return 'Valid master admin email required.';
    }
    if (_adminPasswordCtrl.text.length < 6) {
      return 'Password must be at least 6 characters.';
    }
    return null;
  }

  Future<void> _submit() async {
    final err = _validate();
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err)),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(orgRepositoryProvider).create(
            name: _orgNameCtrl.text,
            masterAdminName: _adminNameCtrl.text,
            masterAdminEmail: _adminEmailCtrl.text,
            masterAdminPhone: _adminPhoneCtrl.text,
            masterAdminPassword: _adminPasswordCtrl.text,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(e.toString().replaceFirst('Bad state: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.borderLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'New organization',
                style:
                    TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'Create an org and its master admin together. The master '
                'admin will be able to log in immediately with the '
                'password you set.',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 20),
              const Text('ORGANIZATION',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: AppColors.textSecondaryLight,
                  )),
              const SizedBox(height: 6),
              TextField(
                controller: _orgNameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Ravi Distributors',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('MASTER ADMIN',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: AppColors.textSecondaryLight,
                  )),
              const SizedBox(height: 6),
              TextField(
                controller: _adminNameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _adminEmailCtrl,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _adminPhoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'Phone (optional)',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _adminPasswordCtrl,
                obscureText: !_showPassword,
                decoration: InputDecoration(
                  labelText: 'Password (min 6 chars)',
                  suffixIcon: IconButton(
                    icon: Icon(_showPassword
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 46)),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: _saving ? null : _submit,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.add, size: 18),
                      label: Text(_saving ? 'Creating...' : 'Create'),
                      style: ElevatedButton.styleFrom(
                          minimumSize: const Size(0, 46)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
