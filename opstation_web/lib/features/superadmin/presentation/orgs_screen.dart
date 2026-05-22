import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/password_hasher.dart';
import '../../../core/theme/app_theme.dart';

class OrgsScreen extends ConsumerStatefulWidget {
  const OrgsScreen({super.key});
  @override
  ConsumerState<OrgsScreen> createState() => _OrgsScreenState();
}

class _OrgsScreenState extends ConsumerState<OrgsScreen> {
  List<Map<String, dynamic>> _orgs = [];
  Map<String, Map<String, dynamic>> _mastersByOrgId = {};
  Map<String, int> _userCountsByOrgId = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final orgs = await client.from('orgs').select().order('name');
      final users = await client.from('users').select('id, name, email, role, org_id');

      final usersList = users as List;
      final mastersByOrgId = <String, Map<String, dynamic>>{};
      final userCountsByOrgId = <String, int>{};
      for (final u in usersList) {
        final m = Map<String, dynamic>.from(u as Map);
        final orgId = m['org_id'] as String?;
        if (orgId == null) continue;
        userCountsByOrgId[orgId] = (userCountsByOrgId[orgId] ?? 0) + 1;
      }
      for (final o in orgs as List) {
        final orgM = Map<String, dynamic>.from(o as Map);
        final mId = orgM['master_admin_id'] as String?;
        if (mId != null) {
          for (final u in usersList) {
            if (u['id'] == mId) {
              mastersByOrgId[orgM['id'] as String] =
                  Map<String, dynamic>.from(u as Map);
              break;
            }
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _orgs = List<Map<String, dynamic>>.from(orgs);
        _mastersByOrgId = mastersByOrgId;
        _userCountsByOrgId = userCountsByOrgId;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load: ${e.toString().split("\n").first}')),
      );
    }
  }

  Future<void> _toggleActive(Map<String, dynamic> o) async {
    final newVal = !(o['is_active'] as bool? ?? true);
    try {
      await Supabase.instance.client
          .from('orgs')
          .update({'is_active': newVal}).eq('id', o['id']);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
  }

  Future<void> _enforceMaxUsers(SupabaseClient client, String orgId) async {
    final orgRow = await client
        .from('orgs')
        .select('max_users')
        .eq('id', orgId)
        .maybeSingle();
    final maxUsers = orgRow?['max_users'] as int?;
    if (maxUsers == null) return;
    final users = await client
        .from('users')
        .select('id')
        .eq('org_id', orgId);
    if ((users as List).length >= maxUsers) {
      throw Exception('User limit reached for this organization. Increase Max Users first.');
    }
  }

  Future<void> _saveOrg({
    required bool isEdit,
    required Map<String, dynamic>? existingOrg,
    required Map<String, dynamic>? existingMaster,
    required String orgName,
    required int? maxUsers,
    required DateTime? expiresAt,
    required String maName,
    required String maEmail,
    required String maPassword,
  }) async {
    final client = Supabase.instance.client;
    final now = DateTime.now();

    if (!isEdit) {
      if (maPassword.length < 6) {
        throw Exception('Password must be at least 6 characters.');
      }
      final salt = PasswordHasher.newSalt();
      final hash = PasswordHasher.hash(maPassword, salt);

      try {
        await client.functions.invoke('create-org-admin', body: {
          'orgName': orgName,
          'maxUsers': maxUsers,
          'expiresAt': expiresAt?.toUtc().toIso8601String(),
          'maName': maName,
          'maEmail': maEmail,
          'maPassword': maPassword,
          'maPasswordHash': hash,
          'maPasswordSalt': salt,
        });
      } on FunctionException catch (e) {
        String code = '';
        String detail = '';
        final body = e.details;
        if (body is Map) {
          if (body['error'] is String) code = body['error'] as String;
          if (body['detail'] is String) detail = body['detail'] as String;
        }
        String message;
        switch (code) {
          case 'email_exists_public':
            message = 'A user with this email already exists.';
            break;
          case 'forbidden':
            message = 'You do not have permission to create organizations.';
            break;
          case 'weak_password':
            message = 'Password must be at least 6 characters.';
            break;
          case 'auth_create_failed':
            message = 'Could not create auth user: $detail';
            break;
          case 'insert_failed_rolled_back':
            message = 'Database error, rolled back: $detail';
            break;
          default:
            message = code.isEmpty
                ? 'Failed to create organization (status ${e.status}).'
                : '$code: $detail';
        }
        throw Exception(message);
      }
    } else {
      final orgId = existingOrg!['id'] as String;
      await client.from('orgs').update({
        'name': orgName,
        'max_users': maxUsers,
        'expires_at': expiresAt?.toUtc().toIso8601String(),
        'updated_at': now.toIso8601String(),
      }).eq('id', orgId);

      if (existingMaster != null) {
        final updates = <String, dynamic>{
          'name': maName,
          'email': maEmail,
          'updated_at': now.toIso8601String(),
        };
        if (maPassword.isNotEmpty) {
          if (maPassword.length < 6) {
            throw Exception('Password must be at least 6 characters.');
          }
          final salt = PasswordHasher.newSalt();
          final hash = PasswordHasher.hash(maPassword, salt);
          updates['password_hash'] = hash;
          updates['password_salt'] = salt;
          updates['password_temporary'] = false;
        }
        await client.from('users').update(updates).eq('id', existingMaster['id']);
      } else {
        await _enforceMaxUsers(client, orgId);
        final existing = await client
            .from('users')
            .select('id')
            .eq('email', maEmail)
            .limit(1);
        if ((existing as List).isNotEmpty) {
          throw Exception('A user with this email already exists.');
        }
        if (maPassword.length < 6) {
          throw Exception('Password must be at least 6 characters.');
        }
        final maId = 'user_${now.millisecondsSinceEpoch}';
        final salt = PasswordHasher.newSalt();
        final hash = PasswordHasher.hash(maPassword, salt);
        await client.from('users').insert({
          'id': maId,
          'name': maName,
          'email': maEmail,
          'phone': '',
          'role': 'masterAdmin',
          'is_active': true,
          'password_hash': hash,
          'password_salt': salt,
          'password_temporary': false,
          'org_id': orgId,
          'created_at': now.toIso8601String(),
        });
        await client.from('orgs').update({'master_admin_id': maId}).eq('id', orgId);
      }
    }
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? org) {
    final isEdit = org != null;
    final master = isEdit ? _mastersByOrgId[org['id']] : null;

    final orgNameCtrl = TextEditingController(text: org?['name'] ?? '');
    final maxUsersCtrl = TextEditingController(
      text: (org?['max_users'] as int?)?.toString() ?? '',
    );
    DateTime? expiresAt = org?['expires_at'] != null
        ? DateTime.parse(org!['expires_at'] as String).toLocal()
        : null;
    final maNameCtrl = TextEditingController(text: master?['name'] ?? '');
    final maEmailCtrl = TextEditingController(text: master?['email'] ?? '');
    final maPasswordCtrl = TextEditingController();
    bool obscure = true;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (dCtx, setS) => AlertDialog(
          title: Text(isEdit ? 'Edit Organization' : 'Add Organization'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ORGANIZATION',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textSecondary,
                          letterSpacing: 0.6)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: orgNameCtrl,
                    decoration: const InputDecoration(labelText: 'Organization Name *'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: maxUsersCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Max Users',
                      hintText: 'Leave blank for unlimited',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: dCtx,
                            initialDate: expiresAt ??
                                DateTime.now().add(const Duration(days: 365)),
                            firstDate: DateTime.now(),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) setS(() => expiresAt = picked);
                        },
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Expires On',
                            hintText: 'Never',
                            prefixIcon: Icon(Icons.event, size: 18),
                          ),
                          child: Text(
                            expiresAt == null
                                ? 'Never'
                                : DateFormat('d MMM yyyy').format(expiresAt!),
                          ),
                        ),
                      ),
                    ),
                    if (expiresAt != null) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => setS(() => expiresAt = null),
                        child: const Text('Clear'),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 24),
                  Text(isEdit ? 'MASTER ADMIN' : 'MASTER ADMIN (created with org)',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textSecondary,
                          letterSpacing: 0.6)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: maNameCtrl,
                    decoration: const InputDecoration(labelText: 'Name *'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: maEmailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email *'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: maPasswordCtrl,
                    obscureText: obscure,
                    decoration: InputDecoration(
                      labelText: isEdit ? 'New Password' : 'Password *',
                      hintText:
                          isEdit ? 'Leave blank to keep current' : 'Min 6 chars',
                      suffixIcon: IconButton(
                        icon: Icon(obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                        onPressed: () => setS(() => obscure = !obscure),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx, rootNavigator: true).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (orgNameCtrl.text.trim().isEmpty ||
                    maNameCtrl.text.trim().isEmpty ||
                    maEmailCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(dCtx).showSnackBar(
                    const SnackBar(content: Text('Please fill all required fields.')),
                  );
                  return;
                }
                if (!isEdit && maPasswordCtrl.text.length < 6) {
                  ScaffoldMessenger.of(dCtx).showSnackBar(
                    const SnackBar(content: Text('Password must be at least 6 characters.')),
                  );
                  return;
                }
                int? maxUsers;
                if (maxUsersCtrl.text.trim().isNotEmpty) {
                  final parsed = int.tryParse(maxUsersCtrl.text.trim());
                  if (parsed == null || parsed <= 0) {
                    ScaffoldMessenger.of(dCtx).showSnackBar(
                      const SnackBar(content: Text('Max users must be a positive integer.')),
                    );
                    return;
                  }
                  maxUsers = parsed;
                }
                try {
                  await _saveOrg(
                    isEdit: isEdit,
                    existingOrg: org,
                    existingMaster: master,
                    orgName: orgNameCtrl.text.trim(),
                    maxUsers: maxUsers,
                    expiresAt: expiresAt,
                    maName: maNameCtrl.text.trim(),
                    maEmail: maEmailCtrl.text.trim().toLowerCase(),
                    maPassword: maPasswordCtrl.text,
                  );
                  if (dCtx.mounted) {
                    Navigator.of(dCtx, rootNavigator: true).pop();
                  }
                  _load();
                } catch (e) {
                  if (dCtx.mounted) {
                    ScaffoldMessenger.of(dCtx).showSnackBar(
                      SnackBar(content: Text('Save failed: $e')),
                    );
                  }
                }
              },
              child: Text(isEdit ? 'Save' : 'Create'),
            ),
          ],
        ),
      ),
    );
  }

  static const _moduleLabels = {
    'inventory': 'Inventory',
    'purchase': 'Purchase',
    'sales': 'Sales',
    'pos': 'POS',
    'hr': 'HR',
    'assets': 'Asset Management',
    'production': 'Production',
    'financial_reporting': 'Financial Reporting',
  };

  Future<void> _showModulesDialog(BuildContext ctx, String orgId, String orgName) async {
    final client = Supabase.instance.client;
    final res = await client
        .from('org_modules')
        .select('module, is_enabled')
        .eq('org_id', orgId);
    final Map<String, bool> states = {
      for (final row in res as List)
        row['module'] as String: row['is_enabled'] as bool,
    };
    if (!ctx.mounted) return;
    await showDialog(
      context: ctx,
      builder: (dCtx) => StatefulBuilder(
        builder: (dCtx, setS) => AlertDialog(
          title: Text('Modules — $orgName'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _moduleLabels.entries.map((e) => SwitchListTile(
                title: Text(e.value),
                value: states[e.key] ?? false,
                onChanged: (val) async {
                  setS(() => states[e.key] = val);
                  await client.from('org_modules').upsert({
                    'org_id': orgId,
                    'module': e.key,
                    'is_enabled': val,
                    'updated_at': DateTime.now().toUtc().toIso8601String(),
                  });
                },
              )).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(),
              child: const Text('Done'),
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
          const Text('Organizations',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: () => _showDialog(context, null),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Organization'),
          ),
        ]),
        const SizedBox(height: 8),
        Text('${_orgs.length} organizations',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 24),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else
          Expanded(
            child: ListView.separated(
              itemCount: _orgs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                final o = _orgs[i];
                final isActive = o['is_active'] as bool? ?? true;
                final maxUsers = o['max_users'] as int?;
                final userCount = _userCountsByOrgId[o['id']] ?? 0;
                final master = _mastersByOrgId[o['id']];
                final expiresAt = o['expires_at'] != null
                    ? DateTime.parse(o['expires_at'] as String).toLocal()
                    : null;
                final isExpired = expiresAt != null && expiresAt.isBefore(DateTime.now());
                return Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Row(children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        (o['name'] as String? ?? 'O').substring(0, 1).toUpperCase(),
                        style: const TextStyle(
                            color: AppTheme.primary,
                            fontWeight: FontWeight.w800,
                            fontSize: 20),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(o['name'] as String? ?? '',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 16)),
                            const SizedBox(height: 2),
                            Text(
                              master != null
                                  ? 'Admin: ${master['name']} · ${master['email']}'
                                  : 'No master admin assigned',
                              style: const TextStyle(
                                  color: AppTheme.textSecondary, fontSize: 12),
                            ),
                            const SizedBox(height: 6),
                            Row(children: [
                              _Chip(
                                icon: Icons.people_outline,
                                label:
                                    '$userCount${maxUsers != null ? '/$maxUsers' : ''} users',
                                color: maxUsers != null && userCount >= maxUsers
                                    ? AppTheme.danger
                                    : AppTheme.textSecondary,
                              ),
                              const SizedBox(width: 8),
                              _Chip(
                                icon: Icons.event_outlined,
                                label: expiresAt == null
                                    ? 'No expiry'
                                    : (isExpired
                                        ? 'Expired'
                                        : 'Until ${DateFormat('d MMM yyyy').format(expiresAt)}'),
                                color: isExpired
                                    ? AppTheme.danger
                                    : AppTheme.textSecondary,
                              ),
                            ]),
                          ]),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: isActive
                            ? AppTheme.success.withOpacity(0.1)
                            : AppTheme.danger.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        isActive ? 'Active' : 'Inactive',
                        style: TextStyle(
                          color: isActive ? AppTheme.success : AppTheme.danger,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Manage Modules',
                      icon: const Icon(Icons.extension_outlined, size: 18),
                      onPressed: () => _showModulesDialog(context, o['id'] as String, o['name'] as String),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () => _showDialog(context, o),
                    ),
                    IconButton(
                      icon: Icon(
                        isActive ? Icons.block : Icons.check_circle_outline,
                        size: 18,
                        color: isActive ? AppTheme.danger : AppTheme.success,
                      ),
                      onPressed: () => _toggleActive(o),
                    ),
                  ]),
                );
              },
            ),
          ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Chip({required this.icon, required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                fontSize: 11, color: color, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}
