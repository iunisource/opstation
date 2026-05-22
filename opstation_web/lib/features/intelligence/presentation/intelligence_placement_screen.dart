import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import 'package:printing/printing.dart';
import '../services/intelligence_pdf_service.dart';

class IntelligencePlacementScreen extends ConsumerStatefulWidget {
  const IntelligencePlacementScreen({super.key});
  @override
  ConsumerState<IntelligencePlacementScreen> createState() => _IntelligencePlacementScreenState();
}

class _IntelligencePlacementScreenState extends ConsumerState<IntelligencePlacementScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _products = [];
  // customer_id -> product_id -> latest audit row
  Map<String, Map<String, Map<String, dynamic>>> _latest = {};
  final _customerSearchCtrl = TextEditingController();
  final _productSearchCtrl = TextEditingController();

  String? _selectedSalespersonId;
  String? _selectedRouteId;
  List<Map<String, dynamic>> _salespeople = [];
  List<Map<String, dynamic>> _routes = [];
  final Map<String, String> _userNames = {};
  final Map<String, Set<String>> _customerToRoutes = {};
  final Map<String, Set<String>> _salespersonToRoutes = {};
  final Map<String, Map<String, String?>> _latestUserId = {};

  @override
  void initState() {
    super.initState();
    _load();
    _loadFilters();
  }

  @override
  void dispose() {
    _customerSearchCtrl.dispose();
    _productSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFilters() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;

      final salespeopleRows = await client
          .from('users')
          .select('id, name')
          .eq('org_id', orgId)
          .eq('role', 'salesperson')
          .order('name');

      final allUsers = await client
          .from('users')
          .select('id, name')
          .eq('org_id', orgId);
      final names = <String, String>{
        for (final u in allUsers)
          u['id'] as String: (u['name'] as String?) ?? 'Unknown',
      };

      final routesRows = await client
          .from('sales_routes')
          .select('id, name')
          .eq('org_id', orgId)
          .eq('kind', 'recurring')
          .order('name');
      final routeIds = [for (final r in routesRows) r['id'] as String];

      final spToRoutes = <String, Set<String>>{};
      if (routeIds.isNotEmpty) {
        final assignments = await client
            .from('route_assignments')
            .select('user_id, route_id')
            .inFilter('route_id', routeIds);
        for (final a in assignments) {
          final uid = a['user_id'] as String;
          final rid = a['route_id'] as String;
          spToRoutes.putIfAbsent(uid, () => <String>{}).add(rid);
        }
      }

      final custToRoutes = <String, Set<String>>{};
      if (routeIds.isNotEmpty) {
        final stops = await client
            .from('route_stops')
            .select('customer_id, route_id')
            .inFilter('route_id', routeIds);
        for (final s in stops) {
          final cid = s['customer_id'] as String;
          final rid = s['route_id'] as String;
          custToRoutes.putIfAbsent(cid, () => <String>{}).add(rid);
        }
      }

      final auditRows = await client
          .from('placement_audit')
          .select('customer_id, product_id, surveyed_by_user_id, surveyed_at')
          .eq('org_id', orgId)
          .order('surveyed_at', ascending: false);
      final latestUserId = <String, Map<String, String?>>{};
      for (final r in auditRows) {
        final cid = r['customer_id'] as String;
        final pid = r['product_id'] as String?;
        final uid = r['surveyed_by_user_id'] as String?;
        if (pid == null || uid == null) continue;
        latestUserId
            .putIfAbsent(cid, () => <String, String?>{})
            .putIfAbsent(pid, () => uid);
      }

      print('LF[place] counts: salespeople=${salespeopleRows.length} allUsers=${allUsers.length} routes=${routesRows.length} routeIds=${routeIds.length} sp2r=${spToRoutes.length} c2r=${custToRoutes.length} audits=${auditRows.length}');
      if (!mounted) return;
      setState(() {
        _userNames..clear()..addAll(names);
        _salespeople = List<Map<String, dynamic>>.from(salespeopleRows);
        _routes = List<Map<String, dynamic>>.from(routesRows);
        _customerToRoutes..clear()..addAll(custToRoutes);
        _salespersonToRoutes..clear()..addAll(spToRoutes);
        _latestUserId..clear()..addAll(latestUserId);
      });
    } catch (e, st) {
      print('placement _loadFilters error: $e\n$st');
    }
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final auditRows = await client
          .from('placement_audit')
          .select('customer_id, product_id, is_present, surveyed_at, surveyed_by_user_id')
          .eq('org_id', orgId)
          .order('surveyed_at', ascending: false);
      final audits = List<Map<String, dynamic>>.from(auditRows);

      // Dedupe to latest per (customer_id, product_id)
      final latest = <String, Map<String, Map<String, dynamic>>>{};
      for (final a in audits) {
        final cid = a['customer_id'] as String;
        final pid = a['product_id'] as String;
        latest.putIfAbsent(cid, () => {});
        if (!latest[cid]!.containsKey(pid)) {
          latest[cid]![pid] = a;
        }
      }

      List<Map<String, dynamic>> customers = [];
      if (latest.keys.isNotEmpty) {
        final rows = await client
            .from('customers')
            .select('id, shop_name, code')
            .eq('org_id', orgId)
            .inFilter('id', latest.keys.toList());
        customers = List<Map<String, dynamic>>.from(rows);
        customers.sort((a, b) => (a['shop_name'] as String).compareTo(b['shop_name'] as String));
      }

      final productRows = await client
          .from('intelligence_products')
          .select('id, name, sku_code, position')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('position');

      setState(() {
        _customers = customers;
        _products = List<Map<String, dynamic>>.from(productRows);
        _latest = latest;
        _loading = false;
      });
    } catch (e) {
      print('Placement load failed: $e');
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filteredCustomers {
    Iterable<Map<String, dynamic>> result = _customers;
    final q = _customerSearchCtrl.text.toLowerCase();
    if (q.isNotEmpty) {
      result = result.where((c) =>
        (c['shop_name'] as String).toLowerCase().contains(q) ||
        (c['code'] as String? ?? '').toLowerCase().contains(q)
      );
    }
    if (_selectedRouteId != null) {
      result = result.where((c) =>
        _customerToRoutes[c['id']]?.contains(_selectedRouteId) ?? false
      );
    }
    if (_selectedSalespersonId != null) {
      final spRoutes = _salespersonToRoutes[_selectedSalespersonId] ?? const <String>{};
      result = result.where((c) {
        final crs = _customerToRoutes[c['id']] ?? const <String>{};
        return crs.any(spRoutes.contains);
      });
    }
    return result.toList();
  }

  List<Map<String, dynamic>> get _filteredProducts {
    final q = _productSearchCtrl.text.toLowerCase();
    if (q.isEmpty) return _products;
    return _products.where((p) =>
      (p['name'] as String).toLowerCase().contains(q) ||
      (p['sku_code'] as String? ?? '').toLowerCase().contains(q)
    ).toList();
  }

  void _showCellDetail(Map<String, dynamic> customer, Map<String, dynamic> product, Map<String, dynamic>? audit) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${product['name']} @ ${customer['shop_name']}'),
        content: SizedBox(
          width: 380,
          child: audit == null
              ? const Text('Never surveyed.')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('Status', (audit['is_present'] as bool) ? 'Displayed' : 'Not displayed'),
                    _kv('Surveyed by', _surveyorNameFor(customer['id'] as String, product['id'] as String)),
                    _kv('Last survey', _fmt(audit['surveyed_at'] as String?)),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 100, child: Text(k, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
      Expanded(child: Text(v, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
    ]),
  );

  String _surveyorNameFor(String customerId, String productId) {
    final uid = _latestUserId[customerId]?[productId];
    if (uid == null) return '—';
    return _userNames[uid] ?? '—';
  }

  String _fmt(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) { return iso; }
  }


  void _showChart() {
    final orgId = ref.read(currentUserProvider)?.orgId ?? '';
    showDialog(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 1400,
            maxHeight: MediaQuery.of(context).size.height * 0.9,
          ),
          child: Stack(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              child: SizedBox(height: 520, child: _PlacementTrendChart(orgId: orgId)),
            ),
            Positioned(top: 4, right: 4, child: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            )),
          ]),
        ),
      ),
    );
  }

  Future<void> _exportPdf() async {
    try {
      final orgName = ref.read(currentUserProvider)?.orgName ?? '';
      final bytes = await IntelligencePdfService.generatePlacementAuditPdf(
        orgName: orgName,
        customers: _filteredCustomers,
        products: _filteredProducts,
        latest: _latest,
      );
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: 'placement_audit_${DateTime.now().toIso8601String().split('T').first}.pdf',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF export failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Placement Audit', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
          '${_filteredCustomers.length} shops audited × ${_filteredProducts.length} products. Green = displayed, red = not displayed, dash = never audited. Click a cell for details.',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: DropdownButtonFormField<String?>(
            value: _selectedSalespersonId,
            decoration: const InputDecoration(labelText: 'Salesperson', isDense: true, border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('All salespeople')),
              ..._salespeople.map((s) => DropdownMenuItem<String?>(value: s['id'] as String, child: Text(s['name'] as String))),
            ],
            onChanged: (v) => setState(() => _selectedSalespersonId = v),
          )),
          const SizedBox(width: 12),
          Expanded(child: DropdownButtonFormField<String?>(
            value: _selectedRouteId,
            decoration: const InputDecoration(labelText: 'Route', isDense: true, border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('All routes')),
              ..._routes.map((r) => DropdownMenuItem<String?>(value: r['id'] as String, child: Text(r['name'] as String))),
            ],
            onChanged: (v) => setState(() => _selectedRouteId = v),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(
            controller: _customerSearchCtrl,
            decoration: const InputDecoration(hintText: 'Filter shops...', prefixIcon: Icon(Icons.search)),
            onChanged: (_) => setState(() {}),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextField(
            controller: _productSearchCtrl,
            decoration: const InputDecoration(hintText: 'Filter products...', prefixIcon: Icon(Icons.search)),
            onChanged: (_) => setState(() {}),
          )),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: _showChart,
            icon: const Icon(Icons.show_chart, size: 18),
            label: const Text('Visual chart'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _exportPdf,
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: const Text('Export PDF'),
          ),
        ]),
        const SizedBox(height: 16),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_customers.isEmpty)
          const Expanded(child: Center(child: Text('No placement audits yet. Surveyor will populate via mobile.')))
        else if (_products.isEmpty)
          const Expanded(child: Center(child: Text('No products configured. Add products first.')))
        else
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: DataTable(
                    columnSpacing: 8,
                    headingRowHeight: 60,
                    dataRowMinHeight: 44,
                    dataRowMaxHeight: 44,
                    columns: [
                      const DataColumn(label: SizedBox(width: 200, child: Text('Shop', style: TextStyle(fontWeight: FontWeight.w700)))),
                      ..._filteredProducts.map((p) => DataColumn(
                        label: SizedBox(
                          width: 100,
                          child: Text(p['name'] as String,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )),
                    ],
                    rows: _filteredCustomers.map((c) {
                      final cid = c['id'] as String;
                      return DataRow(cells: [
                        DataCell(SizedBox(
                          width: 200,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(c['shop_name'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                              Text(c['code'] as String? ?? '', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                            ],
                          ),
                        )),
                        ..._filteredProducts.map((p) {
                          final pid = p['id'] as String;
                          final audit = _latest[cid]?[pid];
                          return DataCell(
                            InkWell(
                              onTap: () => _showCellDetail(c, p, audit),
                              child: SizedBox(
                                width: 100,
                                child: Center(
                                  child: audit == null
                                      ? const Text('—', style: TextStyle(color: AppTheme.textSecondary))
                                      : Icon(
                                          (audit['is_present'] as bool) ? Icons.check_circle : Icons.cancel,
                                          color: (audit['is_present'] as bool) ? AppTheme.success : AppTheme.danger,
                                          size: 22,
                                        ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ]);
                    }).toList(),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class _PlacementTrendChart extends StatefulWidget {
  final String orgId;
  const _PlacementTrendChart({required this.orgId});
  @override
  State<_PlacementTrendChart> createState() => _PlacementTrendChartState();
}

class _PlacementTrendChartState extends State<_PlacementTrendChart> {
  bool _loading = true;
  List<FlSpot> _spots = [];
  double _maxY = 5;
  static const int _days = 30;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day).subtract(const Duration(days: _days - 1));
      final rows = await client.from('placement_audit')
          .select('customer_id, surveyed_at')
          .eq('org_id', widget.orgId)
          .gte('surveyed_at', start.toUtc().toIso8601String());
      final perDay = <int, Set<String>>{};
      for (final r in rows) {
        final ts = DateTime.parse(r['surveyed_at'] as String).toLocal();
        final offset = DateTime(ts.year, ts.month, ts.day).difference(start).inDays;
        if (offset >= 0 && offset < _days) {
          perDay.putIfAbsent(offset, () => <String>{}).add(r['customer_id'] as String);
        }
      }
      final spots = List<FlSpot>.generate(_days, (i) =>
          FlSpot(i.toDouble(), (perDay[i]?.length ?? 0).toDouble()));
      double maxY = 4;
      for (final s in spots) if (s.y > maxY) maxY = s.y;
      if (!mounted) return;
      setState(() { _spots = spots; _maxY = (maxY * 1.25).ceilToDouble(); _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Shops Audited (Last 30 Days)', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            const Spacer(),
            const _LegendDot(color: Color(0xFF14B8A6)),
            const SizedBox(width: 4),
            const Text('Distinct shops/day', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: _loading ? const Center(child: CircularProgressIndicator())
                : LineChart(LineChartData(
                    minX: 0, maxX: (_days - 1).toDouble(), minY: 0, maxY: _maxY,
                    gridData: const FlGridData(show: true, drawVerticalLine: false),
                    titlesData: FlTitlesData(
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 28, interval: 1)),
                      bottomTitles: AxisTitles(sideTitles: SideTitles(
                        showTitles: true, reservedSize: 24, interval: 6,
                        getTitlesWidget: (v, _) {
                          final dt = DateTime.now().subtract(Duration(days: _days - 1 - v.toInt()));
                          return Padding(padding: const EdgeInsets.only(top: 6),
                            child: Text('${dt.day}/${dt.month}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)));
                        },
                      )),
                    ),
                    borderData: FlBorderData(show: false),
                    lineBarsData: [
                      LineChartBarData(
                        spots: _spots,
                        color: const Color(0xFF14B8A6),
                        barWidth: 2.5, isCurved: false,
                        dotData: FlDotData(show: true, checkToShowDot: (spot, _) => spot.y > 0),
                        belowBarData: BarAreaData(show: true, color: const Color(0xFF14B8A6).withOpacity(0.1)),
                      ),
                    ],
                  )),
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  const _LegendDot({required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}
