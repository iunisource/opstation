// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/permissions/access_control.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Production Report (Manufacturing ▸ Production Report,
/// permission /manufacturing/production-report).
///
/// Every production run recorded on a date or across a date range — both
/// Production Vouchers and Job Card batches (runs) — with product totals,
/// per-run detail and Print / PDF. Costs show only to users who may view
/// production costing (same rule as the Production Voucher / Job Card).
class ErpProductionReportScreen extends ConsumerStatefulWidget {
  const ErpProductionReportScreen({super.key});
  @override
  ConsumerState<ErpProductionReportScreen> createState() => _State();
}

class _Run {
  final String id;
  final String source; // 'PV' | 'Job'
  final String doc;
  final DateTime? date;
  final String? branchId;
  final String? productId;
  final double produced;
  final double rejected;
  final String status;
  final double? cost;
  final double overhead; // absorbed labour & overhead
  final String notes;
  _Run(this.id, this.source, this.doc, this.date, this.branchId, this.productId, this.produced, this.rejected,
      this.status, this.cost, this.overhead, this.notes);
}

class _State extends ConsumerState<ErpProductionReportScreen> {
  DateTime _from = DateTime.now();
  DateTime _to = DateTime.now();
  String _preset = 'today';
  String _source = 'all'; // all | pv | job
  bool _postedOnly = true;
  String _branch = 'all';
  final _search = TextEditingController();
  String _view = 'runs'; // runs | products

  bool _loading = false;
  bool _loaded = false;
  String? _error;
  List<_Run> _runs = [];
  final Map<String, String> _prodName = {}, _prodSku = {}, _branchName = {};

  final _q = NumberFormat('#,##0.##');
  final _rs = NumberFormat('#,##0');
  final _d = DateFormat('d MMM yyyy');

  bool get _canCost {
    final r = ref.read(currentUserProvider)?.role;
    if (r == WebUserRole.admin || r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin) return true;
    return ref.read(accessSyncProvider)?.canViewReport('production_cost') ?? false;
  }

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setPreset(String p) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      _preset = p;
      switch (p) {
        case 'today':
          _from = today; _to = today;
          break;
        case 'yesterday':
          _from = today.subtract(const Duration(days: 1)); _to = _from;
          break;
        case 'week':
          _from = today.subtract(Duration(days: today.weekday - 1)); _to = today;
          break;
        case 'month':
          _from = DateTime(today.year, today.month, 1); _to = today;
          break;
        case 'last_month':
          _from = DateTime(today.year, today.month - 1, 1);
          _to = DateTime(today.year, today.month, 0);
          break;
      }
    });
    _load();
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (r == null) return;
    setState(() {
      _from = r.start;
      _to = r.end;
      _preset = 'custom';
    });
    _load();
  }

  static double _n(dynamic v) => (v as num?)?.toDouble() ?? 0;
  static double? _costOf(Map r, double qty) {
    final t = r['total_cost'] ?? r['production_cost'] ?? r['cost_total'];
    if (t is num && t != 0) return t.toDouble();
    final u = r['unit_cost'] ?? r['cost_per_unit'];
    if (u is num && u != 0) return u.toDouble() * qty;
    return null;
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final f = DateFormat('yyyy-MM-dd').format(_from);
    final t = DateFormat('yyyy-MM-dd').format(_to);
    try {
      final c = Supabase.instance.client;
      final runs = <_Run>[];

      // Production Vouchers
      final pv = await c.from('production_vouchers').select()
          .eq('org_id', orgId).gte('voucher_date', f).lte('voucher_date', t).order('voucher_date');
      for (final r in pv as List) {
        final st = '${r['status'] ?? ''}';
        if (st == 'void' || st == 'voided' || r['is_voided'] == true) continue;
        final q = _n(r['output_qty']);
        runs.add(_Run('${r['id']}', 'PV', '${r['voucher_number'] ?? ''}', DateTime.tryParse('${r['voucher_date']}'),
            r['branch_id'] as String?, r['product_id'] as String?, q, 0, st, _costOf(r, q),
            _n(r['total_overhead_cost']), '${r['notes'] ?? ''}'));
      }

      // Job Card batches (runs)
      final jr = await c.from('job_card_runs').select()
          .eq('org_id', orgId).gte('run_date', f).lte('run_date', t).order('run_date');
      final jobIds = {for (final r in jr as List) '${r['job_card_id']}'}.toList();
      final jobs = <String, Map<String, dynamic>>{};
      for (var i = 0; i < jobIds.length; i += 150) {
        final part = jobIds.sublist(i, (i + 150).clamp(0, jobIds.length));
        final rows = await c.from('job_cards').select('id, job_number, product_id, branch_id').inFilter('id', part);
        for (final j in rows as List) {
          jobs['${j['id']}'] = Map<String, dynamic>.from(j as Map);
        }
      }
      for (final r in jr) {
        final st = '${r['status'] ?? ''}';
        if (st == 'void' || st == 'voided') continue;
        final j = jobs['${r['job_card_id']}'] ?? const <String, dynamic>{};
        final q = _n(r['produced_qty']);
        runs.add(_Run('${r['id']}', 'Job', '${j['job_number'] ?? 'Job'}-R${r['run_no'] ?? ''}', DateTime.tryParse('${r['run_date']}'),
            (r['branch_id'] ?? j['branch_id']) as String?, j['product_id'] as String?, q, _n(r['rejected_qty']), st,
            _costOf(r, q), _n(r['overhead_amount']), '${r['notes'] ?? ''}'));
      }

      // names
      final pids = {for (final r in runs) if (r.productId != null) r.productId!}.toList();
      for (var i = 0; i < pids.length; i += 150) {
        final rows = await c.from('products').select('id, name, sku').inFilter('id', pids.sublist(i, (i + 150).clamp(0, pids.length)));
        for (final p in rows as List) {
          _prodName['${p['id']}'] = '${p['name'] ?? ''}';
          _prodSku['${p['id']}'] = '${p['sku'] ?? ''}';
        }
      }
      if (_branchName.isEmpty) {
        final b = await c.from('branches').select('id, name').eq('org_id', orgId);
        for (final x in b as List) {
          _branchName['${x['id']}'] = '${x['name'] ?? ''}';
        }
      }
      runs.sort((a, b) {
        final c1 = (a.date ?? DateTime(2000)).compareTo(b.date ?? DateTime(2000));
        return c1 != 0 ? c1 : a.doc.compareTo(b.doc);
      });
      if (mounted) {
        setState(() {
          _runs = runs;
          _loading = false;
          _loaded = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString().split('\n').first;
        });
      }
    }
  }

  List<_Run> get _visible {
    final q = _search.text.trim().toLowerCase();
    return _runs.where((r) {
      if (_source == 'pv' && r.source != 'PV') return false;
      if (_source == 'job' && r.source != 'Job') return false;
      if (_postedOnly && r.status != 'posted') return false;
      if (_branch != 'all' && r.branchId != _branch) return false;
      if (q.isEmpty) return true;
      final hay = '${r.doc} ${_prodName[r.productId] ?? ''} ${_prodSku[r.productId] ?? ''} ${r.notes}'.toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  /// product -> {produced, rejected, runs, cost}
  List<Map<String, dynamic>> _byProduct(List<_Run> rows) {
    final m = <String, Map<String, dynamic>>{};
    for (final r in rows) {
      final k = r.productId ?? '—';
      final e = m.putIfAbsent(k, () => {'pid': k, 'produced': 0.0, 'rejected': 0.0, 'runs': 0, 'cost': 0.0, 'oh': 0.0, 'hasCost': false});
      e['produced'] = (e['produced'] as double) + r.produced;
      e['oh'] = (e['oh'] as double) + r.overhead;
      e['rejected'] = (e['rejected'] as double) + r.rejected;
      e['runs'] = (e['runs'] as int) + 1;
      if (r.cost != null) {
        e['cost'] = (e['cost'] as double) + r.cost!;
        e['hasCost'] = true;
      }
    }
    final list = m.values.toList()..sort((a, b) => (b['produced'] as double).compareTo(a['produced'] as double));
    return list;
  }

  String get _rangeLabel => _from == _to || DateFormat('yyyyMMdd').format(_from) == DateFormat('yyyyMMdd').format(_to)
      ? _d.format(_from)
      : '${_d.format(_from)} – ${_d.format(_to)}';

  // ── UI ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 700;
    final rows = _visible;
    final showCost = _canCost && rows.any((r) => r.cost != null);
    final produced = rows.fold<double>(0, (s, r) => s + r.produced);
    final rejected = rows.fold<double>(0, (s, r) => s + r.rejected);
    final cost = rows.fold<double>(0, (s, r) => s + (r.cost ?? 0));
    final branches = {for (final r in _runs) if (r.branchId != null) r.branchId!: _branchName[r.branchId] ?? r.branchId!};

    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(narrow ? 12 : 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Production Report', style: TextStyle(fontSize: narrow ? 22 : 28, fontWeight: FontWeight.w800)),
          Text(_rangeLabel, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
          ElevatedButton.icon(
            onPressed: _loading || rows.isEmpty ? null : () => _print(rows, showCost),
            icon: const Icon(Icons.print_outlined, size: 16),
            label: const Text('Print / PDF'),
          ),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final p in const [
            ('today', 'Today'), ('yesterday', 'Yesterday'), ('week', 'This week'),
            ('month', 'This month'), ('last_month', 'Last month'),
          ])
            ChoiceChip(label: Text(p.$2), selected: _preset == p.$1, onSelected: (_) => _setPreset(p.$1)),
          ActionChip(
            avatar: const Icon(Icons.date_range, size: 16),
            label: Text(_preset == 'custom' ? _rangeLabel : 'Pick date / range'),
            onPressed: _pickRange,
            backgroundColor: _preset == 'custom' ? AppTheme.primary.withOpacity(0.12) : null,
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: narrow ? double.infinity : 260,
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 18), hintText: 'Search product, SKU or doc no.', isDense: true),
            ),
          ),
          SizedBox(
            width: 190,
            child: DropdownButtonFormField<String>(
              value: _source,
              isDense: true,
              decoration: const InputDecoration(labelText: 'Source', isDense: true),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All runs')),
                DropdownMenuItem(value: 'pv', child: Text('Production Vouchers')),
                DropdownMenuItem(value: 'job', child: Text('Job Card batches')),
              ],
              onChanged: (v) => setState(() => _source = v ?? 'all'),
            ),
          ),
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<String>(
              value: branches.containsKey(_branch) ? _branch : 'all',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Branch', isDense: true),
              items: [
                const DropdownMenuItem(value: 'all', child: Text('All branches')),
                for (final e in branches.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _branch = v ?? 'all'),
            ),
          ),
          FilterChip(
            label: const Text('Posted only'),
            selected: _postedOnly,
            onSelected: (v) => setState(() => _postedOnly = v),
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'runs', label: Text('Runs'), icon: Icon(Icons.list, size: 16)),
              ButtonSegment(value: 'products', label: Text('By product'), icon: Icon(Icons.inventory_2_outlined, size: 16)),
            ],
            selected: {_view},
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
        ]),
        const SizedBox(height: 12),
        if (_loaded && !_loading)
          Wrap(spacing: 10, runSpacing: 10, children: [
            _kpi('Runs', '${rows.length}'),
            _kpi('Products', '${{for (final r in rows) r.productId}.length}'),
            _kpi('Produced', _q.format(produced)),
            if (rejected > 0) _kpi('Rejected', _q.format(rejected), color: Colors.red),
            if (showCost) _kpi('Absorbed overheads', 'Rs ${_rs.format(rows.fold<double>(0, (s, r) => s + r.overhead))}', color: Colors.teal.shade700),
            if (showCost) _kpi('Production cost (total)', 'Rs ${_rs.format(cost)}'),
          ]),
        const SizedBox(height: 12),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text('Could not load: $_error', style: const TextStyle(color: Colors.red)))
                  : rows.isEmpty
                      ? Center(
                          child: Text(_loaded ? 'No production recorded for $_rangeLabel' : '',
                              style: const TextStyle(color: AppTheme.textSecondary)))
                      : narrow
                          ? (_view == 'runs' ? _runsCards(rows, showCost) : _productCards(rows, showCost))
                          : _view == 'runs'
                              ? _runsTable(rows, showCost)
                              : _productTable(rows, showCost),
        ),
      ]),
    );
  }

  Widget _kpi(String label, String value, {Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFE5E7EB))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
        ]),
      );

  Widget _cell(String t, double w, {bool right = false, bool bold = false, Color? color}) => SizedBox(
        width: w,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Text(t,
              textAlign: right ? TextAlign.right : TextAlign.left,
              style: TextStyle(fontSize: 12.5, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: color)),
        ),
      );

  Widget _frame(double width, List<Widget> header, List<Widget> body, List<Widget> footer) => Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFE5E7EB))),
        child: Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Column(children: [
                Container(color: const Color(0xFFF5F5F5), child: Row(children: header)),
                Expanded(child: ListView(children: body)),
                Container(color: const Color(0xFFF5F5F5), child: Row(children: footer)),
              ]),
            ),
          ),
        ),
      );

  Widget _runsTable(List<_Run> rows, bool showCost) {
    final cols = <(String, double, bool)>[
      ('Date', 105, false), ('Doc', 150, false), ('Source', 80, false), ('Product', 300, false),
      ('Branch', 140, false), ('Produced', 95, true), ('Rejected', 85, true), ('Status', 80, false),
      if (showCost) ('Abs. overheads', 115, true),
      if (showCost) ('Total cost', 110, true),
    ];
    final w = cols.fold<double>(0, (s, c) => s + c.$2);
    return _frame(
      w,
      [for (final c in cols) _cell(c.$1, c.$2, right: c.$3, bold: true)],
      [
        for (final r in rows)
          Container(
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE)))),
            child: Row(children: [
              _cell(r.date == null ? '' : _d.format(r.date!), cols[0].$2),
              _docCell(r, cols[1].$2),
              _cell(r.source == 'PV' ? 'Voucher' : 'Job batch', cols[2].$2),
              _cell('${_prodSku[r.productId]?.isNotEmpty == true ? '${_prodSku[r.productId]} · ' : ''}${_prodName[r.productId] ?? '—'}', cols[3].$2),
              _cell(_branchName[r.branchId] ?? '', cols[4].$2),
              _cell(_q.format(r.produced), cols[5].$2, right: true, bold: true),
              _cell(r.rejected > 0 ? _q.format(r.rejected) : '', cols[6].$2, right: true, color: Colors.red),
              _cell(r.status, cols[7].$2, color: r.status == 'posted' ? Colors.green.shade700 : Colors.orange.shade800),
              if (showCost) _cell(r.overhead == 0 ? '' : _rs.format(r.overhead), cols[8].$2, right: true, color: Colors.teal.shade700),
              if (showCost) _cell(r.cost == null ? '' : _rs.format(r.cost), cols[9].$2, right: true),
            ]),
          ),
      ],
      [
        _cell('Total', cols[0].$2, bold: true),
        _cell('${rows.length} runs', cols[1].$2, bold: true),
        for (var i = 2; i < 5; i++) _cell('', cols[i].$2),
        _cell(_q.format(rows.fold<double>(0, (s, r) => s + r.produced)), cols[5].$2, right: true, bold: true),
        _cell(_q.format(rows.fold<double>(0, (s, r) => s + r.rejected)), cols[6].$2, right: true, bold: true),
        _cell('', cols[7].$2),
        if (showCost) _cell(_rs.format(rows.fold<double>(0, (s, r) => s + r.overhead)), cols[8].$2, right: true, bold: true),
        if (showCost) _cell(_rs.format(rows.fold<double>(0, (s, r) => s + (r.cost ?? 0))), cols[9].$2, right: true, bold: true),
      ],
    );
  }

  Widget _productTable(List<_Run> rows, bool showCost) {
    final data = _byProduct(rows);
    final cols = <(String, double, bool)>[
      ('SKU', 100, false), ('Product', 340, false), ('Runs', 70, true), ('Produced', 110, true), ('Rejected', 100, true),
      if (showCost) ('Abs. overheads', 120, true),
      if (showCost) ('Total cost', 120, true),
      if (showCost) ('Avg / unit', 100, true),
    ];
    final w = cols.fold<double>(0, (s, c) => s + c.$2);
    return _frame(
      w,
      [for (final c in cols) _cell(c.$1, c.$2, right: c.$3, bold: true)],
      [
        for (final e in data)
          Container(
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE)))),
            child: Row(children: [
              _cell(_prodSku[e['pid']] ?? '', cols[0].$2),
              _cell(_prodName[e['pid']] ?? '—', cols[1].$2, bold: true),
              _cell('${e['runs']}', cols[2].$2, right: true),
              _cell(_q.format(e['produced']), cols[3].$2, right: true, bold: true),
              _cell((e['rejected'] as double) > 0 ? _q.format(e['rejected']) : '', cols[4].$2, right: true, color: Colors.red),
              if (showCost) _cell((e['oh'] as double) == 0 ? '' : _rs.format(e['oh']), cols[5].$2, right: true, color: Colors.teal.shade700),
              if (showCost) _cell(e['hasCost'] == true ? _rs.format(e['cost']) : '', cols[6].$2, right: true),
              if (showCost)
                _cell(e['hasCost'] == true && (e['produced'] as double) > 0
                    ? NumberFormat('#,##0.00').format((e['cost'] as double) / (e['produced'] as double)) : '', cols[7].$2, right: true),
            ]),
          ),
      ],
      [
        _cell('Total', cols[0].$2, bold: true),
        _cell('${data.length} products', cols[1].$2, bold: true),
        _cell('${rows.length}', cols[2].$2, right: true, bold: true),
        _cell(_q.format(rows.fold<double>(0, (s, r) => s + r.produced)), cols[3].$2, right: true, bold: true),
        _cell(_q.format(rows.fold<double>(0, (s, r) => s + r.rejected)), cols[4].$2, right: true, bold: true),
        if (showCost) _cell(_rs.format(rows.fold<double>(0, (s, r) => s + r.overhead)), cols[5].$2, right: true, bold: true),
        if (showCost) _cell(_rs.format(rows.fold<double>(0, (s, r) => s + (r.cost ?? 0))), cols[6].$2, right: true, bold: true),
        if (showCost) _cell('', cols[7].$2),
      ],
    );
  }

  // ── clickable doc number + detail modal ───────────────────────────────
  Widget _docCell(_Run r, double w) => SizedBox(
        width: w,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: InkWell(
            onTap: () => _openRun(r),
            child: Text(r.doc,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700, color: AppTheme.primary,
                    decoration: TextDecoration.underline)),
          ),
        ),
      );

  Future<void> _openRun(_Run r) async {
    final c = Supabase.instance.client;
    final showCost = _canCost;
    Map<String, dynamic>? head;
    Map<String, dynamic>? job;
    List<Map<String, dynamic>> lines = [];
    List<Map<String, dynamic>> ohs = [];
    String? err;
    try {
      if (r.source == 'PV') {
        head = await c.from('production_vouchers').select().eq('id', r.id).maybeSingle();
        lines = List<Map<String, dynamic>>.from(
            await c.from('production_voucher_components').select().eq('voucher_id', r.id).order('line_order'));
        ohs = List<Map<String, dynamic>>.from(
            await c.from('production_voucher_overheads').select().eq('voucher_id', r.id).order('line_order'));
      } else {
        head = await c.from('job_card_runs').select().eq('id', r.id).maybeSingle();
        if (head != null) {
          job = await c.from('job_cards').select().eq('id', '${head['job_card_id']}').maybeSingle();
          lines = List<Map<String, dynamic>>.from(
              await c.from('job_card_materials').select().eq('job_card_id', '${head['job_card_id']}').order('line_order'));
        }
      }
      final pids = {for (final l in lines) if (l['product_id'] != null) '${l['product_id']}'}
          .where((p) => !_prodName.containsKey(p)).toList();
      if (pids.isNotEmpty) {
        final ps = await c.from('products').select('id, name, sku').inFilter('id', pids);
        for (final p in ps as List) {
          _prodName['${p['id']}'] = '${p['name'] ?? ''}';
          _prodSku['${p['id']}'] = '${p['sku'] ?? ''}';
        }
      }
    } catch (e) {
      err = e.toString().split('\n').first;
    }
    if (!mounted) return;
    final narrow = MediaQuery.of(context).size.width < 700;
    double n(dynamic v) => (v as num?)?.toDouble() ?? 0;
    Widget kv(String k, String v, {Color? color, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 130, child: Text(k, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(child: Text(v, style: TextStyle(fontSize: 13, color: color, fontWeight: bold ? FontWeight.w700 : FontWeight.w500))),
          ]),
        );
    final h = head ?? const <String, dynamic>{};
    final isPv = r.source == 'PV';
    final produced = r.produced;
    final total = r.cost ?? 0;
    await showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: EdgeInsets.all(narrow ? 10 : 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(isPv ? 'Production Voucher' : 'Job Card batch',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    Text(r.doc, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.primary)),
                  ]),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
              ]),
              const Divider(),
              if (err != null)
                Text('Could not load details: $err', style: const TextStyle(color: Colors.red))
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      kv('Date', r.date == null ? '' : _d.format(r.date!)),
                      kv('Product', '${_prodSku[r.productId]?.isNotEmpty == true ? '${_prodSku[r.productId]} · ' : ''}${_prodName[r.productId] ?? '—'}', bold: true),
                      kv('Branch', _branchName[r.branchId] ?? '—'),
                      if (!isPv && job != null) kv('Job card', '${job['job_number'] ?? ''} · planned ${_q.format(n(job['planned_qty']))}'),
                      kv('Produced', _q.format(produced), bold: true),
                      if (!isPv && n(h['accepted_qty']) > 0) kv('Accepted', _q.format(n(h['accepted_qty'])), color: Colors.green.shade700),
                      if (r.rejected > 0) kv('Rejected', _q.format(r.rejected), color: Colors.red),
                      kv('Status', r.status, color: r.status == 'posted' ? Colors.green.shade700 : Colors.orange.shade800),
                      if (showCost) ...[
                        const SizedBox(height: 6),
                        if (isPv) kv('Materials', 'Rs ${_rs.format(n(h['total_component_cost']))}'),
                        kv('Absorbed overheads', 'Rs ${_rs.format(r.overhead)}', color: Colors.teal.shade700),
                        kv('Total cost', 'Rs ${_rs.format(total)}', bold: true),
                        if (produced > 0 && total > 0) kv('Cost / unit', 'Rs ${NumberFormat('#,##0.00').format(total / produced)}'),
                      ],
                      if (r.notes.trim().isNotEmpty) kv('Notes', r.notes),
                      if (lines.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(isPv ? 'Components used' : 'Job card materials (for the whole job)',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                        const SizedBox(height: 6),
                        for (final l in lines)
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE)))),
                            child: Row(children: [
                              Expanded(
                                child: Text(
                                    '${_prodSku[l['product_id']]?.isNotEmpty == true ? '${_prodSku[l['product_id']]} · ' : ''}${_prodName[l['product_id']] ?? '—'}',
                                    style: const TextStyle(fontSize: 12.5)),
                              ),
                              Text(_q.format(n(l['quantity'] ?? l['issued_qty'] ?? l['planned_qty'])),
                                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                              if (showCost && isPv && n(l['unit_cost']) > 0) ...[
                                const SizedBox(width: 12),
                                SizedBox(
                                  width: 90,
                                  child: Text('Rs ${_rs.format(n(l['unit_cost']) * n(l['quantity']))}',
                                      textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)),
                                ),
                              ],
                            ]),
                          ),
                      ],
                      if (showCost && ohs.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Text('Labour & overheads', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                        const SizedBox(height: 6),
                        for (final o in ohs)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(children: [
                              Expanded(
                                child: Text(
                                    [o['cost_type'], o['description']].whereType<String>().where((x) => x.trim().isNotEmpty).join(' · '),
                                    style: const TextStyle(fontSize: 12.5)),
                              ),
                              Text('Rs ${_rs.format(n(o['amount']))}', style: const TextStyle(fontSize: 12.5)),
                            ]),
                          ),
                      ],
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  // ── mobile cards ──────────────────────────────────────────────────────
  Widget _runsCards(List<_Run> rows, bool showCost) {
    final produced = rows.fold<double>(0, (s, r) => s + r.produced);
    return ListView(children: [
      for (final r in rows)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            onTap: () => _openRun(r),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(r.doc,
                        style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.primary, decoration: TextDecoration.underline)),
                  ),
                  Text(r.date == null ? '' : _d.format(r.date!), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
                const SizedBox(height: 4),
                Text(_prodName[r.productId] ?? '—', style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Wrap(spacing: 12, runSpacing: 4, children: [
                  Text('Produced ${_q.format(r.produced)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (r.rejected > 0) Text('Rejected ${_q.format(r.rejected)}', style: const TextStyle(color: Colors.red)),
                  Text(r.source == 'PV' ? 'Voucher' : 'Job batch', style: const TextStyle(color: AppTheme.textSecondary)),
                  if ((_branchName[r.branchId] ?? '').isNotEmpty) Text(_branchName[r.branchId]!, style: const TextStyle(color: AppTheme.textSecondary)),
                  Text(r.status, style: TextStyle(color: r.status == 'posted' ? Colors.green.shade700 : Colors.orange.shade800)),
                ]),
                if (showCost) ...[
                  const SizedBox(height: 4),
                  Wrap(spacing: 12, children: [
                    Text('Overheads Rs ${_rs.format(r.overhead)}', style: TextStyle(fontSize: 12, color: Colors.teal.shade700)),
                    if (r.cost != null) Text('Total Rs ${_rs.format(r.cost)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ]),
                ],
              ]),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('${rows.length} runs · ${_q.format(produced)} produced',
            textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    ]);
  }

  Widget _productCards(List<_Run> rows, bool showCost) {
    final data = _byProduct(rows);
    return ListView(children: [
      for (final e in data)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_prodName[e['pid']] ?? '—', style: const TextStyle(fontWeight: FontWeight.w700)),
              if ((_prodSku[e['pid']] ?? '').isNotEmpty)
                Text(_prodSku[e['pid']]!, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              const SizedBox(height: 4),
              Wrap(spacing: 12, runSpacing: 4, children: [
                Text('Produced ${_q.format(e['produced'])}', style: const TextStyle(fontWeight: FontWeight.w800)),
                Text('${e['runs']} run${e['runs'] == 1 ? '' : 's'}', style: const TextStyle(color: AppTheme.textSecondary)),
                if ((e['rejected'] as double) > 0) Text('Rejected ${_q.format(e['rejected'])}', style: const TextStyle(color: Colors.red)),
              ]),
              if (showCost) ...[
                const SizedBox(height: 4),
                Wrap(spacing: 12, children: [
                  Text('Overheads Rs ${_rs.format(e['oh'])}', style: TextStyle(fontSize: 12, color: Colors.teal.shade700)),
                  if (e['hasCost'] == true) Text('Total Rs ${_rs.format(e['cost'])}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  if (e['hasCost'] == true && (e['produced'] as double) > 0)
                    Text('Rs ${NumberFormat('#,##0.00').format((e['cost'] as double) / (e['produced'] as double))}/unit',
                        style: const TextStyle(fontSize: 12)),
                ]),
              ],
            ]),
          ),
        ),
    ]);
  }

  // ── print / PDF ────────────────────────────────────────────────────────
  static String _esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  void _print(List<_Run> rows, bool showCost) {
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final gen = DateFormat('d MMM yyyy, HH:mm').format(DateTime.now());
    final produced = rows.fold<double>(0, (s, r) => s + r.produced);
    final rejected = rows.fold<double>(0, (s, r) => s + r.rejected);
    final cost = rows.fold<double>(0, (s, r) => s + (r.cost ?? 0));
    final filters = <String>[
      _source == 'pv' ? 'Production Vouchers' : _source == 'job' ? 'Job Card batches' : 'All runs',
      _postedOnly ? 'Posted only' : 'Including drafts',
      if (_branch != 'all') 'Branch: ${_branchName[_branch] ?? _branch}',
      if (_search.text.trim().isNotEmpty) 'Search: “${_search.text.trim()}”',
    ];
    final prod = StringBuffer();
    for (final e in _byProduct(rows)) {
      prod.write('<tr><td>${_esc(_prodSku[e['pid']] ?? '')}</td><td><b>${_esc(_prodName[e['pid']] ?? '—')}</b></td>'
          '<td class="num">${e['runs']}</td><td class="num"><b>${_q.format(e['produced'])}</b></td>'
          '<td class="num">${(e['rejected'] as double) > 0 ? _q.format(e['rejected']) : ''}</td>'
          '${showCost ? '<td class="num">${(e['oh'] as double) == 0 ? '' : _rs.format(e['oh'])}</td><td class="num">${e['hasCost'] == true ? _rs.format(e['cost']) : ''}</td>' : ''}</tr>');
    }
    final det = StringBuffer();
    for (final r in rows) {
      det.write('<tr><td>${r.date == null ? '' : _d.format(r.date!)}</td><td class="doc">${_esc(r.doc)}</td>'
          '<td>${r.source == 'PV' ? 'Voucher' : 'Job batch'}</td>'
          '<td>${_esc('${_prodSku[r.productId]?.isNotEmpty == true ? '${_prodSku[r.productId]} · ' : ''}${_prodName[r.productId] ?? '—'}')}</td>'
          '<td>${_esc(_branchName[r.branchId] ?? '')}</td><td class="num"><b>${_q.format(r.produced)}</b></td>'
          '<td class="num">${r.rejected > 0 ? _q.format(r.rejected) : ''}</td><td>${_esc(r.status)}</td>'
          '${showCost ? '<td class="num">${r.overhead == 0 ? '' : _rs.format(r.overhead)}</td><td class="num">${r.cost == null ? '' : _rs.format(r.cost)}</td>' : ''}</tr>');
    }
    final doc = '''<!doctype html><html><head><meta charset="utf-8"><title>Production Report $_rangeLabel</title>
<style>
@page { size: A4 landscape; margin: 12mm; }
* { box-sizing: border-box; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body { font-family: -apple-system, Segoe UI, Roboto, Arial, sans-serif; color: #0F1729; font-size: 10.5px; margin: 0; }
.head { display: flex; justify-content: space-between; align-items: flex-end; border-bottom: 2px solid #2F6FED; padding-bottom: 6px; margin-bottom: 8px; }
.org { font-size: 11px; color: #2F6FED; font-weight: 800; letter-spacing: 1px; text-transform: uppercase; }
h1 { font-size: 20px; margin: 2px 0 0; }
h2 { font-size: 12px; margin: 14px 0 6px; text-transform: uppercase; letter-spacing: .6px; color: #374151; }
.meta { text-align: right; color: #6B7280; }
.filters { color: #374151; margin: 0 0 8px; }
.kpis { display: flex; gap: 10px; margin: 6px 0 4px; }
.kpi { border: 1px solid #E5E7EB; border-radius: 8px; padding: 6px 12px; }
.kpi span { display: block; color: #6B7280; font-size: 9px; }
.kpi b { font-size: 15px; }
table { width: 100%; border-collapse: collapse; }
th { background: #F3F4F6; text-align: left; padding: 5px 6px; font-size: 9.5px; text-transform: uppercase; letter-spacing: .4px; color: #374151; }
td { padding: 4px 6px; border-bottom: 1px solid #EEE; vertical-align: top; }
td.doc { color: #2F6FED; font-weight: 700; white-space: nowrap; }
.num { text-align: right; white-space: nowrap; }
tr.tot td { background: #F3F4F6; font-weight: 800; }
thead { display: table-header-group; }
tr { page-break-inside: avoid; }
.foot { margin-top: 10px; display: flex; justify-content: space-between; color: #9CA3AF; font-size: 9px; }
</style></head><body>
<div class="head"><div><div class="org">${_esc(org)}</div><h1>Production Report</h1></div>
<div class="meta"><b>${_esc(_rangeLabel)}</b><br>Printed $gen</div></div>
<div class="filters">${_esc(filters.join('  ·  '))}</div>
<div class="kpis"><div class="kpi"><span>Runs</span><b>${rows.length}</b></div>
<div class="kpi"><span>Produced</span><b>${_q.format(produced)}</b></div>
${rejected > 0 ? '<div class="kpi"><span>Rejected</span><b style="color:#DC2626">${_q.format(rejected)}</b></div>' : ''}
${showCost ? '<div class="kpi"><span>Absorbed overheads</span><b>Rs ${_rs.format(rows.fold<double>(0, (s, r) => s + r.overhead))}</b></div><div class="kpi"><span>Production cost (total)</span><b>Rs ${_rs.format(cost)}</b></div>' : ''}</div>
<h2>By product</h2>
<table><thead><tr><th>SKU</th><th>Product</th><th class="num">Runs</th><th class="num">Produced</th><th class="num">Rejected</th>${showCost ? '<th class="num">Abs. overheads</th><th class="num">Total cost</th>' : ''}</tr></thead>
<tbody>$prod<tr class="tot"><td></td><td>Total</td><td class="num">${rows.length}</td><td class="num">${_q.format(produced)}</td><td class="num">${_q.format(rejected)}</td>${showCost ? '<td class="num">${_rs.format(rows.fold<double>(0, (s, r) => s + r.overhead))}</td><td class="num">${_rs.format(cost)}</td>' : ''}</tr></tbody></table>
<h2>Runs</h2>
<table><thead><tr><th>Date</th><th>Doc</th><th>Source</th><th>Product</th><th>Branch</th><th class="num">Produced</th><th class="num">Rejected</th><th>Status</th>${showCost ? '<th class="num">Abs. overheads</th><th class="num">Total cost</th>' : ''}</tr></thead>
<tbody>$det</tbody></table>
<div class="foot"><span>Opstation ERP · Production Report</span><span>Printed $gen</span></div>
</body></html>''';
    try {
      html.document.getElementById('ops-print-frame')?.remove();
      final frame = html.IFrameElement()
        ..id = 'ops-print-frame'
        ..style.position = 'fixed'
        ..style.left = '-9999px'
        ..style.width = '0'
        ..style.height = '0'
        ..style.border = '0';
      frame.srcdoc = doc.replaceFirst('</body>',
          '<script>window.onload=function(){setTimeout(function(){try{window.focus();window.print();}catch(e){}},350);};</script></body>');
      html.document.body!.append(frame);
    } catch (_) {
      final blob = html.Blob([doc], 'text/html;charset=utf-8');
      html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
    }
  }
}
