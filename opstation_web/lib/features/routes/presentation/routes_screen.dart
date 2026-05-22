import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
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
  final _searchCtrl = TextEditingController();
  bool _loading = true;

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
      final routes = await client
          .from('sales_routes')
          .select()
          .eq('org_id', orgId)
          .order('name');
      final stops = await client
          .from('route_stops')
          .select('route_id, customer_id, position');
      // Paginate past PostgREST's 1000-row default cap
      final List<Map<String, dynamic>> customers = [];
      {
        const pageSize = 1000;
        var offset = 0;
        while (true) {
          final page = await client
              .from('customers')
              .select('id, shop_name, code')
              .eq('org_id', orgId)
              .order('shop_name')
              .range(offset, offset + pageSize - 1);
          customers.addAll(List<Map<String, dynamic>>.from(page));
          if (page.length < pageSize) break;
          offset += pageSize;
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
      _customers = customers;
      _filter();
      setState(() => _loading = false);
    } catch (_) {
      setState(() => _loading = false);
    }
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

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
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
                        child: Row(children: [
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
                                icon: const Icon(Icons.swap_vert, size: 18, color: AppTheme.primary),
                                onPressed: () => _showReorderDialog(context, row),
                                tooltip: 'Reorder stops'),
                          IconButton(
                              icon:
                                  const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () => _showDialog(context, row)),
                          IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 18, color: AppTheme.danger),
                              onPressed: () =>
                                  _delete(r['id'] as String)),
                        ]),
                      );
                    },
                  ),
          ),
      ]),
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
  void _showDialog(BuildContext context, _RouteRow? route) {
    final nameCtrl = TextEditingController(text: route?.data['name'] ?? '');
    String kind = route?.data['kind'] ?? 'recurring';
    // Selected customer ids in stop order. For new routes, empty.
    // For edits, populated from the loaded stops.
    final selectedIds = <String>[
      for (final s in route?.stops ?? const []) s['customer_id'] as String,
    ];
    final customerSearchCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setS) {
        // Filter customer list by code/name as the user types
        final q = customerSearchCtrl.text.trim().toLowerCase();
        final visibleCustomers = q.isEmpty
            ? _customers
            : _customers.where((c) {
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
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      'Customers (${selectedIds.length} selected · ${_customers.length} total)',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppTheme.textSecondary))),
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
                    ? const Center(
                        child: Text('No customers match your search.'))
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
                        'created_at': now.toIso8601String(),
                      });
                    } else {
                      // Update
                      routeId = route.data['id'] as String;
                      await client.from('sales_routes').update({
                        'name': nameCtrl.text.trim(),
                        'kind': kind,
                        'updated_at': now.toIso8601String(),
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
