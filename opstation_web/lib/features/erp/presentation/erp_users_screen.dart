import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/permissions/permission_registry.dart';
import '../../auth/auth_controller.dart';
import '../../../core/utils/friendly_error.dart';

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

  // ── "How they use the app" activity panel ───────────────────────────────
  Future<void> _showActivity(Map<String, dynamic> u) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final now = DateTime.now();
    final from = now.subtract(const Duration(days: 30));
    String d(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.insights_outlined, size: 18, color: AppTheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text('${u['name'] ?? 'User'} — App usage', style: const TextStyle(fontSize: 16))),
        ]),
        content: SizedBox(
          width: 520,
          child: FutureBuilder(
            future: Supabase.instance.client.rpc('erp_user_activity', params: {
              'p_org': orgId, 'p_user': u['id'], 'p_from': d(from), 'p_to': d(now),
            }),
            builder: (ctx, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
              }
              if (snap.hasError || snap.data == null) {
                return const Padding(padding: EdgeInsets.all(12), child: Text('Could not load activity.'));
              }
              return _activityBody(Map<String, dynamic>.from(snap.data as Map));
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('Close'))],
      ),
    );
  }

  Widget _activityBody(Map<String, dynamic> m) {
    final total = (m['total'] as num?)?.toInt() ?? 0;
    final voided = (m['voided'] as num?)?.toInt() ?? 0;
    final backdated = (m['backdated'] as num?)?.toInt() ?? 0;
    final afterHours = (m['after_hours'] as num?)?.toInt() ?? 0;
    final activeDays = (m['active_days'] as num?)?.toInt() ?? 0;
    final approvals = (m['approvals'] as num?)?.toInt() ?? 0;
    final byModule = Map<String, dynamic>.from(m['by_module'] as Map? ?? {});
    final last = m['last_active'] != null ? DateTime.tryParse(m['last_active'] as String)?.toLocal() : null;
    final daysSince = last == null ? null : DateTime.now().difference(last).inDays;

    if (total == 0 && approvals == 0) {
      return const Padding(padding: EdgeInsets.all(8),
        child: Text('No voucher activity in the last 30 days.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)));
    }

    // top module
    String? topMod; int topN = 0;
    byModule.forEach((k, v) { final n = (v as num).toInt(); if (n > topN) { topN = n; topMod = k; } });
    final modules = byModule.keys.toList()..sort();
    final voidPct = total > 0 ? (voided / total * 100) : 0.0;

    final amber = Colors.amber.shade800;
    final notes = <(IconData, Color, String)>[];
    notes.add((Icons.receipt_long, AppTheme.primary,
        '$total voucher${total == 1 ? '' : 's'} created in 30 days${topMod != null ? ' — mostly $topMod ($topN)' : ''}.'));
    if (approvals > 0) notes.add((Icons.verified, AppTheme.primary, '$approvals purchase order${approvals == 1 ? '' : 's'} approved.'));
    if (modules.isNotEmpty) notes.add((Icons.dashboard_customize_outlined, AppTheme.textSecondary,
        'Works across: ${[for (final k in modules) '$k (${(byModule[k] as num).toInt()})'].join(', ')}.'));
    if (voided > 0) {
      notes.add((voidPct >= 8 ? Icons.error_outline : Icons.undo, voidPct >= 8 ? AppTheme.danger : amber,
          '$voided (${voidPct.toStringAsFixed(0)}%) of their vouchers were later voided${voidPct >= 8 ? ' — high rework, worth reviewing' : ''}.'));
    }
    if (backdated > 0) notes.add((Icons.event_repeat, amber,
        '$backdated entr${backdated == 1 ? 'y was' : 'ies were'} back-dated (voucher date well before entry) — check timing controls.'));
    if (afterHours > 0 && total > 0 && afterHours / total >= 0.25) notes.add((Icons.nightlight_round, amber,
        '$afterHours of $total entered after hours (after 8 PM / before 6 AM).'));
    if (daysSince != null && daysSince >= 5) notes.add((Icons.event_busy, Colors.orange,
        'No vouchers entered in the last $daysSince days.'));
    if (notes.length <= (modules.isNotEmpty ? 2 : 1)) notes.add((Icons.thumb_up, AppTheme.success,
        'Steady, clean usage — low rework and consistent entry.'));

    final concerns = notes.where((n) => n.$2 == AppTheme.danger).length;
    final warns = notes.where((n) => n.$2 == amber || n.$2 == Colors.orange).length;
    final (IconData, Color, String) head = concerns > 0
        ? (Icons.warning_amber_rounded, AppTheme.danger, 'Needs attention')
        : warns > 0 ? (Icons.info_outline, amber, 'A few habits to watch')
                    : (Icons.check_circle, AppTheme.success, 'Healthy usage');

    // ── Productivity score + estimated active time ──────────────────────────
    // Score = weighted blend of five 0–100 sub-scores. Volume is peer-relative
    // (this user vs the top user that period); Consistency uses the org's actual
    // working days (distinct days anyone was active). Shown transparently below.
    final peerTop = (m['peer_top_total'] as num?)?.toInt() ?? 0;
    final orgActiveDays = (m['org_active_days'] as num?)?.toInt() ?? 0;
    final engagedMin = (m['period_engaged_min'] as num?)?.toDouble() ?? 0;
    final distinctModules = byModule.keys.length;
    const totalModules = 5; // Purchase, Sales, Accounts, Inventory, Production
    double clamp100(double v) => v < 0 ? 0 : (v > 100 ? 100 : v);
    final sVolume = peerTop > 0 ? clamp100(total / peerTop * 100) : (total > 0 ? 100.0 : 0.0);
    final sConsistency = orgActiveDays > 0 ? clamp100(activeDays / orgActiveDays * 100) : 0.0;
    final sBreadth = clamp100(distinctModules / totalModules * 100);
    final sTimeliness = total > 0 ? clamp100(100 - backdated / total * 100) : 100.0;
    final sQuality = total > 0 ? clamp100(100 - voidPct.toDouble()) : 100.0;
    final productivity =
        (0.40 * sVolume + 0.20 * sConsistency + 0.15 * sBreadth + 0.15 * sTimeliness + 0.10 * sQuality).round();
    final scoreColor = productivity >= 75 ? AppTheme.success : (productivity >= 50 ? amber : AppTheme.danger);
    final scoreLabel = productivity >= 75 ? 'Strong' : (productivity >= 50 ? 'Steady' : 'Needs attention');
    final hrs = engagedMin ~/ 60;
    final mns = (engagedMin % 60).round();
    final timeStr = hrs > 0 ? '${hrs}h ${mns}m' : '${mns}m';
    final daysDenom = orgActiveDays == 0 ? activeDays : orgActiveDays;

    Widget subBar(String label, double v) => Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(children: [
        SizedBox(width: 82, child: Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
        Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: (v / 100).clamp(0, 1), minHeight: 7,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation(v >= 75 ? AppTheme.success : (v >= 50 ? amber : AppTheme.danger))))),
        const SizedBox(width: 8),
        SizedBox(width: 28, child: Text('${v.round()}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
      ]),
    );

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 54, height: 54, alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: scoreColor.withOpacity(0.12), border: Border.all(color: scoreColor, width: 2)),
              child: Text('$productivity', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: scoreColor))),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Productivity · $scoreLabel', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: scoreColor)),
              const SizedBox(height: 3),
              Text('~$timeStr active  ·  $total vouchers  ·  $activeDays/$daysDenom working days',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ])),
          ]),
          const SizedBox(height: 12),
          subBar('Volume', sVolume),
          subBar('Consistency', sConsistency),
          subBar('Breadth', sBreadth),
          subBar('Timeliness', sTimeliness),
          subBar('Quality', sQuality),
        ]),
      ),
      Row(children: [
        Icon(head.$1, size: 16, color: head.$2),
        const SizedBox(width: 6),
        Text(head.$3, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: head.$2)),
        const Spacer(),
        Text('active ${activeDays}d${daysSince != null ? ' · last ${daysSince == 0 ? 'today' : '${daysSince}d ago'}' : ''}',
            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ]),
      const SizedBox(height: 12),
      for (final n in notes) ...[
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(n.$1, size: 16, color: n.$2),
          const SizedBox(width: 8),
          Expanded(child: Text(n.$3, style: const TextStyle(fontSize: 13, height: 1.35))),
        ]),
        const SizedBox(height: 8),
      ],
    ]);
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
      _showSnack(friendlyError('That did not save', e));
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
                    // Apply the "New Password" field through the admin-API Edge
                    // Function so it lands in auth.users — the login source of
                    // truth for both web and mobile. The old code ignored this
                    // field entirely, so resets here silently did nothing.
                    final newPass = passCtrl.text;
                    if (newPass.isNotEmpty) {
                      if (newPass.length < 6) {
                        throw Exception('Password must be at least 6 characters');
                      }
                      final rp = await client.functions.invoke(
                        'reset-team-user-password',
                        body: {
                          'email': (user['email'] as String?) ??
                              emailCtrl.text.trim().toLowerCase(),
                          'newPassword': newPass,
                        },
                      );
                      final rd = rp.data as Map<String, dynamic>?;
                      if (rd == null || rd['ok'] != true) {
                        throw Exception(rd?['error'] ?? 'Password reset failed');
                      }
                    }
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
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(friendlyError('That did not save', e))));
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
                    SizedBox(width: 120),
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
                                  SizedBox(width: 120, child: Row(children: [
                                    IconButton(icon: const Icon(Icons.insights_outlined, size: 18, color: AppTheme.primary),
                                        tooltip: 'How they use the app', onPressed: () => _showActivity(u)),
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
