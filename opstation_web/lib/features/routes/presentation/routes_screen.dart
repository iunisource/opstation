import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/format/money.dart';
import '../../auth/auth_controller.dart';

class RoutesScreen extends ConsumerStatefulWidget {
  const RoutesScreen({super.key});
  @override
  ConsumerState<RoutesScreen> createState() => _RoutesScreenState();
}

class _RoutesScreenState extends ConsumerState<RoutesScreen> {
  // Routes plus their stops (joined in-memory) and customers cache.
  // Stops are stored separately in the route_stops table; we hydrate
  // each route with its stop count and stop ids on load.
  List<_RouteRow> _routes = [];
  List<_RouteRow> _filtered = [];
  List<Map<String, dynamic>> _customers = [];
  bool _customersLoaded = false;
  Future<void>? _customersFuture; // de-dupes concurrent loads
  final _searchCtrl = TextEditingController();
  bool _loading = true;
  bool _targetsEnabled = false;
  // route_id -> rpc_route_target_achievement row (target/achieved/etc).
  // Populated only when the customer-targets toggle is ON.
  final Map<String, Map<String, dynamic>> _routeAch = {};
  // route_id -> assigned salesperson name (from route_assignments + users).
  // One route maps to one salesperson under our assignment rule.
  final Map<String, String> _routeAssignee = {};
  // route_id -> user_id of its current owner (one owner at a time).
  final Map<String, String> _routeOwnerId = {};

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_filter);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      // The routes LIST needs only routes/stops/assignees — not the (often
      // thousands of) customers — so fetch just those, in parallel, and load the
      // full customer list lazily when a route editor or the stop picker opens.
      final res = await Future.wait([
        client.from('sales_routes').select().eq('org_id', orgId).order('name'),
        client.from('route_stops').select('route_id, customer_id, position').eq('org_id', orgId),
        client.from('route_assignments').select('route_id, user_id'),
        client.from('users').select('id, name').eq('org_id', orgId).or('role.is.null,role.neq.retailer'),
      ]);
      final routes = res[0] as List;
      final stops = res[1] as List;
      final assignments = res[2] as List;
      final teamUsers = res[3] as List;
      final userNameById = <String, String>{
        for (final u in teamUsers)
          (u as Map)['id'] as String: ((u)['name'] as String? ?? '').trim(),
      };
      _routeAssignee.clear();
      _routeOwnerId.clear();
      for (final a in (assignments as List)) {
        final m = a as Map;
        final rid = m['route_id'] as String?;
        final uid = m['user_id'] as String?;
        if (rid == null || uid == null) continue;
        _routeOwnerId[rid] = uid;
        final nm = userNameById[uid];
        if (nm == null || nm.isEmpty) continue;
        // Show EVERY assignee — previously the last one silently overwrote the
        // others, so a route assigned to two people showed only one name.
        final cur = _routeAssignee[rid];
        if (cur == null || cur.isEmpty) {
          _routeAssignee[rid] = nm;
        } else if (!cur.split(', ').contains(nm)) {
          _routeAssignee[rid] = '$cur, $nm';
        }
      }
      // Group stops by route
      final byRoute = <String, List<Map<String, dynamic>>>{};
      for (final s in (stops as List)) {
        final m = Map<String, dynamic>.from(s as Map);
        final rid = m['route_id'] as String;
        byRoute.putIfAbsent(rid, () => []).add(m);
      }
      for (final list in byRoute.values) {
        list.sort((a, b) =>
            (a['position'] as int).compareTo(b['position'] as int));
      }

      _routes = [
        for (final r in (routes as List))
          _RouteRow(
            data: Map<String, dynamic>.from(r as Map),
            stops: byRoute[(r as Map)['id'] as String] ?? const [],
          )
      ];

      // Warm the customer list in the background so it's usually ready by the
      // time a route editor / stop picker is opened — without blocking the list.
      _ensureCustomers();

      // Sales-targets overlay (gated). Read the org toggle; if ON, pull
      // accumulated route target/achievement in a single RPC call. This is
      // an optional overlay — any failure leaves the routes list intact.
      _routeAch.clear();
      var targetsOn = false;
      try {
        final tgl = await client
            .from('app_config')
            .select('value')
            .eq('org_id', orgId)
            .eq('key', 'org.customer_targets_enabled')
            .maybeSingle();
        targetsOn = (tgl?['value'] as String?) == 'true';
        if (targetsOn) {
          final rows = await client.rpc(
            'rpc_route_target_achievement',
            params: {'p_org_id': orgId},
          );
          for (final r in (rows as List)) {
            final m = Map<String, dynamic>.from(r as Map);
            final rid = m['route_id'] as String?;
            if (rid != null) _routeAch[rid] = m;
          }
        }
      } catch (_) {
        targetsOn = false;
        _routeAch.clear();
      }
      _targetsEnabled = targetsOn;

      _filter();
      setState(() => _loading = false);
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  // Lazily loads the full active-customer list once (paginated past the 1000-row
  // cap), caching it. Concurrent callers share the same in-flight future.
  Future<void> _ensureCustomers() {
    if (_customersLoaded) return Future.value();
    return _customersFuture ??= () async {
      final orgId = ref.read(currentUserProvider)?.orgId;
      if (orgId == null) return;
      try {
        final client = Supabase.instance.client;
        final out = <Map<String, dynamic>>[];
        const pageSize = 1000;
        var offset = 0;
        while (true) {
          final page = await client
              .from('customers')
              .select('id, shop_name, code')
              .eq('org_id', orgId)
              .eq('is_active', true)
              .order('shop_name')
              .range(offset, offset + pageSize - 1);
          out.addAll(List<Map<String, dynamic>>.from(page));
          if (page.length < pageSize) break;
          offset += pageSize;
        }
        if (mounted) setState(() { _customers = out; _customersLoaded = true; });
      } catch (_) {
        _customersFuture = null; // allow a retry on the next open
      }
    }();
  }

  void _filter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) {
      _filtered = List.of(_routes);
    } else {
      _filtered = _routes
          .where((r) => (r.data['name'] as String? ?? '')
              .toLowerCase()
              .contains(q))
          .toList();
    }
    setState(() {});
  }

  /// Compact target/progress strip for a route, shown only when the
  /// customer-targets feature is enabled. Reads from the _routeAch map
  /// populated in _load() via rpc_route_target_achievement (accumulated
  /// across all of the route's customers for the running calendar month).
  Widget _routeProgress(String routeId) {
    final ach = _routeAch[routeId];
    if (ach == null) return const SizedBox.shrink();
    final target = (ach['target'] as num?)?.toDouble() ?? 0;
    final achieved = (ach['achieved'] as num?)?.toDouble() ?? 0;
    final salesperson = (ach['salesperson_name'] as String?)?.trim();
    final pct = target <= 0 ? 0.0 : (achieved / target).clamp(0.0, 1.0);
    final pctLabel =
        target <= 0 ? '—' : '${(achieved / target * 100).round()}%';
    final met = target > 0 && achieved >= target;
    final remaining = target - achieved;
    final barColor = met ? AppTheme.success : AppTheme.primary;

    return Padding(
      padding: const EdgeInsets.only(top: 12, left: 56),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.flag_outlined,
                size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(
              'Rs ${_money(achieved)} of Rs ${_money(target)}',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                  color: barColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10)),
              child: Text(pctLabel,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: barColor)),
            ),
            const Spacer(),
            if (salesperson != null && salesperson.isNotEmpty)
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.person_outline,
                    size: 13, color: AppTheme.textSecondary),
                const SizedBox(width: 4),
                Text(salesperson,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ]),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: AppTheme.border,
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            met
                ? 'Target met'
                : (target <= 0
                    ? 'No target set'
                    : 'Rs ${_money(remaining)} to go'),
            style: TextStyle(
                fontSize: 11,
                color: met ? AppTheme.success : AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  /// Whole-rupee formatting with thousands separators (no decimals; sales
  /// targets and invoice totals are tracked as whole rupees here).
  String _money(num v) => money(v);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 16 : 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Routes',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          OutlinedButton.icon(
              onPressed: () => context.push('/routes/import'),
              icon: const Icon(Icons.upload_file, size: 18),
              label: const Text('Bulk Import')),
          const SizedBox(width: 8),
          ElevatedButton.icon(
              onPressed: () => _showDialog(context, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Route')),
        ]),
        const SizedBox(height: 8),
        Text('${_filtered.length} of ${_routes.length} routes',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        TextField(
          controller: _searchCtrl,
          decoration: const InputDecoration(
            hintText: 'Search routes by name...',
            prefixIcon: Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 16),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else
          Expanded(
            child: _filtered.isEmpty
                ? const Center(
                    child: Text('No routes match your search.'))
                : ListView.separated(
                    itemCount: _filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      final row = _filtered[i];
                      final r = row.data;
                      final kind = r['kind'] as String? ?? 'recurring';
                      final isActive = r['is_active'] as bool? ?? true;
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border:
                                Border.all(color: AppTheme.border)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                    color: kind == 'recurring'
                                        ? AppTheme.success.withOpacity(0.1)
                                        : AppTheme.warning.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(8)),
                                child: Icon(
                                    kind == 'recurring'
                                        ? Icons.all_inclusive
                                        : Icons.event_available_outlined,
                                    color: kind == 'recurring'
                                        ? AppTheme.success
                                        : AppTheme.warning,
                                    size: 20),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(r['name'] as String? ?? '',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 15)),
                                    Text(
                                        '${kind == 'recurring' ? 'Recurring' : 'One-time'} · ${row.stops.length} stops',
                                        style: const TextStyle(
                                            color: AppTheme.textSecondary,
                                            fontSize: 13)),
                                    const SizedBox(height: 4),
                                    Builder(builder: (_) {
                                      final assignee = _routeAssignee[
                                          r['id'] as String];
                                      final assigned = assignee != null &&
                                          assignee.isNotEmpty;
                                      return InkWell(
                                        onTap: () => _showAssignDialog(
                                            r['id'] as String,
                                            '${r['name'] ?? ''}'),
                                        borderRadius: BorderRadius.circular(4),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.person_outline,
                                                size: 14,
                                                color: assigned
                                                    ? AppTheme.primary
                                                    : AppTheme.textSecondary),
                                            const SizedBox(width: 4),
                                            Text(
                                                assigned
                                                    ? assignee
                                                    : 'Unassigned',
                                                style: TextStyle(
                                                    color: assigned
                                                        ? AppTheme.primary
                                                        : AppTheme
                                                            .textSecondary,
                                                    fontSize: 12.5,
                                                    fontWeight: assigned
                                                        ? FontWeight.w600
                                                        : FontWeight.w400,
                                                    fontStyle: assigned
                                                        ? FontStyle.normal
                                                        : FontStyle.italic)),
                                            const SizedBox(width: 4),
                                            Icon(Icons.edit_outlined,
                                                size: 12,
                                                color: AppTheme.textSecondary
                                                    .withOpacity(0.7)),
                                          ]));
                                    }),
                                  ])),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                    color: isActive
                                        ? AppTheme.success.withOpacity(0.1)
                                        : AppTheme.danger.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(6)),
                                child: Text(isActive ? 'Active' : 'Inactive',
                                    style: TextStyle(
                                        color: isActive
                                            ? AppTheme.success
                                            : AppTheme.danger,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                              ),
                              const SizedBox(width: 8),
                              if (row.stops.length > 1)
                                IconButton(
                                    icon: const Icon(Icons.swap_vert,
                                        size: 18, color: AppTheme.primary),
                                    onPressed: () =>
                                        _showReorderDialog(context, row),
                                    tooltip: 'Reorder stops'),
                              IconButton(
                                  icon: const Icon(Icons.person_add_alt_1_outlined,
                                      size: 18, color: AppTheme.primary),
                                  tooltip: 'Assign / hand over',
                                  onPressed: () => _showAssignDialog(
                                      r['id'] as String, '${r['name'] ?? ''}')),
                              IconButton(
                                  icon: const Icon(Icons.history,
                                      size: 18, color: AppTheme.textSecondary),
                                  tooltip: 'Assignment history',
                                  onPressed: () => _showAssignmentHistory(
                                      r['id'] as String, '${r['name'] ?? ''}')),
                              IconButton(
                                  icon: const Icon(Icons.edit_outlined,
                                      size: 18),
                                  onPressed: () => _showDialog(context, row)),
                              IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      size: 18, color: AppTheme.danger),
                                  onPressed: () =>
                                      _delete(r['id'] as String)),
                            ]),
                            if (_targetsEnabled &&
                                _routeAch[r['id'] as String] != null)
                              _routeProgress(r['id'] as String),
                          ],
                        ),
                      );
                    },
                  ),
          ),
      ]),
    );
  }

  /// Assign a route to a salesperson, hand it over, or unassign it — the same
  /// one-owner rule as Team → Assign Routes (the database moves the route
  /// from its previous owner in one step and records it in the history).
  Future<void> _showAssignDialog(String routeId, String routeName) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final me = ref.read(currentUserProvider)?.id;
    if (orgId == null) return;
    final client = Supabase.instance.client;
    List<Map<String, dynamic>> people = [];
    try {
      people = List<Map<String, dynamic>>.from(await client
          .from('users')
          .select('id, name, role, is_active')
          .eq('org_id', orgId)
          .eq('role', 'salesperson')
          .order('name'));
      people = people.where((u) => u['is_active'] != false).toList();
    } catch (e) {
      _showSnack('Could not load salespersons: ${e.toString().split('\n').first}');
      return;
    }
    if (!mounted) return;
    final currentId = _routeOwnerId[routeId];
    final currentName = _routeAssignee[routeId];
    String? picked = currentId;
    final searchCtrl = TextEditingController();

    final action = await showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setS) {
        final q = searchCtrl.text.trim().toLowerCase();
        final list = q.isEmpty
            ? people
            : people.where((u) => '${u['name'] ?? ''}'.toLowerCase().contains(q)).toList();
        final changing = picked != null && picked != currentId;
        final pickedName = people
            .firstWhere((u) => u['id'] == picked, orElse: () => const {'name': ''})['name'];
        return AlertDialog(
          title: const Text('Assign route'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(routeName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                currentName == null || currentName.isEmpty
                    ? 'Currently unassigned'
                    : 'Currently with $currentName',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: searchCtrl,
                onChanged: (_) => setS(() {}),
                decoration: const InputDecoration(
                    hintText: 'Search salesperson…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
              ),
              const SizedBox(height: 8),
              Container(
                height: 260,
                decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
                child: list.isEmpty
                    ? const Center(child: Text('No salespersons found.'))
                    : ListView(children: [
                        for (final u in list)
                          RadioListTile<String>(
                            dense: true,
                            value: u['id'] as String,
                            groupValue: picked,
                            onChanged: (v) => setS(() => picked = v),
                            title: Text('${u['name'] ?? ''}', style: const TextStyle(fontSize: 13)),
                            secondary: u['id'] == currentId
                                ? const Text('Current', style: TextStyle(fontSize: 11, color: AppTheme.success))
                                : null,
                          ),
                      ]),
              ),
              if (changing && currentId != null) ...[
                const SizedBox(height: 8),
                Text('This hands the route over: $currentName will no longer have it.',
                    style: TextStyle(fontSize: 12, color: Colors.orange.shade800, fontWeight: FontWeight.w600)),
              ],
              if (changing && pickedName != null && '$pickedName'.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text('New owner: $pickedName', style: const TextStyle(fontSize: 12)),
              ],
            ]),
          ),
          actions: [
            if (currentId != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'unassign'),
                style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
                child: const Text('Unassign'),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: changing ? () => Navigator.pop(ctx, 'assign') : null,
              child: Text(currentId == null ? 'Assign' : 'Hand over'),
            ),
          ],
        );
      }),
    );
    if (action == null || !mounted) return;

    Future<void> notify(String userId, String title, String body) async {
      try {
        await client.functions.invoke('send-notification',
            body: {'userId': userId, 'title': title, 'body': body});
      } catch (_) {}
    }

    try {
      if (action == 'unassign' && currentId != null) {
        await client.from('route_assignments').delete().eq('route_id', routeId);
        await notify(currentId, 'Route removed', '$routeName is no longer assigned to you.');
        _showSnack('Route unassigned');
      } else if (action == 'assign' && picked != null) {
        await client.from('route_assignments').insert({
          'user_id': picked,
          'route_id': routeId,
          'assigned_at': DateTime.now().toUtc().toIso8601String(),
          'assigned_by': me,
        });
        final newName = people.firstWhere((u) => u['id'] == picked, orElse: () => const {'name': ''})['name'];
        await notify(picked!, 'New Route Assigned', '$routeName has been assigned to you.');
        if (currentId != null) {
          await notify(currentId, 'Route handed over', '$routeName is now with $newName.');
        }
        _showSnack(currentId == null ? 'Assigned to $newName' : 'Handed over to $newName');
      }
      await _load();
    } catch (e) {
      final m = e.toString();
      _showSnack(m.contains('duplicate') || m.contains('23505')
          ? 'This route already has an owner — refresh and try again.'
          : 'Could not save: ${m.split('\n').first}');
    }
  }

  /// Route lifecycle: every assignment, hand-over and un-assignment
  /// (route_assignment_log, SQL 359), newest first.
  Future<void> _showAssignmentHistory(String routeId, String routeName) async {
    List<Map<String, dynamic>> rows = [];
    String? err;
    try {
      rows = List<Map<String, dynamic>>.from(await Supabase.instance.client
          .from('route_assignment_log')
          .select()
          .eq('route_id', routeId)
          .order('changed_at', ascending: false)
          .limit(200));
    } catch (e) {
      err = e.toString().contains('route_assignment_log')
          ? 'This feature isn\'t set up yet — please contact Opstation support.'
          : 'Could not load: ${e.toString().split('\n').first}';
    }
    if (!mounted) return;
    final names = <String, String>{
      for (final m in rows)
        if (m['changed_by'] != null) m['changed_by'] as String: '',
    };
    if (names.isNotEmpty) {
      try {
        final u = await Supabase.instance.client
            .from('users').select('id, name').inFilter('id', names.keys.toList());
        for (final x in (u as List)) {
          names[x['id'] as String] = '${x['name'] ?? ''}';
        }
      } catch (_) {}
    }
    if (!mounted) return;
    final df = DateFormat('d MMM y, h:mm a');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Assignment history', style: const TextStyle(fontSize: 18)),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(routeName, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            const SizedBox(height: 10),
            if (err != null)
              Text(err, style: const TextStyle(color: AppTheme.danger))
            else if (rows.isEmpty)
              const Text('No changes recorded yet.',
                  style: TextStyle(color: AppTheme.textSecondary))
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final m = rows[i];
                    final note = '${m['note'] ?? ''}';
                    final from = m['from_name'] as String?;
                    final to = m['to_name'] as String?;
                    final when = DateTime.tryParse('${m['changed_at'] ?? ''}')?.toLocal();
                    final by = names[m['changed_by']] ?? '';
                    final (IconData icon, Color color, String what) = note.startsWith('Handed')
                        ? (Icons.swap_horiz, Colors.orange.shade800, '${from ?? '—'} → ${to ?? '—'}')
                        : note == 'Unassigned'
                            ? (Icons.person_remove_outlined, AppTheme.danger, 'Removed from ${from ?? '—'}')
                            : note.startsWith('Clean-up')
                                ? (Icons.cleaning_services_outlined, AppTheme.textSecondary,
                                    'Kept with ${to ?? '—'}, removed from ${from ?? '—'}')
                                : (Icons.person_add_alt_1_outlined, AppTheme.success, 'Assigned to ${to ?? '—'}');
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(icon, size: 18, color: color),
                      title: Text(what, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        [
                          if (when != null) df.format(when),
                          if (by.isNotEmpty) 'by $by',
                          if (note.startsWith('Clean-up')) 'one-time clean-up of a double assignment',
                        ].join(' · '),
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    );
                  },
                ),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Future<void> _delete(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Route'),
        content: const Text(
            'This will permanently remove the route and its stops. Continue?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.danger),
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirm == true) {
      final client = Supabase.instance.client;
      // Delete child stops first, then the route. Both are scoped by id.
      await client.from('route_stops').delete().eq('route_id', id);
      await client.from('sales_routes').delete().eq('id', id);
      _showSnack('Route deleted');
      _load();
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _showReorderDialog(BuildContext context, _RouteRow row) async {
    await _ensureCustomers(); // resolve stop names in the editor
    if (!mounted) return;
    // Snapshot the current stops sorted by position; user reorders this list
    // and on save we delete + re-insert with new positions (same pattern as edit).
    final stops = List<Map<String, dynamic>>.from(row.stops)
      ..sort((a, b) => ((a['position'] as int?) ?? 0)
          .compareTo((b['position'] as int?) ?? 0));

    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (dialogCtx, setSt) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Reorder stops · ${row.data['name']}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text('Drag to reorder. Click Save to apply.',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                  const SizedBox(height: 16),
                  Flexible(
                    child: ReorderableListView.builder(
                      shrinkWrap: true,
                      buildDefaultDragHandles: false,
                      itemCount: stops.length,
                      onReorder: (oldIdx, newIdx) {
                        setSt(() {
                          if (newIdx > oldIdx) newIdx -= 1;
                          final item = stops.removeAt(oldIdx);
                          stops.insert(newIdx, item);
                        });
                      },
                      itemBuilder: (_, i) {
                        final stop = stops[i];
                        final cId = stop['customer_id'] as String;
                        final cust = _customers.firstWhere(
                          (c) => c['id'] == cId,
                          orElse: () => <String, dynamic>{'shop_name': '(unknown)', 'code': ''},
                        );
                        return Container(
                          key: ValueKey(cId),
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppTheme.background,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.border),
                          ),
                          child: Row(children: [
                            Container(
                              width: 28, height: 28,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppTheme.primary.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text('${i + 1}',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.primary)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(cust['shop_name'] as String? ?? '',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600, fontSize: 14)),
                                  Text(cust['code'] as String? ?? '',
                                      style: const TextStyle(
                                          color: AppTheme.textSecondary, fontSize: 11)),
                                ],
                              ),
                            ),
                            ReorderableDragStartListener(
                              index: i,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4),
                                child: Icon(Icons.drag_handle, color: AppTheme.textSecondary),
                              ),
                            ),
                          ]),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () =>
                            Navigator.of(dialogCtx, rootNavigator: true).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.save_outlined, size: 18),
                        label: const Text('Save order'),
                        onPressed: () async {
                          final routeId = row.data['id'] as String;
                          final client = Supabase.instance.client;
                          try {
                            await client.from('route_stops').delete().eq('route_id', routeId);
                            await client.from('route_stops').insert([
                              for (var i = 0; i < stops.length; i++)
                                {
                                  'route_id': routeId,
                                  'customer_id': stops[i]['customer_id'],
                                  'position': i,
                                },
                            ]);
                            if (dialogCtx.mounted) {
                              Navigator.of(dialogCtx, rootNavigator: true).pop();
                            }
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Stop order updated')),
                              );
                            }
                            _load();
                          } catch (e) {
                            if (dialogCtx.mounted) {
                              ScaffoldMessenger.of(dialogCtx).showSnackBar(
                                SnackBar(content: Text('Failed to save: $e')),
                              );
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Add or edit a route. Edits replace the stops list wholesale —
  /// simpler than diffing, fine for our scale.
  Future<void> _showDialog(BuildContext context, _RouteRow? route) async {
    await _ensureCustomers(); // the picker needs the full customer list
    if (!mounted) return;
    final nameCtrl = TextEditingController(text: route?.data['name'] ?? '');
    String kind = route?.data['kind'] ?? 'recurring';
    // Selected customer ids in stop order. For new routes, empty.
    // For edits, populated from the loaded stops.
    final selectedIds = <String>[
      for (final s in route?.stops ?? const []) s['customer_id'] as String,
    ];
    final customerSearchCtrl = TextEditingController();
    var selectedOnly = false;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setS) {
        // Filter customer list by code/name as the user types
        final q = customerSearchCtrl.text.trim().toLowerCase();
        // "Selected only": the route's customers, in stop order.
        final pool = selectedOnly
            ? [
                for (final id in selectedIds)
                  ..._customers.where((c) => c['id'] == id).take(1),
              ]
            : _customers;
        final visibleCustomers = q.isEmpty
            ? pool
            : pool.where((c) {
                final code =
                    (c['code'] as String? ?? '').toLowerCase();
                final name =
                    (c['shop_name'] as String? ?? '').toLowerCase();
                return code.contains(q) || name.contains(q);
              }).toList();

        return AlertDialog(
          title: Text(route == null ? 'Add Route' : 'Edit Route'),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: nameCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Route Name')),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: kind,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(
                      value: 'recurring', child: Text('Recurring')),
                  DropdownMenuItem(
                      value: 'one_time', child: Text('One-time')),
                ],
                onChanged: (v) => setS(() => kind = v!),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: Text(
                      'Customers (${selectedIds.length} selected · ${_customers.length} total)',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppTheme.textSecondary)),
                ),
                FilterChip(
                  label: Text(selectedOnly ? 'Selected only (${selectedIds.length})' : 'Show selected only',
                      style: const TextStyle(fontSize: 12)),
                  selected: selectedOnly,
                  showCheckmark: true,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) => setS(() => selectedOnly = v),
                ),
              ]),
              const SizedBox(height: 8),
              TextField(
                controller: customerSearchCtrl,
                onChanged: (_) => setS(() {}),
                decoration: const InputDecoration(
                  hintText: 'Search customers by code or name...',
                  prefixIcon: Icon(Icons.search, size: 18),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 220,
                decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.border),
                    borderRadius: BorderRadius.circular(8)),
                child: visibleCustomers.isEmpty
                    ? Center(
                        child: Text(selectedOnly && selectedIds.isEmpty
                            ? 'No customers selected yet.'
                            : 'No customers match your search.'))
                    : ListView(
                        children: visibleCustomers.map((c) {
                        final id = c['id'] as String;
                        final selected = selectedIds.contains(id);
                        return CheckboxListTile(
                          dense: true,
                          title: Text(
                              '${c['code']} · ${c['shop_name']}',
                              style: const TextStyle(fontSize: 13)),
                          value: selected,
                          onChanged: (v) => setS(() {
                            if (v == true) {
                              if (!selectedIds.contains(id)) {
                                selectedIds.add(id);
                              }
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
                  final orgId = ref.read(currentUserProvider)?.orgId;
                  if (orgId == null) return;
                  final client = Supabase.instance.client;
                  final now = DateTime.now();

                  try {
                    String routeId;
                    if (route == null) {
                      // Create
                      routeId =
                          'route_${now.millisecondsSinceEpoch}';
                      await client.from('sales_routes').insert({
                        'id': routeId,
                        'name': nameCtrl.text.trim(),
                        'kind': kind,
                        'is_active': true,
                        'org_id': orgId,
                        'created_at': now.toUtc().toIso8601String(),
                      });
                    } else {
                      // Update
                      routeId = route.data['id'] as String;
                      await client.from('sales_routes').update({
                        'name': nameCtrl.text.trim(),
                        'kind': kind,
                        'updated_at': now.toUtc().toIso8601String(),
                      }).eq('id', routeId);
                      // Replace stops wholesale
                      await client
                          .from('route_stops')
                          .delete()
                          .eq('route_id', routeId);
                    }

                    // Insert stops in selection order
                    if (selectedIds.isNotEmpty) {
                      final stopRows = [
                        for (int i = 0; i < selectedIds.length; i++)
                          {
                            'route_id': routeId,
                            'customer_id': selectedIds[i],
                            'position': i + 1,
                          }
                      ];
                      await client
                          .from('route_stops')
                          .insert(stopRows);
                    }

                    if (ctx.mounted) {
                      Navigator.of(ctx, rootNavigator: true).pop();
                    }
                    _showSnack(route == null
                        ? 'Route added'
                        : 'Route updated');
                    _load();
                  } catch (e) {
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                          content:
                              Text('Failed: ${e.toString().split('\n').first}')));
                    }
                  }
                },
                child: Text(route == null ? 'Add' : 'Save')),
          ],
        );
      }),
    );
  }
}

/// Local view-model: a route plus its hydrated stops list. We keep
/// this here rather than a shared model because the routes screen is
/// the only consumer.
class _RouteRow {
  final Map<String, dynamic> data;
  final List<Map<String, dynamic>> stops;
  const _RouteRow({required this.data, required this.stops});
}
