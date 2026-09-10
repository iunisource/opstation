import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import 'salesperson_history_screen.dart';
import 'driver_history_screen.dart';
import 'team_member_360_screen.dart';
import '../../../core/widgets/responsive.dart';

class TeamScreen extends ConsumerStatefulWidget {
  const TeamScreen({super.key});
  @override
  ConsumerState<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends ConsumerState<TeamScreen> {
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
      final rows = await Supabase.instance.client
          .from('users')
          .select()
          .eq('org_id', orgId)
          .neq('role', 'retailer')
          .order('name');
      setState(() { _users = List<Map<String, dynamic>>.from(rows); _loading = false; });
    } catch (_) { setState(() => _loading = false); }
  }

  Color _roleColor(String role) {
    switch (role) {
      case 'masterAdmin': return AppTheme.primary;
      case 'admin': return const Color(0xFF8B5CF6);
      case 'salesperson': return AppTheme.success;
      case 'driver': return AppTheme.warning;
      case 'dispatchManager': return const Color(0xFF06B6D4);
      case 'surveyor': return const Color(0xFFEC4899);
      case 'accountant': return const Color(0xFF4F46E5);
      default: return AppTheme.textSecondary;
    }
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'masterAdmin': return 'Master Admin';
      case 'admin': return 'Admin';
      case 'salesperson': return 'Salesperson';
      case 'driver': return 'Driver';
      case 'dispatchManager': return 'Dispatch Manager';
      case 'surveyor': return 'Surveyor';
      case 'accountant': return 'Accountant';
      case 'superAdmin': return 'Super Admin';
      default: return role;
    }
  }

  // ---- Authorization helpers ------------------------------------------
  //
  // Web is now an edit/manage surface only — user creation lives on
  // mobile (so password hashes and Drift state are always written
  // correctly together). Web can still edit existing users, deactivate
  // them, delete them (masterAdmin only), and assign routes.

  bool _canEdit(String? viewerRole, Map<String, dynamic> target, String? viewerId) {
    final targetRole = target['role'] as String? ?? '';
    final isSelf = viewerId != null && target['id'] == viewerId;
    if (viewerRole == 'masterAdmin') return true;
    if (viewerRole == 'admin') {
      if (isSelf) return true;
      if (targetRole == 'masterAdmin' || targetRole == 'admin') return false;
      return true;
    }
    return false;
  }

  bool _canDeactivate(String? viewerRole, Map<String, dynamic> target, String? viewerId) {
    final targetRole = target['role'] as String? ?? '';
    final isSelf = viewerId != null && target['id'] == viewerId;
    if (isSelf) return false;
    if (viewerRole == 'masterAdmin') return true;
    if (viewerRole == 'admin') {
      if (targetRole == 'masterAdmin' || targetRole == 'admin') return false;
      return true;
    }
    return false;
  }

  bool _canDelete(String? viewerRole, Map<String, dynamic> target, String? viewerId) {
    final isSelf = viewerId != null && target['id'] == viewerId;
    if (isSelf) return false;
    if (viewerRole == 'masterAdmin') return true;
    return false;
  }

  void _openHistory(BuildContext context, Map<String, dynamic> u) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SalespersonHistoryScreen(
        userId: u['id'] as String,
        userName: u['name'] as String? ?? '',
      ),
    ));
  }

  void _openDriverHistory(BuildContext context, Map<String, dynamic> u) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DriverHistoryScreen(
        userId: u['id'] as String,
        userName: u['name'] as String? ?? '',
      ),
    ));
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewer = ref.watch(authControllerProvider).valueOrNull;
    final viewerRole = viewer?.role.name;
    final viewerId = viewer?.id;

    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Team', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 8),
          Text('${_users.length} members · Create new members from the mobile app',
              style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 24),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Expanded(
              child: HScrollOnNarrow(minWidth: 900, child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: const BoxDecoration(
                        color: AppTheme.background,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                      ),
                      child: const Row(children: [
                        Expanded(flex: 3, child: Text('Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 3, child: Text('Email', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Role', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Phone', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 1, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        SizedBox(width: 170),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _users.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final u = _users[i];
                          final role = u['role'] as String? ?? '';
                          final isActive = u['is_active'] as bool? ?? true;
                          final canEdit = _canEdit(viewerRole, u, viewerId);
                          final canDeactivate = _canDeactivate(viewerRole, u, viewerId);
                          final canDelete = _canDelete(viewerRole, u, viewerId);
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(children: [
                              Expanded(flex: 3, child: Row(children: [
                                CircleAvatar(
                                  radius: 18,
                                  backgroundColor: _roleColor(role).withOpacity(0.1),
                                  child: Text((u['name'] as String? ?? 'U').substring(0, 1).toUpperCase(),
                                    style: TextStyle(color: _roleColor(role), fontWeight: FontWeight.w700)),
                                ),
                                const SizedBox(width: 10),
                                Text(u['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                              ])),
                              Expanded(flex: 3, child: Text(u['email'] as String? ?? '', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                              Expanded(flex: 2, child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(color: _roleColor(role).withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                                child: Text(_roleLabel(role), style: TextStyle(color: _roleColor(role), fontSize: 12, fontWeight: FontWeight.w600)),
                              )),
                              Expanded(flex: 2, child: Text(u['phone'] as String? ?? '-', style: const TextStyle(fontSize: 13))),
                              Expanded(flex: 1, child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isActive ? AppTheme.success.withOpacity(0.1) : AppTheme.danger.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(isActive ? 'Active' : 'Inactive',
                                  style: TextStyle(color: isActive ? AppTheme.success : AppTheme.danger, fontSize: 12, fontWeight: FontWeight.w600)),
                              )),
                              SizedBox(width: 220, child: Row(children: [
                                IconButton(
                                  icon: const Icon(Icons.account_circle_outlined, size: 18, color: AppTheme.primary),
                                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => TeamMember360Screen(user: u),
                                  )),
                                  tooltip: 'Profile',
                                ),
                                if (canEdit)
                                  IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _showEditUser(context, u), tooltip: 'Edit'),
                                if (role == 'salesperson') ...[
                                  IconButton(
                                    icon: const Icon(Icons.history, size: 18, color: AppTheme.success),
                                    onPressed: () => _openHistory(context, u),
                                    tooltip: 'Visit History',
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.alt_route, size: 18, color: AppTheme.primary),
                                    onPressed: () => _showAssignRoutes(context, u),
                                    tooltip: 'Assign Routes',
                                  ),
                                ],
                                if (role == 'driver')
                                  IconButton(
                                    icon: const Icon(Icons.history, size: 18, color: AppTheme.success),
                                    onPressed: () => _openDriverHistory(context, u),
                                    tooltip: 'Delivery History',
                                  ),
                                if (canDeactivate)
                                  IconButton(
                                    icon: Icon(isActive ? Icons.block : Icons.check_circle_outline, size: 18,
                                      color: isActive ? AppTheme.danger : AppTheme.success),
                                    onPressed: () => _toggleActive(u),
                                    tooltip: isActive ? 'Deactivate' : 'Activate',
                                  ),
                                if (canDelete)
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                                    onPressed: () => _delete(u),
                                    tooltip: 'Delete',
                                  ),
                              ])),
                            ]),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              )),
            ),
        ],
      ),
    );
  }

  Future<void> _toggleActive(Map<String, dynamic> u) async {
    final viewer = ref.read(authControllerProvider).valueOrNull;
    if (viewer != null && u['id'] == viewer.id) {
      _showSnack("You can't deactivate yourself.");
      return;
    }
    final newVal = !(u['is_active'] as bool? ?? true);
    try {
      await Supabase.instance.client.from('users').update({'is_active': newVal}).eq('id', u['id']);
      _showSnack(newVal ? 'User activated' : 'User deactivated');
      _load();
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _delete(Map<String, dynamic> u) async {
    final viewer = ref.read(authControllerProvider).valueOrNull;
    if (viewer != null && u['id'] == viewer.id) {
      _showSnack("You can't delete yourself.");
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete User'),
        content: Text('Permanently delete ${u['name']}? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client.from('users').delete().eq('id', u['id']);
      _showSnack('User deleted');
      _load();
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
    }
  }

  void _showEditUser(BuildContext context, Map<String, dynamic> user) {
    final nameCtrl = TextEditingController(text: user['name'] ?? '');
    final phoneCtrl = TextEditingController(text: user['phone'] ?? '');
    String role = user['role'] ?? 'salesperson';

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Edit Member'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full Name')),
                const SizedBox(height: 12),
                // Email is the auth identity — not editable from web. To
                // change someone's email, recreate the user on mobile
                // with the new email and delete the old row here.
                TextField(
                  controller: TextEditingController(text: user['email'] ?? ''),
                  decoration: const InputDecoration(
                    labelText: 'Email (locked)',
                    helperText: 'Email is the auth identity and cannot be changed here.',
                  ),
                  enabled: false,
                ),
                const SizedBox(height: 12),
                TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone')),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: role,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: const [
                    DropdownMenuItem(value: 'admin', child: Text('Admin')),
                    DropdownMenuItem(value: 'salesperson', child: Text('Salesperson')),
                    DropdownMenuItem(value: 'driver', child: Text('Driver')),
                    DropdownMenuItem(value: 'dispatchManager', child: Text('Dispatch Manager')),
                    DropdownMenuItem(value: 'surveyor', child: Text('Surveyor')),
                    DropdownMenuItem(value: 'accountant', child: Text('Accountant')),
                  ],
                  onChanged: (v) => setS(() => role = v!),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Name is required')));
                  return;
                }
                try {
                  await Supabase.instance.client.from('users').update({
                    'name': nameCtrl.text.trim(),
                    'phone': phoneCtrl.text.trim(),
                    'role': role,
                  }).eq('id', user['id']);
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack('Member updated');
                  _load();
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                      content: Text('Failed: ${e.toString().split('\n').first}'),
                    ));
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAssignRoutes(
      BuildContext context, Map<String, dynamic> user) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final actorId = ref.read(currentUserProvider)?.id;
    if (orgId == null || actorId == null) return;

    final client = Supabase.instance.client;
    List<Map<String, dynamic>> routes = [];
    Set<String> originalAssignedIds = {};

    try {
      final routesRes = await client
          .from('sales_routes')
          .select('id, name, kind, is_active')
          .eq('org_id', orgId)
          .order('name');
      final assignmentsRes = await client
          .from('route_assignments')
          .select('route_id')
          .eq('user_id', user['id']);
      // Fetch all org-wide assignments so we can hide routes already taken
      // by other salespersons (one route -> one salesperson rule).
      final allAssignmentsRes = await client
          .from('route_assignments')
          .select('user_id, route_id');
      final assignedElsewhere = <String>{};
      for (final a in (allAssignmentsRes as List)) {
        final m = a as Map;
        final uid = m['user_id'] as String;
        final rid = m['route_id'] as String;
        if (uid != user['id']) assignedElsewhere.add(rid);
      }
      final allRoutes = List<Map<String, dynamic>>.from(routesRes);
      routes = [
        for (final r in allRoutes)
          if (!assignedElsewhere.contains(r['id'] as String)) r,
      ];
      originalAssignedIds = {
        for (final a in (assignmentsRes as List))
          (a as Map)['route_id'] as String,
      };
    } catch (e) {
      _showSnack('Failed to load: ${e.toString().split('\n').first}');
      return;
    }

    if (!context.mounted) return;

    final selectedIds = Set<String>.from(originalAssignedIds);
    final searchCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setS) {
        final q = searchCtrl.text.trim().toLowerCase();
        final visibleRoutes = q.isEmpty
            ? routes
            : routes.where((r) {
                final name = (r['name'] as String? ?? '').toLowerCase();
                return name.contains(q);
              }).toList();

        return AlertDialog(
          title: Text('Assign Routes — ${user['name'] ?? 'Salesperson'}'),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: searchCtrl,
                onChanged: (_) => setS(() {}),
                decoration: const InputDecoration(
                  hintText: 'Search routes by name...',
                  prefixIcon: Icon(Icons.search, size: 18),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('${selectedIds.length} of ${routes.length} selected',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ),
              const SizedBox(height: 8),
              Container(
                height: 320,
                decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.border),
                    borderRadius: BorderRadius.circular(8)),
                child: visibleRoutes.isEmpty
                    ? const Center(
                        child: Text('No routes match your search.',
                            style: TextStyle(
                                color: AppTheme.textSecondary,
                                fontStyle: FontStyle.italic)))
                    : ListView(
                        children: visibleRoutes.map((r) {
                        final id = r['id'] as String;
                        final selected = selectedIds.contains(id);
                        final kind = r['kind'] as String? ?? 'recurring';
                        final isActive = r['is_active'] as bool? ?? true;
                        return CheckboxListTile(
                          dense: true,
                          title: Text(r['name'] as String? ?? '',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                          subtitle: Text(
                              '${kind == 'recurring' ? 'Recurring' : 'One-time'}${isActive ? '' : ' · Inactive'}',
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.textSecondary)),
                          value: selected,
                          onChanged: (v) => setS(() {
                            if (v == true) {
                              selectedIds.add(id);
                            } else {
                              selectedIds.remove(id);
                            }
                          }),
                        );
                      }).toList()),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () =>
                    Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () async {
                  final toRemove =
                      originalAssignedIds.difference(selectedIds);
                  final toAdd =
                      selectedIds.difference(originalAssignedIds);

                  if (toRemove.isEmpty && toAdd.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('No changes.')));
                    return;
                  }

                  try {
                    for (final routeId in toRemove) {
                      await client
                          .from('route_assignments')
                          .delete()
                          .eq('user_id', user['id'])
                          .eq('route_id', routeId);
                    }
                    if (toAdd.isNotEmpty) {
                      final now = DateTime.now().toIso8601String();
                      final newRows = [
                        for (final routeId in toAdd)
                          {
                            'user_id': user['id'],
                            'route_id': routeId,
                            'assigned_at': now,
                            'assigned_by': actorId,
                          }
                      ];
                      await client
                          .from('route_assignments')
                          .insert(newRows);

                      // FCM notify the salesperson about newly added routes.
                      try {
                        final routesById = {
                          for (final r in routes) r['id'] as String: r,
                        };
                        final names = [
                          for (final id in toAdd)
                            (routesById[id]?['name'] as String?) ?? 'a route',
                        ];
                        final body = names.length == 1
                            ? '${names.first} has been assigned to you.'
                            : '${names.length} new routes have been assigned: '
                                '${names.take(3).join(", ")}'
                                '${names.length > 3 ? "..." : ""}';
                        print('FCM: invoking send-notification for salesperson ${user['id']}');
                        await client.functions.invoke(
                          'send-notification',
                          body: {
                            'userId': user['id'],
                            'title': 'New Route Assigned',
                            'body': body,
                          },
                        );
                      } catch (e, st) {
                        print('FCM notify failed (web route assignment): $e\n$st');
                      }
                    }

                    if (ctx.mounted) {
                      Navigator.of(ctx, rootNavigator: true).pop();
                    }
                    _showSnack('Updated assignments: +${toAdd.length}, -${toRemove.length}');
                  } catch (e) {
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                          content: Text(
                              'Failed: ${e.toString().split('\n').first}')));
                    }
                  }
                },
                child: const Text('Save')),
          ],
        );
      }),
    );
  }
}
