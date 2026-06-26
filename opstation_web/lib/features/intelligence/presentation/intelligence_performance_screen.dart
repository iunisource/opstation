import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Sales-target performance for the running calendar month, surfaced two ways:
///   • By Salesperson — route rows grouped by the route's current salesperson,
///     totals accumulated; expand to see that person's routes, then customers.
///   • By Route — one card per active route; expand to see its customers.
///
/// All figures come from the same engine as the routes screen and CRM 360:
///   rpc_route_target_achievement(p_org_id)            -> one row per route
///   rpc_route_customer_achievement(p_org_id, p_route) -> customers in a route
///
/// The whole section is gated by org.customer_targets_enabled; the sidebar
/// already hides the menu item when off, but we re-check here so a direct hit
/// on the URL shows a clean notice instead of an empty screen.
class IntelligencePerformanceScreen extends ConsumerStatefulWidget {
  const IntelligencePerformanceScreen({super.key});
  @override
  ConsumerState<IntelligencePerformanceScreen> createState() =>
      _IntelligencePerformanceScreenState();
}

class _IntelligencePerformanceScreenState
    extends ConsumerState<IntelligencePerformanceScreen> {
  bool _loading = true;
  bool _enabled = true;
  String _mode = 'salesperson'; // 'salesperson' | 'route'
  final _searchCtrl = TextEditingController();

  // One row per active route from rpc_route_target_achievement.
  List<Map<String, dynamic>> _routeRows = [];

  // Lazy per-route customer drill-down (rpc_route_customer_achievement).
  final Map<String, List<Map<String, dynamic>>> _custCache = {};
  final Set<String> _custLoading = {};

  // Expansion state.
  final Set<String> _expandedRoutes = {};
  final Set<String> _expandedSalespeople = {};

  static const String _unassigned = '__unassigned__';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
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
      final tgl = await client
          .from('app_config')
          .select('value')
          .eq('org_id', orgId)
          .eq('key', 'org.customer_targets_enabled')
          .maybeSingle();
      final on = (tgl?['value'] as String?) == 'true';
      if (!on) {
        if (!mounted) return;
        setState(() {
          _enabled = false;
          _routeRows = [];
          _loading = false;
        });
        return;
      }

      final rows = await client.rpc(
        'rpc_route_target_achievement',
        params: {'p_org_id': orgId},
      );
      final list = [
        for (final r in (rows as List)) Map<String, dynamic>.from(r as Map)
      ];
      if (!mounted) return;
      setState(() {
        _enabled = true;
        _routeRows = list;
        _loading = false;
      });
    } catch (e, st) {
      print('performance _load error: $e\n$st');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _loadCustomers(String routeId) async {
    if (_custCache.containsKey(routeId) || _custLoading.contains(routeId)) {
      return;
    }
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _custLoading.add(routeId));
    try {
      final client = Supabase.instance.client;
      final rows = await client.rpc(
        'rpc_route_customer_achievement',
        params: {'p_org_id': orgId, 'p_route_id': routeId},
      );
      final list = [
        for (final r in (rows as List)) Map<String, dynamic>.from(r as Map)
      ];
      if (!mounted) return;
      setState(() {
        _custCache[routeId] = list;
        _custLoading.remove(routeId);
      });
    } catch (e, st) {
      print('performance _loadCustomers error: $e\n$st');
      if (!mounted) return;
      setState(() {
        _custCache[routeId] = [];
        _custLoading.remove(routeId);
      });
    }
  }

  // ── Derived data ───────────────────────────────────────────────────────────

  List<_SpGroup> _salespersonGroups() {
    final map = <String, _SpGroup>{};
    for (final r in _routeRows) {
      final sid = (r['salesperson_id'] as String?) ?? _unassigned;
      final sname =
          (r['salesperson_name'] as String?)?.trim().isNotEmpty == true
              ? (r['salesperson_name'] as String).trim()
              : 'Unassigned';
      final g = map.putIfAbsent(sid, () => _SpGroup(id: sid, name: sname));
      g.routes.add(r);
      g.target += (r['target'] as num?)?.toDouble() ?? 0;
      g.achieved += (r['achieved'] as num?)?.toDouble() ?? 0;
      g.customerCount += (r['customer_count'] as num?)?.toInt() ?? 0;
    }
    final list = map.values.toList();
    // Leaderboard order: most achieved first; unassigned sinks to the bottom.
    list.sort((a, b) {
      if (a.id == _unassigned) return 1;
      if (b.id == _unassigned) return -1;
      return b.achieved.compareTo(a.achieved);
    });
    return list;
  }

  List<Map<String, dynamic>> _routesSorted() {
    final list = List<Map<String, dynamic>>.from(_routeRows);
    list.sort((a, b) => ((b['achieved'] as num?)?.toDouble() ?? 0)
        .compareTo((a['achieved'] as num?)?.toDouble() ?? 0));
    return list;
  }

  bool _matchesSearch(String text) {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return text.toLowerCase().contains(q);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Performance',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text(
          'Sales-target achievement for the current month. Tap a salesperson '
          'or route to drill down to customer level.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 16),
        Row(children: [
          _segment(),
          const Spacer(),
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Refresh',
          ),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: _mode == 'salesperson'
                ? 'Filter salespeople...'
                : 'Filter routes...',
            prefixIcon: const Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(child: _body()),
      ]),
    );
  }

  Widget _segment() {
    Widget btn(String value, String label, IconData icon) {
      final selected = _mode == value;
      return InkWell(
        onTap: () => setState(() => _mode = value),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppTheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                size: 16,
                color: selected ? Colors.white : AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : AppTheme.textSecondary)),
          ]),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        btn('salesperson', 'By Salesperson', Icons.people_outline),
        const SizedBox(width: 4),
        btn('route', 'By Route', Icons.route_outlined),
      ]),
    );
  }

  Widget _body() {
    if (!_enabled) {
      return _notice(
        Icons.flag_outlined,
        'Customer targets are turned off',
        'Enable "Customer sales targets" in ERP → Admin Settings to use this section.',
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_routeRows.isEmpty) {
      return _notice(
        Icons.insights_outlined,
        'Nothing to show yet',
        'No active routes were returned. Add routes and assign salespeople, '
            'then set monthly targets on customers.',
      );
    }
    return _mode == 'salesperson' ? _salespersonList() : _routeList();
  }

  Widget _notice(IconData icon, String title, String subtitle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 44, color: AppTheme.textSecondary),
          const SizedBox(height: 12),
          Text(title,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13)),
        ]),
      ),
    );
  }

  // ── By Salesperson ─────────────────────────────────────────────────────────

  Widget _salespersonList() {
    final groups = _salespersonGroups()
        .where((g) => _matchesSearch(g.name))
        .toList();
    if (groups.isEmpty) {
      return const Center(child: Text('No salespeople match your search.'));
    }
    return ListView.separated(
      itemCount: groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _spCard(groups[i]),
    );
  }

  Widget _spCard(_SpGroup g) {
    final expanded = _expandedSalespeople.contains(g.id);
    final pct = g.target <= 0 ? 0.0 : (g.achieved / g.target).clamp(0.0, 1.0);
    final met = g.target > 0 && g.achieved >= g.target;
    final color = met ? AppTheme.success : AppTheme.primary;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() {
            if (expanded) {
              _expandedSalespeople.remove(g.id);
            } else {
              _expandedSalespeople.add(g.id);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: Icon(Icons.person_outline, color: color, size: 20),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                        '${g.routes.length} route${g.routes.length == 1 ? '' : 's'} · ${g.customerCount} customers',
                        style: const TextStyle(
                            color: AppTheme.textSecondary, fontSize: 13)),
                    const SizedBox(height: 8),
                    _barRow(g.target, g.achieved),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _pctChip(g.target, g.achieved),
              Icon(expanded ? Icons.expand_less : Icons.expand_more,
                  color: AppTheme.textSecondary),
            ]),
          ),
        ),
        if (expanded) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              children: [
                for (final r in g.routes) _routeBlock(r, nested: true),
              ],
            ),
          ),
        ],
      ]),
    );
  }

  // ── By Route ───────────────────────────────────────────────────────────────

  Widget _routeList() {
    final routes = _routesSorted()
        .where((r) => _matchesSearch((r['route_name'] as String?) ?? ''))
        .toList();
    if (routes.isEmpty) {
      return const Center(child: Text('No routes match your search.'));
    }
    return ListView.separated(
      itemCount: routes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: _routeBlock(routes[i], nested: false),
      ),
    );
  }

  /// A route header plus its (lazy) customer drill-down. Used both as a
  /// standalone card (By Route) and nested inside a salesperson (By Salesperson).
  Widget _routeBlock(Map<String, dynamic> r, {required bool nested}) {
    final routeId = r['route_id'] as String;
    final name = (r['route_name'] as String?) ?? '';
    final target = (r['target'] as num?)?.toDouble() ?? 0;
    final achieved = (r['achieved'] as num?)?.toDouble() ?? 0;
    final custCount = (r['customer_count'] as num?)?.toInt() ?? 0;
    final salesperson =
        (r['salesperson_name'] as String?)?.trim().isNotEmpty == true
            ? (r['salesperson_name'] as String).trim()
            : null;
    final expanded = _expandedRoutes.contains(routeId);
    final color = (target > 0 && achieved >= target)
        ? AppTheme.success
        : AppTheme.primary;

    final header = InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        setState(() {
          if (expanded) {
            _expandedRoutes.remove(routeId);
          } else {
            _expandedRoutes.add(routeId);
          }
        });
        if (!expanded) _loadCustomers(routeId);
      },
      child: Padding(
        padding: EdgeInsets.all(nested ? 12 : 16),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.route_outlined, color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 2),
                Text(
                    [
                      if (!nested && salesperson != null) salesperson,
                      '$custCount customers',
                    ].join(' · '),
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12)),
                const SizedBox(height: 8),
                _barRow(target, achieved),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _pctChip(target, achieved),
          Icon(expanded ? Icons.expand_less : Icons.expand_more,
              color: AppTheme.textSecondary, size: 20),
        ]),
      ),
    );

    return Container(
      margin: nested ? const EdgeInsets.only(bottom: 8) : EdgeInsets.zero,
      decoration: nested
          ? BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border),
            )
          : null,
      child: Column(children: [
        header,
        if (expanded) ...[
          Divider(height: 1, color: AppTheme.border),
          _customerDrill(routeId, nested: nested),
        ],
      ]),
    );
  }

  Widget _customerDrill(String routeId, {required bool nested}) {
    if (_custLoading.contains(routeId)) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    final custs = _custCache[routeId] ?? const [];
    if (custs.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No customers on this route.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(nested ? 12 : 16, 8, nested ? 12 : 16, 12),
      child: Column(
        children: [
          for (final c in custs) _customerRow(c),
        ],
      ),
    );
  }

  Widget _customerRow(Map<String, dynamic> c) {
    final code = (c['code'] as String?) ?? '';
    final shop = (c['shop_name'] as String?) ?? '';
    final target = (c['monthly_sale_target'] as num?)?.toDouble() ?? 0;
    final achieved = (c['achieved'] as num?)?.toDouble() ?? 0;
    final label = code.isEmpty ? shop : '$code · $shop';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: Text(label,
              style: const TextStyle(fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Rs ${_money(achieved)} of Rs ${_money(target)}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              _bar(target, achieved),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(width: 48, child: Align(
          alignment: Alignment.centerRight,
          child: _pctChip(target, achieved),
        )),
      ]),
    );
  }

  // ── Shared bits ────────────────────────────────────────────────────────────

  Widget _barRow(double target, double achieved) {
    final met = target > 0 && achieved >= target;
    final remaining = target - achieved;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Rs ${_money(achieved)} of Rs ${_money(target)}',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 6),
        _bar(target, achieved),
        const SizedBox(height: 4),
        Text(
          met
              ? 'Target met'
              : (target <= 0 ? 'No target set' : 'Rs ${_money(remaining)} to go'),
          style: TextStyle(
              fontSize: 11,
              color: met ? AppTheme.success : AppTheme.textSecondary),
        ),
      ],
    );
  }

  Widget _bar(double target, double achieved) {
    final pct = target <= 0 ? 0.0 : (achieved / target).clamp(0.0, 1.0);
    final met = target > 0 && achieved >= target;
    final color = met ? AppTheme.success : AppTheme.primary;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: pct,
        minHeight: 6,
        backgroundColor: AppTheme.border,
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }

  Widget _pctChip(double target, double achieved) {
    final met = target > 0 && achieved >= target;
    final color = met ? AppTheme.success : AppTheme.primary;
    final label = target <= 0 ? '—' : '${(achieved / target * 100).round()}%';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10)),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  /// Whole-rupee formatting with thousands separators (no decimals; sales
  /// targets and invoice totals are tracked as whole rupees here).
  String _money(num v) {
    final n = v.round();
    final neg = n < 0;
    final digits = n.abs().toString();
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return '${neg ? '-' : ''}$buf';
  }
}

/// Accumulated totals for one salesperson across all of their routes.
class _SpGroup {
  final String id;
  final String name;
  final List<Map<String, dynamic>> routes = [];
  double target = 0;
  double achieved = 0;
  int customerCount = 0;
  _SpGroup({required this.id, required this.name});
}
