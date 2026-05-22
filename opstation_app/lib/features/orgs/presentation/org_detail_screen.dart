import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../team/data/team_repository.dart';
import '../../team/models/team_user.dart';
import '../data/org_repository.dart';
import '../models/org.dart';

/// View + edit a single organization. Super admin can:
///   - Rename the org (inline text field)
///   - Enable / disable (login gate for all org members)
///
/// Delete is intentionally not offered — disable is the non-destructive
/// equivalent and covers the realistic 95% case (org not paying this
/// month, on pause, etc.).
class OrgDetailScreen extends ConsumerStatefulWidget {
  final String orgId;
  const OrgDetailScreen({super.key, required this.orgId});

  @override
  ConsumerState<OrgDetailScreen> createState() => _OrgDetailScreenState();
}

class _OrgDetailScreenState extends ConsumerState<OrgDetailScreen> {
  final _nameCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  Org? _org;
  TeamUser? _masterAdmin;
  int _userCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgRepo = ref.read(orgRepositoryProvider);
    final team = ref.read(teamRepositoryProvider);
    final org = await orgRepo.byId(widget.orgId);
    if (org == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final admin = org.masterAdminId == null
        ? null
        : await team.byId(org.masterAdminId!);
    final count = await orgRepo.userCount(org.id);
    if (!mounted) return;
    setState(() {
      _org = org;
      _masterAdmin = admin;
      _userCount = count;
      _nameCtrl.text = org.name;
      _loading = false;
    });
  }

  Future<void> _saveRename() async {
    final org = _org;
    if (org == null) return;
    final newName = _nameCtrl.text.trim();
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Organization name required.')),
      );
      return;
    }
    if (newName == org.name) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(orgRepositoryProvider)
          .rename(id: org.id, newName: newName);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Organization renamed.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleActive(bool newValue) async {
    final org = _org;
    if (org == null) return;
    // If disabling, force a confirm — the login gate is effectively
    // kicking out every user in the org until someone re-enables it.
    if (!newValue) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Disable organization?'),
          content: Text(
            'All $_userCount ${_userCount == 1 ? "user" : "users"} in '
            '${org.name} will be blocked from logging in until you '
            're-enable the organization. Their data is preserved.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep active'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                  foregroundColor: AppColors.danger),
              child: const Text('Disable'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(orgRepositoryProvider)
          .setActive(id: org.id, active: newValue);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final org = _org!;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => Navigator.of(context).pop(true),
        ),
        title: const Text(
          'Organization',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _headerCard(org),
          const SizedBox(height: 20),
          const _Label('NAME'),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _saving ? null : _saveRename,
                style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 52)),
                child: const Text('Save'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const _Label('MASTER ADMIN'),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Row(
              children: [
                const Icon(Icons.person_outline,
                    size: 18, color: AppColors.textSecondaryLight),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _masterAdmin?.name ?? 'Unassigned',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                      if (_masterAdmin != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          _masterAdmin!.email,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondaryLight,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _Label('STATUS'),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: SwitchListTile(
              value: org.isActive,
              onChanged: _saving ? null : _toggleActive,
              title: Text(org.isActive ? 'Active' : 'Disabled'),
              subtitle: Text(
                org.isActive
                    ? 'All users in this organization can log in.'
                    : 'Login blocked for all users. Data preserved.',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerCard(Org org) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: org.isActive
            ? AppColors.primaryLight.withOpacity(0.5)
            : AppColors.dangerLight.withOpacity(0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            org.isActive ? Icons.apartment : Icons.power_off_outlined,
            color: org.isActive ? AppColors.primary : AppColors.dangerDark,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  org.name,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  '$_userCount ${_userCount == 1 ? "user" : "users"} · created ${DateFormat('d MMM y').format(org.createdAt)}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
        color: AppColors.textSecondaryLight,
      ),
    );
  }
}
