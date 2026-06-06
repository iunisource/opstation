import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/permissions/permission_registry.dart';
import '../../auth/auth_controller.dart';

class ErpUsersScreen extends ConsumerStatefulWidget {
  const ErpUsersScreen({super.key});
  @override
  ConsumerState<ErpUsersScreen> createState() => _ErpUsersScreenState();
}

class _ErpUsersScreenState extends ConsumerState<ErpUsersScreen> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final users = await client
          .from('users')
          .select()
          .eq('org_id', orgId)
          .eq('role', 'erpUser')
          .order('name');
      final userIds = (users as List).map((u) => u['id'] as String).toList();
      Map<String, List<String>> branchMap = {};
      if (userIds.isNotEmpty) {
        final branches = await client
            .from('erp_user_branches')
            .select('user_id, branches(name)')
            .inFilter('user_id', userIds);
        for (final b in branches as List) {
          final uid = b['user_id'] as String;
          branchMap.putIfAbsent(uid, () => []);
          if (b['branches'] != null) {
            branchMap[uid]!.add(b['branches']['name'] as String);
          }
        }
      }
      setState(() {
        _users = users.map((u) {
          final m = Map<String, dynamic>.from(u);
          m['_branches'] = branchMap[u['id']] ?? [];
          return m;
        }).toList();
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _toggleActive(Map<String, dynamic> user) async {
    final newVal = !(user['is_active'] as bool? ?? true);
    try {
      await Supabase.instance.client
          .from('users')
          .update({'is_active': newVal})
          .eq('id', user['id']);
      _showSnack(newVal ? 'User activated' : 'User deactivated');
      _load();
    } catch (e) {
      _showSnack('Failed: $e');
    }
  }

  // ── Permission editor widgets ───────────────────────────────────────────

  Widget _miniCheck(String label, bool value, void Function(bool) onChanged) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 2),
          Text(label, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _permModuleTile(
    PermModule mod,
    Set<String> sel,
    Set<String> expanded,
    void Function(void Function()) setS,
  ) {
    final keys = mod.allKeys;
    final grantedCount = keys.where(sel.contains).length;
    final allOn = keys.isNotEmpty && keys.every(sel.contains);
    final isExp = expanded.contains(mod.key);

    return Column(children: [
      InkWell(
        onTap: () => setS(() {
          if (isExp) {
            expanded.remove(mod.key);
          } else {
            expanded.add(mod.key);
          }
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Icon(mod.icon,
                size: 18,
                color: grantedCount > 0 ? AppTheme.primary : AppTheme.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(mod.label,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: grantedCount > 0 ? AppTheme.primary : Colors.black87)),
            ),
            if (grantedCount > 0)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text('$grantedCount',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ),
            Tooltip(
              message: allOn ? 'Clear all in module' : 'Grant all in module',
              child: Switch(
                value: allOn,
                onChanged: (v) => setS(() {
                  if (v) {
                    sel.addAll(keys);
                    expanded.add(mod.key);
                  } else {
                    sel.removeAll(keys);
                  }
                }),
              ),
            ),
            Icon(isExp ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 18, color: AppTheme.textSecondary),
          ]),
        ),
      ),
      if (isExp) ...[
        const Divider(height: 1),
        // Column headers
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 4, 12, 2),
          child: Row(children: const [
            Expanded(child: SizedBox()),
            SizedBox(width: 64, child: Text('Add', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 64, child: Text('Edit', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
          ]),
        ),
        ...mod.items.map((it) => Padding(
              padding: const EdgeInsets.fromLTRB(40, 0, 12, 0),
              child: Row(children: [
                Expanded(
                  child: Text(it.label,
                      style: const TextStyle(fontSize: 12.5)),
                ),
                if (it.kind == PermKind.doc) ...[
                  SizedBox(
                    width: 64,
                    child: Center(
                      child: _miniCheck('', sel.contains(it.addKey), (v) => setS(() {
                        if (v) {
                          sel.add(it.addKey);
                        } else {
                          sel.remove(it.addKey);
                        }
                      })),
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    child: Center(
                      child: _miniCheck('', sel.contains(it.editKey), (v) => setS(() {
                        if (v) {
                          sel.add(it.editKey);
                        } else {
                          sel.remove(it.editKey);
                        }
                      })),
                    ),
                  ),
                ] else
                  SizedBox(
                    width: 128,
                    child: Center(
                      child: _miniCheck('Show', sel.contains(it.viewKey), (v) => setS(() {
                        if (v) {
                          sel.add(it.viewKey);
                        } else {
                          sel.remove(it.viewKey);
                        }
                      })),
                    ),
                  ),
              ]),
            )),
        const SizedBox(height: 6),
        const Divider(height: 1),
      ],
      if (mod.key != kPermissionRegistry.last.key) const Divider(height: 1),
    ]);
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? user) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final client = Supabase.instance.client;

    final branches = await client
        .from('branches')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('name');

    List<String> currentBranches = [];
    // scope key '*' == all branches (branch_id NULL / global grant); else a branch_id.
    final Map<String, Set<String>> permsByScope = {};

    if (user != null) {
      final existingBranches = await client
          .from('erp_user_branches')
          .select('branch_id')
          .eq('user_id', user['id']);
      currentBranches =
          (existingBranches as List).map((b) => b['branch_id'] as String).toList();

      final existingPerms = await client
          .from('user_permissions')
          .select('permission, branch_id')
          .eq('user_id', user['id']);
      for (final p in existingPerms as List) {
        final key = p['permission'] as String;
        if (!kAllPermKeys.contains(key)) continue; // drop legacy keys
        final bid = p['branch_id'] as String?;
        (permsByScope[bid ?? '*'] ??= <String>{}).add(key);
      }
    }

    if (!mounted) return;

    final nameCtrl = TextEditingController(text: user?['name'] ?? '');
    final emailCtrl = TextEditingController(text: user?['email'] ?? '');
    final passCtrl = TextEditingController();
    final selectedBranches = Set<String>.from(currentBranches);
    String currentScope = '*';
    final expandedModules = <String>{};

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(user == null ? 'Add ERP User' : 'Edit ERP User'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Basic Info',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
                const SizedBox(height: 8),
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full Name *')),
                const SizedBox(height: 12),
                TextField(controller: emailCtrl,
                    decoration: const InputDecoration(labelText: 'Email *'),
                    keyboardType: TextInputType.emailAddress,
                    enabled: user == null),
                const SizedBox(height: 12),
                TextField(controller: passCtrl, obscureText: true,
                    decoration: InputDecoration(
                        labelText: user == null ? 'Password *' : 'New Password (leave blank to keep)',
                        hintText: 'Min 6 characters')),
                const SizedBox(height: 20),

                // Branch assignment
                const Align(alignment: Alignment.centerLeft,
                    child: Text('Branch Access',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
                const SizedBox(height: 4),
                const Align(alignment: Alignment.centerLeft,
                    child: Text('Branches this user can operate in',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                      border: Border.all(color: AppTheme.border),
                      borderRadius: BorderRadius.circular(8)),
                  child: Column(
                    children: (branches as List).map((b) {
                      final bid = b['id'] as String;
                      return CheckboxListTile(
                        dense: true,
                        title: Text(b['name'] as String, style: const TextStyle(fontSize: 13)),
                        value: selectedBranches.contains(bid),
                        onChanged: (v) => setS(() {
                          if (v == true) {
                            selectedBranches.add(bid);
                          } else {
                            selectedBranches.remove(bid);
                            if (currentScope == bid) currentScope = '*';
                          }
                        }),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 20),

                // Permissions
                const Align(alignment: Alignment.centerLeft,
                    child: Text('Permissions',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
                const SizedBox(height: 4),
                const Align(alignment: Alignment.centerLeft,
                    child: Text('Add / Edit per voucher · Show per report. Delete is restricted to admins.',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                const SizedBox(height: 10),
                // Branch scope switcher (Option A): 'All branches' edits global
                // grants (branch_id NULL); a branch edits grants only for it.
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(spacing: 8, runSpacing: 6, children: [
                    ChoiceChip(
                      label: const Text('All branches'),
                      selected: currentScope == '*',
                      onSelected: (_) => setS(() => currentScope = '*'),
                    ),
                    for (final b in (branches as List).where((b) => selectedBranches.contains(b['id'] as String)))
                      ChoiceChip(
                        label: Text(b['name'] as String),
                        selected: currentScope == b['id'],
                        onSelected: (_) => setS(() => currentScope = b['id'] as String),
                      ),
                  ]),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    currentScope == '*'
                        ? 'Editing grants that apply at every branch.'
                        : 'Editing grants that apply only at the selected branch.',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontStyle: FontStyle.italic),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                      border: Border.all(color: AppTheme.border),
                      borderRadius: BorderRadius.circular(8)),
                  child: Column(
                    children: [
                      for (final mod in kPermissionRegistry)
                        _permModuleTile(mod, permsByScope.putIfAbsent(currentScope, () => <String>{}), expandedModules, setS),
                    ],
                  ),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty || (user == null && emailCtrl.text.trim().isEmpty)) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Name and email are required')));
                  return;
                }
                if (user == null && passCtrl.text.length < 6) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Password must be at least 6 characters')));
                  return;
                }
                if (selectedBranches.isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Assign at least one branch')));
                  return;
                }

                try {
                  String userId;
                  if (user == null) {
                    final res = await client.functions.invoke('create-team-user', body: {
                      'name': nameCtrl.text.trim(),
                      'email': emailCtrl.text.trim().toLowerCase(),
                      'password': passCtrl.text,
                      'role': 'erpUser',
                      'orgId': orgId,
                    });
                    final data = res.data as Map<String, dynamic>?;
                    if (data == null || data['userId'] == null) {
                      throw Exception(data?['error'] ?? 'Failed to create user');
                    }
                    userId = data['userId'] as String;
                  } else {
                    userId = user['id'] as String;
                    await client.from('users').update({'name': nameCtrl.text.trim()}).eq('id', userId);
                  }

                  // Branch assignments — diff against existing (avoids the
                  // unique-constraint collision when a delete is RLS-blocked,
                  // and only touches rows that actually changed).
                  final existBr = await client
                      .from('erp_user_branches')
                      .select('branch_id')
                      .eq('user_id', userId);
                  final existingBranchIds = {
                    for (final r in existBr as List) r['branch_id'] as String
                  };
                  final toAddBr = selectedBranches.difference(existingBranchIds);
                  final toRemoveBr = existingBranchIds.difference(selectedBranches);
                  int bseq = 0;
                  for (final bid in toAddBr) {
                    await client.from('erp_user_branches').insert({
                      'id': 'eub_${DateTime.now().microsecondsSinceEpoch}_${bseq++}',
                      'org_id': orgId,
                      'user_id': userId,
                      'branch_id': bid,
                    });
                  }
                  for (final bid in toRemoveBr) {
                    await client
                        .from('erp_user_branches')
                        .delete()
                        .eq('user_id', userId)
                        .eq('branch_id', bid);
                  }

                  // Permissions — branch-scoped diff (Option A). A pair is
                  // "<scope>|<permission>"; scope '*' maps to branch_id NULL
                  // (global), otherwise to that branch_id. Grants for branches no
                  // longer assigned are pruned.
                  final existPm = await client
                      .from('user_permissions')
                      .select('permission, branch_id')
                      .eq('user_id', userId);
                  final existingPairs = <String>{
                    for (final r in existPm as List)
                      '${(r['branch_id'] as String?) ?? '*'}|${r['permission'] as String}'
                  };
                  final desiredPairs = <String>{};
                  permsByScope.forEach((scope, keys) {
                    if (scope != '*' && !selectedBranches.contains(scope)) return;
                    for (final k in keys) desiredPairs.add('$scope|$k');
                  });
                  final grantedBy = ref.read(currentUserProvider)?.id;
                  int pseq = 0;
                  for (final pair in desiredPairs.difference(existingPairs)) {
                    final i = pair.indexOf('|');
                    final scope = pair.substring(0, i);
                    final perm = pair.substring(i + 1);
                    await client.from('user_permissions').insert({
                      'id': 'up_${DateTime.now().microsecondsSinceEpoch}_${pseq++}',
                      'org_id': orgId,
                      'user_id': userId,
                      'permission': perm,
                      'branch_id': scope == '*' ? null : scope,
                      'granted_by': grantedBy,
                    });
                  }
                  for (final pair in existingPairs.difference(desiredPairs)) {
                    final i = pair.indexOf('|');
                    final scope = pair.substring(0, i);
                    final perm = pair.substring(i + 1);
                    final del = client
                        .from('user_permissions')
                        .delete()
                        .eq('user_id', userId)
                        .eq('permission', perm);
                    if (scope == '*') {
                      await del.isFilter('branch_id', null);
                    } else {
                      await del.eq('branch_id', scope);
                    }
                  }

                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack(user == null ? 'ERP user created' : 'ERP user updated');
                  _load();
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: $e')));
                  }
                }
              },
              child: Text(user == null ? 'Create' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('ERP Users', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: () => _showDialog(context, null),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add ERP User'),
          ),
        ]),
        const SizedBox(height: 8),
        Text('${_users.length} ERP users', style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 24),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: const BoxDecoration(
                    color: AppTheme.background,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  child: const Row(children: [
                    Expanded(flex: 3, child: Text('Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 3, child: Text('Email', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 3, child: Text('Branches', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 1, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    SizedBox(width: 80),
                  ]),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _users.isEmpty
                      ? const Center(child: Text('No ERP users yet.', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: _users.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final u = _users[i];
                            final isActive = u['is_active'] as bool? ?? true;
                            final branches = (u['_branches'] as List<String>).join(', ');
                            return Opacity(
                              opacity: isActive ? 1.0 : 0.5,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                child: Row(children: [
                                  Expanded(flex: 3, child: Text(u['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600))),
                                  Expanded(flex: 3, child: Text(u['email'] as String? ?? '', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                                  Expanded(flex: 3, child: Text(branches.isEmpty ? 'No branches' : branches,
                                      style: TextStyle(fontSize: 13, color: branches.isEmpty ? AppTheme.danger : AppTheme.textSecondary))),
                                  Expanded(flex: 1, child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: isActive ? AppTheme.success.withOpacity(0.1) : AppTheme.danger.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(isActive ? 'Active' : 'Inactive',
                                        style: TextStyle(color: isActive ? AppTheme.success : AppTheme.danger, fontSize: 12, fontWeight: FontWeight.w600)),
                                  )),
                                  SizedBox(width: 80, child: Row(children: [
                                    IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _showDialog(context, u)),
                                    IconButton(
                                      icon: Icon(isActive ? Icons.block : Icons.check_circle_outline, size: 18,
                                          color: isActive ? AppTheme.danger : AppTheme.success),
                                      onPressed: () => _toggleActive(u),
                                    ),
                                  ])),
                                ]),
                              ),
                            );
                          }),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}
