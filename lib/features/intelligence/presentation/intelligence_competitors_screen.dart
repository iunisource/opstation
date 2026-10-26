import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/responsive.dart';
import '../../auth/auth_controller.dart';
import 'package:printing/printing.dart';
import '../services/intelligence_pdf_service.dart';
import '../widgets/searchable_dropdown.dart';

class IntelligenceCompetitorsScreen extends ConsumerStatefulWidget {
  const IntelligenceCompetitorsScreen({super.key});
  @override
  ConsumerState<IntelligenceCompetitorsScreen> createState() => _IntelligenceCompetitorsScreenState();
}

class _IntelligenceCompetitorsScreenState extends ConsumerState<IntelligenceCompetitorsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _categories = [];
  Map<String, Map<String, Map<String, dynamic>>> _latest = {};
  final _customerSearchCtrl = TextEditingController();

  String? _selectedSalespersonId;
  String? _selectedRouteId;
  List<Map<String, dynamic>> _salespeople = [];
  List<Map<String, dynamic>> _routes = [];
  final Map<String, String> _userNames = {};
  final Map<String, Set<String>> _customerToRoutes = {};
  final Map<String, Set<String>> _salespersonToRoutes = {};
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
    _loadFilters();
  }

  @override
  void dispose() {
    _customerSearchCtrl.dispose();
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

      print('LF[comp] counts: salespeople=${salespeopleRows.length} allUsers=${allUsers.length} routes=${routesRows.length} routeIds=${routeIds.length} sp2r=${spToRoutes.length} c2r=${custToRoutes.length}');
      if (!mounted) return;
      setState(() {
        _userNames..clear()..addAll(names);
        _salespeople = List<Map<String, dynamic>>.from(salespeopleRows);
        _routes = List<Map<String, dynamic>>.from(routesRows);
        _customerToRoutes..clear()..addAll(custToRoutes);
        _salespersonToRoutes..clear()..addAll(spToRoutes);
      });
    } catch (e, st) {
      print('competitor _loadFilters error: $e\n$st');
    }
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final spottingRows = await client
          .from('competitor_spotting')
          .select()
          .eq('org_id', orgId)
          .order('surveyed_at', ascending: false);
      final spottings = List<Map<String, dynamic>>.from(spottingRows);

      final latest = <String, Map<String, Map<String, dynamic>>>{};
      for (final s in spottings) {
        final cid = s['customer_id'] as String;
        final catId = s['category_id'] as String;
        latest.putIfAbsent(cid, () => {});
        if (!latest[cid]!.containsKey(catId)) {
          latest[cid]![catId] = s;
        }
      }

      List<Map<String, dynamic>> customers = [];
      if (latest.keys.isNotEmpty) {
        final rows = await client
            .from('customers')
            .select('id, shop_name, code')
            .eq('org_id', orgId)
            .eq('is_active', true)
            .inFilter('id', latest.keys.toList());
        customers = List<Map<String, dynamic>>.from(rows);
        customers.sort((a, b) => (a['shop_name'] as String).compareTo(b['shop_name'] as String));
      }

      final catRows = await client
          .from('competitor_categories')
          .select('id, name, position')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('position');

      setState(() {
        _customers = customers;
        _categories = List<Map<String, dynamic>>.from(catRows);
        _latest = latest;
        _loading = false;
      });
    } catch (e) {
      print('Competitor load failed: $e');
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filteredCustomers {
    Iterable<Map<String, dynamic>> result = _customers;
    final q = _customerSearchCtrl.text.toLowerCase();
    if (q.isNotEmpty) {
      result = result.where((c) =>
        matchesQuery('${c['shop_name'] ?? ''} ${c['code'] ?? ''}', q)
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

  void _showCellDetail(Map<String, dynamic> customer, Map<String, dynamic> category, Map<String, dynamic> spotting) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${category['name']} @ ${customer['shop_name']}'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('Brand', spotting['brand_name'] as String? ?? ''),
              _kv('Price', spotting['price'] == null ? '—' : 'PKR ${spotting['price']}'),
              _kv('Specs', (spotting['specs'] as String?)?.isEmpty ?? true ? '—' : spotting['specs'] as String),
              _kv('Surveyed', _fmt(spotting['surveyed_at'] as String?)),
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
      SizedBox(width: 80, child: Text(k, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
      Expanded(child: Text(v, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
    ]),
  );

  String _fmt(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) { return iso; }
  }


  void _showChart() {
    final orgId = ref.read(currentUserProvider)?.orgId ?? '';
    final isMobile = context.isMobile;
    final pad = isMobile ? 12.0 : 24.0;
    showDialog(
      context: context,
      builder: (_) => Dialog(
        insetPadding: EdgeInsets.all(isMobile ? 8 : 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 1400,
            maxHeight: MediaQuery.of(context).size.height * 0.9,
          ),
          child: Stack(children: [
            Padding(
              padding: EdgeInsets.all(pad),
              child: SizedBox(
                height: isMobile
                    ? MediaQuery.of(context).size.height * 0.75
                    : 520,
                child: _CompetitorTrendChart(
                  orgId: orgId,
                  customerIds: _filteredCustomers.map((c) => c['id'] as String).toList(),
                ),
              ),
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
      final toExport = _selectedIds.isEmpty
          ? _filteredCustomers
          : _filteredCustomers.where((c) => _selectedIds.contains(c['id'])).toList();
      if (toExport.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No shops to export. Adjust filter or selection.')),
          );
        }
        return;
      }
      final bytes = await IntelligencePdfService.generateCompetitorSpottingPdf(
        orgName: orgName,
        customers: toExport,
        categories: _categories,
        latest: _latest,
      );
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: 'competitor_spotting_${DateTime.now().toIso8601String().split('T').first}.pdf',
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
    final isMobile = context.isMobile;
    final allSelected = _filteredCustomers.isNotEmpty &&
        _filteredCustomers.every((c) => _selectedIds.contains(c['id']));
    final spDropdown = SearchableDropdown(
      label: 'Salesperson',
      value: _selectedSalespersonId,
      allLabel: 'All salespeople',
      options: [
        for (final s in _salespeople)
          MapEntry(s['id'] as String?, s['name'] as String),
      ],
      onChanged: (v) => setState(() => _selectedSalespersonId = v),
    );
    final routeDropdown = SearchableDropdown(
      label: 'Route',
      value: _selectedRouteId,
      allLabel: 'All routes',
      options: [
        for (final r in _routes)
          MapEntry(r['id'] as String?, r['name'] as String),
      ],
      onChanged: (v) => setState(() => _selectedRouteId = v),
    );
    final searchField = TextField(
      controller: _customerSearchCtrl,
      decoration: const InputDecoration(hintText: 'Filter shops...', prefixIcon: Icon(Icons.search), isDense: true),
      onChanged: (_) => setState(() {}),
    );
    final chartBtn = TextButton.icon(
      onPressed: _showChart,
      icon: const Icon(Icons.show_chart, size: 18),
      label: Text(isMobile ? 'Chart' : 'Visual chart'),
    );
    final selectBtn = TextButton.icon(
      onPressed: () => setState(() {
        if (allSelected) {
          _selectedIds.clear();
        } else {
          _selectedIds.addAll(_filteredCustomers.map((c) => c['id'] as String));
        }
      }),
      icon: const Icon(Icons.checklist, size: 18),
      label: Text(allSelected ? (isMobile ? 'Clear' : 'Clear selection') : 'Select all'),
    );
    final pdfBtn = OutlinedButton.icon(
      onPressed: _exportPdf,
      icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
      label: Text(isMobile
          ? (_selectedIds.isEmpty ? 'PDF (${_filteredCustomers.length})' : 'PDF (${_selectedIds.length})')
          : (_selectedIds.isEmpty
              ? 'Export PDF (all ${_filteredCustomers.length})'
              : 'Export PDF (${_selectedIds.length} selected)')),
    );
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(isMobile ? 12 : 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Competitor Spotting', style: TextStyle(fontSize: isMobile ? 22 : 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
          '${_filteredCustomers.length} shops × ${_categories.length} categories tracked. Each cell shows the latest known competitor brand. Click for price + specs.',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 16),
        if (isMobile) ...[
          spDropdown,
          const SizedBox(height: 10),
          routeDropdown,
          const SizedBox(height: 10),
          searchField,
          const SizedBox(height: 6),
          Wrap(spacing: 4, runSpacing: 0, children: [chartBtn, selectBtn, pdfBtn]),
        ] else ...[
          Row(children: [
            Expanded(child: spDropdown),
            const SizedBox(width: 12),
            Expanded(child: routeDropdown),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: searchField),
            const SizedBox(width: 12),
            chartBtn,
            const SizedBox(width: 8),
            selectBtn,
            const SizedBox(width: 8),
            pdfBtn,
          ]),
        ],
        const SizedBox(height: 16),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_customers.isEmpty)
          const Expanded(child: Center(child: Text('No competitor data yet. Surveyor will populate via mobile.')))
        else if (_categories.isEmpty)
          const Expanded(child: Center(child: Text('No competitor categories configured.')))
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
                    columnSpacing: isMobile ? 4 : 8,
                    horizontalMargin: isMobile ? 8 : 24,
                    headingRowHeight: 60,
                    dataRowMinHeight: 48,
                    dataRowMaxHeight: 48,
                    columns: [
                      DataColumn(label: SizedBox(width: 40, child: Checkbox(
                        value: _filteredCustomers.isNotEmpty &&
                            _filteredCustomers.every((c) => _selectedIds.contains(c['id'])),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selectedIds.addAll(_filteredCustomers.map((c) => c['id'] as String));
                          } else {
                            _selectedIds.clear();
                          }
                        }),
                      ))),
                      DataColumn(label: SizedBox(width: isMobile ? 130 : 200, child: const Text('Shop', style: TextStyle(fontWeight: FontWeight.w700)))),
                      ..._categories.map((cat) => DataColumn(
                        label: SizedBox(
                          width: isMobile ? 110 : 140,
                          child: Text(cat['name'] as String,
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
                        DataCell(SizedBox(width: 40, child: Checkbox(
                          value: _selectedIds.contains(cid),
                          onChanged: (v) => setState(() {
                            if (v == true) _selectedIds.add(cid);
                            else _selectedIds.remove(cid);
                          }),
                        ))),
                        DataCell(SizedBox(
                          width: isMobile ? 130 : 200,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(c['shop_name'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                              Text(c['code'] as String? ?? '', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                            ],
                          ),
                        )),
                        ..._categories.map((cat) {
                          final catId = cat['id'] as String;
                          final spotting = _latest[cid]?[catId];
                          if (spotting == null) {
                            return DataCell(SizedBox(width: isMobile ? 110 : 140, child: const Center(child: Text('—', style: TextStyle(color: AppTheme.textSecondary)))));
                          }
                          return DataCell(
                            InkWell(
                              onTap: () => _showCellDetail(c, cat, spotting),
                              child: SizedBox(
                                width: isMobile ? 110 : 140,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppTheme.primary.withOpacity(0.08),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Center(
                                    child: Text(
                                      spotting['brand_name'] as String? ?? '',
                                      style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primary, fontSize: 12),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                    ),
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

class _CompetitorTrendChart extends StatefulWidget {
  final String orgId;
  final List<String> customerIds;
  const _CompetitorTrendChart({required this.orgId, required this.customerIds});
  @override
  State<_CompetitorTrendChart> createState() => _CompetitorTrendChartState();
}

class _CompetitorTrendChartState extends State<_CompetitorTrendChart> {
  bool _loading = true;
  List<_CategoryItem> _categories = [];
  String? _selectedCategoryId;
  String _selectedWindow = '6m';

  List<DateTime> _binEnds = [];
  List<_BrandSeries> _brandSeries = [];
  int _otherBrandCount = 0;
  double _maxY = 1;

  static const List<Color> _palette = [
    Color(0xFFF59E0B),
    Color(0xFF3B82F6),
    Color(0xFF10B981),
    Color(0xFFEF4444),
    Color(0xFF8B5CF6),
    Color(0xFFEC4899),
    Color(0xFF06B6D4),
  ];
  static const Color _otherColor = Color(0xFF94A3B8);

  static const Map<String, _Window> _windows = {
    '7d': _Window(days: 7, binKind: _BinKind.daily),
    '30d': _Window(days: 30, binKind: _BinKind.weekly),
    '6m': _Window(days: 180, binKind: _BinKind.monthly),
  };

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    try {
      final client = Supabase.instance.client;
      final cats = await client
          .from('competitor_categories')
          .select('id, name')
          .eq('org_id', widget.orgId);
      final spottings = await client
          .from('competitor_spotting')
          .select('category_id')
          .eq('org_id', widget.orgId);
      final counts = <String, int>{};
      for (final r in spottings) {
        final cid = r['category_id'] as String?;
        if (cid != null) counts[cid] = (counts[cid] ?? 0) + 1;
      }
      final list = <_CategoryItem>[];
      for (final c in cats) {
        list.add(_CategoryItem(
          id: c['id'] as String,
          name: (c['name'] as String?) ?? '-',
          count: counts[c['id'] as String] ?? 0,
        ));
      }
      list.sort((a, b) => b.count.compareTo(a.count));
      if (!mounted) return;
      setState(() {
        _categories = list;
        _selectedCategoryId = list.isNotEmpty ? list.first.id : null;
      });
      if (_selectedCategoryId != null) {
        await _loadChart();
      } else {
        if (!mounted) return;
        setState(() => _loading = false);
      }
    } catch (e) {
      print('competitor chart loadCategories error: $e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _loadChart() async {
    if (_selectedCategoryId == null) return;
    setState(() => _loading = true);
    try {
      final window = _windows[_selectedWindow]!;
      final now = DateTime.now();
      final windowStart = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: window.days - 1));
      final binEnds = _computeBinEnds(now, window);

      if (widget.customerIds.isEmpty) {
        if (!mounted) return;
        setState(() {
          _binEnds = binEnds;
          _brandSeries = [];
          _otherBrandCount = 0;
          _loading = false;
        });
        return;
      }

      final client = Supabase.instance.client;
      final all = await client
          .from('competitor_spotting')
          .select('customer_id, brand_name, surveyed_at')
          .eq('org_id', widget.orgId)
          .eq('category_id', _selectedCategoryId!)
          .gte('surveyed_at', windowStart.toUtc().toIso8601String());

      final customerSet = widget.customerIds.toSet();
      final byCustomer = <String, List<Map<String, dynamic>>>{};
      for (final r in all) {
        final cid = r['customer_id'] as String?;
        if (cid == null || !customerSet.contains(cid)) continue;
        byCustomer.putIfAbsent(cid, () => []).add(r);
      }
      for (final lst in byCustomer.values) {
        lst.sort((a, b) =>
            (b['surveyed_at'] as String).compareTo(a['surveyed_at'] as String));
      }

      final perBin = <Map<String, int>>[];
      for (final binEnd in binEnds) {
        final brandCount = <String, int>{};
        byCustomer.forEach((cid, lst) {
          for (final sp in lst) {
            final ts = DateTime.parse(sp['surveyed_at'] as String).toLocal();
            if (!ts.isAfter(binEnd)) {
              final brand = (sp['brand_name'] as String?) ?? '-';
              brandCount[brand] = (brandCount[brand] ?? 0) + 1;
              break;
            }
          }
        });
        perBin.add(brandCount);
      }

      final totals = <String, int>{};
      for (final bin in perBin) {
        bin.forEach((b, c) => totals[b] = (totals[b] ?? 0) + c);
      }
      final sortedBrands = totals.keys.toList()
        ..sort((a, b) => totals[b]!.compareTo(totals[a]!));
      final topBrands = sortedBrands.take(7).toList();
      final otherBrands = sortedBrands.skip(7).toList();

      final series = <_BrandSeries>[];
      for (var i = 0; i < topBrands.length; i++) {
        final brand = topBrands[i];
        final spots = <FlSpot>[];
        for (var j = 0; j < perBin.length; j++) {
          spots.add(FlSpot(j.toDouble(), (perBin[j][brand] ?? 0).toDouble()));
        }
        series.add(_BrandSeries(
          name: brand,
          color: _palette[i % _palette.length],
          spots: spots,
        ));
      }
      if (otherBrands.isNotEmpty) {
        final spots = <FlSpot>[];
        for (var j = 0; j < perBin.length; j++) {
          var n = 0;
          for (final b in otherBrands) {
            n += perBin[j][b] ?? 0;
          }
          spots.add(FlSpot(j.toDouble(), n.toDouble()));
        }
        series.add(_BrandSeries(name: 'Other', color: _otherColor, spots: spots));
      }

      double maxY = 1;
      for (final s in series) {
        for (final pt in s.spots) {
          if (pt.y > maxY) maxY = pt.y;
        }
      }

      if (!mounted) return;
      setState(() {
        _binEnds = binEnds;
        _brandSeries = series;
        _otherBrandCount = otherBrands.length;
        _maxY = (maxY * 1.25).ceilToDouble();
        if (_maxY < 1) _maxY = 1;
        _loading = false;
      });
      print('competitor chart loaded: bins=${binEnds.length} brands=${series.length} other=${otherBrands.length}');
    } catch (e) {
      print('competitor chart loadChart error: $e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  List<DateTime> _computeBinEnds(DateTime now, _Window window) {
    final today = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final ends = <DateTime>[];
    switch (window.binKind) {
      case _BinKind.daily:
        for (var i = window.days - 1; i >= 0; i--) {
          ends.add(today.subtract(Duration(days: i)));
        }
        break;
      case _BinKind.weekly:
        final nBins = (window.days / 7).ceil();
        for (var i = nBins - 1; i >= 0; i--) {
          ends.add(today.subtract(Duration(days: i * 7)));
        }
        break;
      case _BinKind.monthly:
        for (var i = 5; i >= 0; i--) {
          final m = DateTime(now.year, now.month - i, 1);
          final monthEnd = DateTime(m.year, m.month + 1, 0, 23, 59, 59);
          ends.add(monthEnd.isAfter(today) ? today : monthEnd);
        }
        break;
    }
    return ends;
  }

  @override
  Widget build(BuildContext context) {
    final hasData = _brandSeries.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Competitor Brand Trend',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              Row(mainAxisSize: MainAxisSize.min, children: [
                _windowSegment('7d'),
                _windowSegment('30d'),
                _windowSegment('6m'),
              ]),
            ],
          ),
          const SizedBox(height: 10),
          if (_categories.isNotEmpty)
            SizedBox(
              width: context.isMobile ? double.infinity : 320,
              child: SearchableDropdown(
                label: 'Category',
                value: _selectedCategoryId,
                options: [
                  for (final c in _categories)
                    MapEntry(c.id as String?, '${c.name}  (${c.count})'),
                ],
                onChanged: (v) {
                  if (v == null || v == _selectedCategoryId) return;
                  setState(() => _selectedCategoryId = v);
                  _loadChart();
                },
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : !hasData
                    ? _emptyState()
                    : _chart(),
          ),
          if (!_loading && hasData) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                for (final s in _brandSeries)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    _LegendDot(color: s.color),
                    const SizedBox(width: 4),
                    Text(s.name,
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textSecondary)),
                  ]),
              ],
            ),
            if (_otherBrandCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '+$_otherBrandCount more brands grouped as "Other"',
                  style: const TextStyle(
                      fontSize: 10, color: AppTheme.textSecondary),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _windowSegment(String key) {
    final selected = _selectedWindow == key;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: InkWell(
        onTap: () {
          if (selected) return;
          setState(() => _selectedWindow = key);
          _loadChart();
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.primary.withOpacity(0.1)
                : Colors.transparent,
            border: Border.all(
              color: selected ? AppTheme.primary : AppTheme.border,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            key,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? AppTheme.primary : AppTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    final catName = _categories
        .firstWhere(
          (c) => c.id == _selectedCategoryId,
          orElse: () => const _CategoryItem(id: '', name: 'this category', count: 0),
        )
        .name;
    return Center(
      child: Text(
        'No spottings yet for $catName in this window',
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      ),
    );
  }

  Widget _chart() {
    final n = _binEnds.length;
    if (n == 0) return const SizedBox.shrink();
    final yInterval = _maxY >= 5 ? (_maxY / 5).ceilToDouble() : 1.0;
    return LineChart(LineChartData(
      minX: 0,
      maxX: (n - 1).toDouble(),
      minY: 0,
      maxY: _maxY,
      gridData: const FlGridData(show: true, drawVerticalLine: false),
      titlesData: FlTitlesData(
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 28,
            interval: yInterval,
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 24,
            interval: 1,
            getTitlesWidget: (v, _) {
              final i = v.toInt();
              if (i < 0 || i >= _binEnds.length) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _formatBinLabel(_binEnds[i]),
                  style: const TextStyle(
                      fontSize: 10, color: AppTheme.textSecondary),
                ),
              );
            },
          ),
        ),
      ),
      borderData: FlBorderData(show: false),
      lineBarsData: [
        for (final s in _brandSeries)
          LineChartBarData(
            spots: s.spots,
            color: s.color,
            barWidth: 2.5,
            isCurved: false,
            dotData: FlDotData(
              show: true,
              checkToShowDot: (spot, _) => spot.y > 0,
            ),
          ),
      ],
    ));
  }

  String _formatBinLabel(DateTime dt) {
    final binKind = _windows[_selectedWindow]!.binKind;
    switch (binKind) {
      case _BinKind.daily:
      case _BinKind.weekly:
        return '${dt.day}/${dt.month}';
      case _BinKind.monthly:
        const months = [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ];
        return months[dt.month - 1];
    }
  }
}

enum _BinKind { daily, weekly, monthly }

class _Window {
  final int days;
  final _BinKind binKind;
  const _Window({required this.days, required this.binKind});
}

class _CategoryItem {
  final String id;
  final String name;
  final int count;
  const _CategoryItem({required this.id, required this.name, required this.count});
}

class _BrandSeries {
  final String name;
  final Color color;
  final List<FlSpot> spots;
  const _BrandSeries({required this.name, required this.color, required this.spots});
}

class _LegendDot extends StatelessWidget {
  final Color color;
  const _LegendDot({required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

