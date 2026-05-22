import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

const _modulePermissions = {
  'inventory': {
    'label': 'Inventory',
    'icon': Icons.inventory_2_outlined,
    'permissions': {
      'inventory.view': 'View products & stock',
      'inventory.manage_products': 'Add / edit products',
      'inventory.adjust_stock': 'Adjust stock levels',
      'inventory.opening_stock': 'Set opening stock',
      'inventory.stock_transfer': 'Create stock transfers',
    },
  },
  'purchase': {
    'label': 'Purchase',
    'icon': Icons.shopping_cart_outlined,
    'permissions': {
      'purchase.view': 'View purchase orders',
      'purchase.create': 'Create purchase orders',
      'purchase.receive': 'Receive goods',
      'purchase.manage_suppliers': 'Manage suppliers',
      'purchase.payment': 'Create payment vouchers',
    },
  },
  'sales': {
    'label': 'Sales',
    'icon': Icons.receipt_long_outlined,
    'permissions': {
      'sales.view': 'View sales orders',
      'sales.create': 'Create sales orders',
      'sales.confirm': 'Confirm orders',
      'sales.deliver': 'Mark as delivered',
      'sales.receipt': 'Create receipt vouchers',
    },
  },
  'pos': {
    'label': 'POS',
    'icon': Icons.storefront_outlined,
    'permissions': {
      'pos.open_session': 'Open / close sessions',
      'pos.transact': 'Process transactions',
      'pos.view_reports': 'View session reports',
    },
  },
  'reports': {
    'label': 'Reports & Ledgers',
    'icon': Icons.analytics_outlined,
    'permissions': {
      'reports.inventory': 'Inventory ledger',
      'reports.supplier': 'Supplier ledger',
      'reports.customer': 'Customer ledger',
    },
  },
};

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
      // Load branch assignments for each user
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
    } catch (e) { _showSnack('Failed: $e'); }
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? user) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final client = Supabase.instance.client;

    // Load branches and current assignments
    final branches = await client
        .from('branches')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('name');

    List<String> currentBranches = [];
    Set<String> currentPermissions = {};

    if (user != null) {
      final existingBranches = await client
          .from('erp_user_branches')
          .select('branch_id')
          .eq('user_id', user['id']);
      currentBranches = (existingBranches as List).map((b) => b['branch_id'] as String).toList();

      final existingPerms = await client
          .from('user_permissions')
          .select('permission')
          .eq('user_id', user['id']);
      currentPermissions = (existingPerms as List).map((p) => p['permission'] as String).toSet();
    }

    if (!mounted) return;

    final nameCtrl = TextEditingController(text: user?['name'] ?? '');
    final emailCtrl = TextEditingController(text: user?['email'] ?? '');
    final passCtrl = TextEditingController();
    final selectedBranches = Set<String>.from(currentBranches);
    final selectedPerms = Set<String>.from(currentPermissions);
    final expandedModules = <String>{};

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(user == null ? 'Add ERP User' : 'Edit ERP User'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Basic info
                const Align(alignment: Alignment.centerLeft,
                    child: Text('Basic Info', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
                const SizedBox(height: 8),
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full Name *')),
                const SizedBox(height: 12),
                TextField(controller: emailCtrl, decoration: const InputDecoration(labelText: 'Email *'),
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
                    child: Text('Branch Access', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
                const SizedBox(height: 4),
                const Align(alignment: Alignment.centerLeft,
                    child: Text('Select branches this user can access', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: (branches as List).map((b) {
                      final bid = b['id'] as String;
                      return CheckboxListTile(
                        dense: true,
                        title: Text(b['name'] as String, style: const TextStyle(fontSize: 13)),
                        value: selectedBranches.contains(bid),
                        onChanged: (v) => setS(() {
                          if (v == true) selectedBranches.add(bid);
                          else selectedBranches.remove(bid);
                        }),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 20),

                // Module permissions
                const Align(alignment: Alignment.centerLeft,
                    child: Text('Permissions', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
                const SizedBox(height: 4),
                const Align(alignment: Alignment.centerLeft,
                    child: Text('Enable modules and set granular access', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: _modulePermissions.entries.map((module) {
                      final moduleKey = module.key;
                      final moduleData = module.value;
                      final moduleLabel = moduleData['label'] as String;
                      final moduleIcon = moduleData['icon'] as IconData;
                      final permissions = moduleData['permissions'] as Map<String, String>;
                      final moduleEnabled = permissions.keys.any((p) => selectedPerms.contains(p));
                      final isExpanded = expandedModules.contains(moduleKey);

                      return Column(children: [
                        InkWell(
                          onTap: () => setS(() {
                            if (isExpanded) expandedModules.remove(moduleKey);
                            else expandedModules.add(moduleKey);
                          }),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            child: Row(children: [
                              Icon(moduleIcon, size: 18, color: moduleEnabled ? AppTheme.primary : AppTheme.textSecondary),
                              const SizedBox(width: 10),
                              Expanded(child: Text(moduleLabel,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: moduleEnabled ? AppTheme.primary : Colors.black87))),
                              Switch(
                                value: moduleEnabled,
                                onChanged: (v) => setS(() {
                                  if (v) {
                                    selectedPerms.addAll(permissions.keys);
                                    expandedModules.add(moduleKey);
                                  } else {
                                    selectedPerms.removeAll(permissions.keys);
                                    expandedModules.remove(moduleKey);
                                  }
                                }),
                              ),
                              Icon(isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                  size: 18, color: AppTheme.textSecondary),
                            ]),
                          ),
                        ),
                        if (isExpanded) ...[
                          const Divider(height: 1),
                          ...permissions.entries.map((perm) => Padding(
                            padding: const EdgeInsets.only(left: 40),
                            child: CheckboxListTile(
                              dense: true,
                              title: Text(perm.value, style: const TextStyle(fontSize: 12)),
                              value: selectedPerms.contains(perm.key),
                              onChanged: (v) => setS(() {
                                if (v == true) selectedPerms.add(perm.key);
                                else selectedPerms.remove(perm.key);
                              }),
                            ),
                          )),
                          const Divider(height: 1),
                        ],
                        if (module.key != _modulePermissions.keys.last)
                          const Divider(height: 1),
                      ]);
                    }).toList(),
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
                    // Create via Edge Function
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
                    final updates = <String, dynamic>{'name': nameCtrl.text.trim()};
                    await client.from('users').update(updates).eq('id', userId);
                    if (passCtrl.text.length >= 6) {
                      // TODO: update password via Edge Function in v1.1
                    }
                  }

                  // Save branch assignments
                  await client.from('erp_user_branches').delete().eq('user_id', userId);
                  for (final bid in selectedBranches) {
                    await client.from('erp_user_branches').insert({
                      'id': 'eub_${DateTime.now().millisecondsSinceEpoch}_${bid.substring(0, 4)}',
                      'org_id': orgId,
                      'user_id': userId,
                      'branch_id': bid,
                    });
                  }

                  // Save permissions
                  await client.from('user_permissions').delete().eq('user_id', userId);
                  final grantedBy = ref.read(currentUserProvider)?.id;
                  for (final perm in selectedPerms) {
                    await client.from('user_permissions').insert({
                      'id': 'up_${DateTime.now().millisecondsSinceEpoch}_${perm.replaceAll('.', '_')}',
                      'org_id': orgId,
                      'user_id': userId,
                      'permission': perm,
                      'granted_by': grantedBy,
                    });
                  }

                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack(user == null ? 'ERP user created' : 'ERP user updated');
                  _load();
                } catch (e) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Failed: $e')));
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
                                  Expanded(flex: 3, child: Text(u['name'] as String? ?? '',
                                      style: const TextStyle(fontWeight: FontWeight.w600))),
                                  Expanded(flex: 3, child: Text(u['email'] as String? ?? '',
                                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                                  Expanded(flex: 3, child: Text(branches.isEmpty ? 'No branches' : branches,
                                      style: TextStyle(fontSize: 13,
                                          color: branches.isEmpty ? AppTheme.danger : AppTheme.textSecondary))),
                                  Expanded(flex: 1, child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: isActive ? AppTheme.success.withOpacity(0.1) : AppTheme.danger.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(isActive ? 'Active' : 'Inactive',
                                        style: TextStyle(
                                            color: isActive ? AppTheme.success : AppTheme.danger,
                                            fontSize: 12, fontWeight: FontWeight.w600)),
                                  )),
                                  SizedBox(width: 80, child: Row(children: [
                                    IconButton(
                                        icon: const Icon(Icons.edit_outlined, size: 18),
                                        onPressed: () => _showDialog(context, u)),
                                    IconButton(
                                      icon: Icon(
                                          isActive ? Icons.block : Icons.check_circle_outline,
                                          size: 18,
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
