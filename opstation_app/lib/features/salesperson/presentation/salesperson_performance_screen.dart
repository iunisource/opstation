import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';

/// The salesperson's own sales-target performance for the running month —
/// the mobile mirror of the web Intelligence → Performance section, scoped to
/// this user's assigned routes.
///
///   rpc_route_target_achievement(p_org_id)            -> all routes (filtered
///                                                        to this salesperson)
///   rpc_route_customer_achievement(p_org_id, p_route) -> customers in a route
///
/// Gated by org.customer_targets_enabled; the drawer already hides the entry
/// when off, but we re-check here as a safety net.
class SalespersonPerformanceScreen extends ConsumerStatefulWidget {
  const SalespersonPerformanceScreen({super.key});
  @override
  ConsumerState<SalespersonPerformanceScreen> createState() =>
      _SalespersonPerformanceScreenState();
}

class _SalespersonPerformanceScreenState
    extends ConsumerState<SalespersonPerformanceScreen> {
  bool _loading = true;
  bool _enabled = true;
  String? _error;

  // This salesperson's route rows from rpc_route_target_achievement.
  List<Map<String, dynamic>> _routes = [];

  // Lazy per-route customer drill-down.
  final Map<String, List<Map<String, dynamic>>> _custCache = {};
  final Set<String> _custLoading = {};
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = ref.read(authControllerProvider).valueOrNull;
    final orgId = user?.organizationId;
    final userId = user?.id;
    if (orgId == null || userId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
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
          _routes = [];
          _loading = false;
        });
        return;
      }

      final rows = await client.rpc(
        'rpc_route_target_achievement',
        params: {'p_org_id': orgId},
      );
      final mine = [
        for (final r in (rows as List))
          if ((r as Map)['salesperson_id'] == userId)
            Map<String, dynamic>.from(r)
      ];
      if (!mounted) return;
      setState(() {
        _enabled = true;
        _routes = mine;
        _loading = false;
      });
    } catch (e) {
      final s = e.toString().toLowerCase();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = (s.contains('socket') ||
                s.contains('network') ||
                s.contains('connection'))
            ? 'No connection — pull to retry when online.'
            : 'Failed to load performance.';
      });
    }
  }

  Future<void> _loadCustomers(String routeId) async {
    if (_custCache.containsKey(routeId) || _custLoading.contains(routeId)) {
      return;
    }
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _custCache[routeId] = [];
        _custLoading.remove(routeId);
      });
    }
  }

  double get _totalTarget =>
      _routes.fold(0.0, (s, r) => s + ((r['target'] as num?)?.toDouble() ?? 0));
  double get _totalAchieved => _routes.fold(
      0.0, (s, r) => s + ((r['achieved'] as num?)?.toDouble() ?? 0));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('Performance'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimaryLight,
        elevation: 0.5,
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_enabled) {
      return _scrollable(_notice(Icons.flag_outlined,
          'Sales targets are turned off for your organization.'));
    }
    if (_error != null) {
      return _scrollable(_notice(Icons.cloud_off_outlined, _error!));
    }
    if (_routes.isEmpty) {
      return _scrollable(_notice(Icons.route_outlined,
          'No routes assigned to you yet, or no targets set.'));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        _summaryCard(),
        const SizedBox(height: 12),
        for (final r in _routes) ...[
          _routeCard(r),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _scrollable(Widget child) => ListView(
        padding: const EdgeInsets.only(top: 120),
        children: [child],
      );

  Widget _notice(IconData icon, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: AppColors.textTertiaryLight),
            const SizedBox(height: 10),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondaryLight)),
          ]),
        ),
      );

  Widget _summaryCard() {
    final target = _totalTarget;
    final achieved = _totalAchieved;
    final met = target > 0 && achieved >= target;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('This month',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(target <= 0 ? '—' : '${(achieved / target * 100).round()}%',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 10),
        Text('Rs. ${_money(achieved)}',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w800)),
        Text('of Rs. ${_money(target)} target',
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: target <= 0 ? 0 : (achieved / target).clamp(0.0, 1.0),
            minHeight: 7,
            backgroundColor: Colors.white24,
            valueColor:
                const AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        ),
        const SizedBox(height: 8),
        Text(
            met
                ? 'Target met across ${_routes.length} route${_routes.length == 1 ? '' : 's'}'
                : (target <= 0
                    ? 'No targets set on your routes yet'
                    : 'Rs. ${_money(target - achieved)} to go · ${_routes.length} route${_routes.length == 1 ? '' : 's'}'),
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]),
    );
  }

  Widget _routeCard(Map<String, dynamic> r) {
    final routeId = r['route_id'] as String;
    final name = (r['route_name'] as String?) ?? '';
    final target = (r['target'] as num?)?.toDouble() ?? 0;
    final achieved = (r['achieved'] as num?)?.toDouble() ?? 0;
    final custCount = (r['customer_count'] as num?)?.toInt() ?? 0;
    final expanded = _expanded.contains(routeId);
    final met = target > 0 && achieved >= target;
    final color = met ? AppColors.success : AppColors.primary;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            setState(() {
              if (expanded) {
                _expanded.remove(routeId);
              } else {
                _expanded.add(routeId);
              }
            });
            if (!expanded) _loadCustomers(routeId);
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(name,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      _pctChip(target, achieved),
                    ]),
                    const SizedBox(height: 2),
                    Text('$custCount customers',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondaryLight)),
                    const SizedBox(height: 8),
                    Text('Rs. ${_money(achieved)} of Rs. ${_money(target)}',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: target <= 0
                            ? 0
                            : (achieved / target).clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor: AppColors.borderLight,
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(expanded ? Icons.expand_less : Icons.expand_more,
                  color: AppColors.textSecondaryLight),
            ]),
          ),
        ),
        if (expanded) ...[
          Divider(height: 1, color: AppColors.borderLight),
          _customerDrill(routeId),
        ],
      ]),
    );
  }

  Widget _customerDrill(String routeId) {
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
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('No customers on this route.',
            style: TextStyle(
                color: AppColors.textSecondaryLight, fontSize: 12)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Column(children: [
        for (final c in custs) _customerRow(c),
      ]),
    );
  }

  Widget _customerRow(Map<String, dynamic> c) {
    final code = (c['code'] as String?) ?? '';
    final shop = (c['shop_name'] as String?) ?? '';
    final target = (c['monthly_sale_target'] as num?)?.toDouble() ?? 0;
    final achieved = (c['achieved'] as num?)?.toDouble() ?? 0;
    final label = code.isEmpty ? shop : '$code · $shop';
    final met = target > 0 && achieved >= target;
    final color = met ? AppColors.success : AppColors.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          _pctChip(target, achieved),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: target <= 0
                    ? 0
                    : (achieved / target).clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: AppColors.borderLight,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text('Rs. ${_money(achieved)}/${_money(target)}',
              style: TextStyle(
                  fontSize: 11, color: AppColors.textSecondaryLight)),
        ]),
      ]),
    );
  }

  Widget _pctChip(double target, double achieved) {
    final met = target > 0 && achieved >= target;
    final color = met ? AppColors.success : AppColors.primary;
    final label = target <= 0 ? '—' : '${(achieved / target * 100).round()}%';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: met ? AppColors.successLight : AppColors.primaryLight,
          borderRadius: BorderRadius.circular(8)),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  // Whole-rupee formatting with thousands separators (targets are whole rupees).
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
