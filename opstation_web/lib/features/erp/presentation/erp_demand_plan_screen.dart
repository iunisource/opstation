import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:excel/excel.dart' as xls;

import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Demand & Replenishment Planner.
///
/// Calls fn_demand_plan(org, branch, lead_days, target_cover) and renders, per
/// product x branch: average daily demand, days of cover, reorder point, and a
/// suggested order/production quantity, with make/buy, confidence, and an
/// urgency status. Buy rows can be ticked and turned into a draft Purchase
/// Order (the user picks the supplier).
class ErpDemandPlanScreen extends ConsumerStatefulWidget {
  const ErpDemandPlanScreen({super.key});
  @override
  ConsumerState<ErpDemandPlanScreen> createState() => _ErpDemandPlanScreenState();
}

class _ErpDemandPlanScreenState extends ConsumerState<ErpDemandPlanScreen> {
  // RPC params
  String? _branchId; // null = all branches
  final _leadCtrl = TextEditingController(text: '14');
  final _targetCtrl = TextEditingController(text: '30');

  // client-side filters
  String _kind = 'all'; // all | buy | make
  String _status = 'all';
  final _searchCtrl = TextEditingController();

  // data
  List<Map<String, dynamic>> _branches = [];
  List<Map<String, dynamic>> _suppliers = [];
  List<Map<String, dynamic>> _rows = [];
  final Set<String> _selected = {}; // key = product_id|branch_id

  bool _loadingFilters = true;
  bool _running = false;
  bool _hasRun = false;
  bool _creatingPo = false;
  String? _runError;

  @override
  void initState() {
    super.initState();
    _loadFilters();
  }

  @override
  void dispose() {
    _leadCtrl.dispose();
    _targetCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFilters() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) { setState(() => _loadingFilters = false); return; }
    try {
      final client = Supabase.instance.client;
      final br = await client.from('branches')
          .select('id, name').eq('org_id', orgId).eq('is_active', true).order('name');
      final sup = await client.from('suppliers')
          .select('id, name').eq('org_id', orgId).eq('is_active', true).order('name');
      setState(() {
        _branches = List<Map<String, dynamic>>.from(br);
        _suppliers = List<Map<String, dynamic>>.from(sup);
        _loadingFilters = false;
      });
    } catch (_) {
      setState(() => _loadingFilters = false);
    }
  }

  Future<void> _run() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() { _running = true; _runError = null; });
    try {
      final res = await Supabase.instance.client.rpc('fn_demand_plan', params: {
        'p_org_id': orgId,
        'p_branch_id': _branchId,
        'p_lead_days': double.tryParse(_leadCtrl.text.trim()) ?? 14,
        'p_target_cover': double.tryParse(_targetCtrl.text.trim()) ?? 30,
      });
      setState(() {
        _rows = List<Map<String, dynamic>>.from(res as List);
        _selected.clear();
        _running = false;
        _hasRun = true;
      });
    } catch (e) {
      setState(() { _running = false; _hasRun = true; _runError = '$e'; _rows = []; });
    }
  }

  // ── filtering ──────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _rows.where((r) {
      if (_kind != 'all' && (r['plan_kind'] as String? ?? 'buy') != _kind) return false;
      if (_status != 'all' && (r['status'] as String? ?? '') != _status) return false;
      if (!matchesQuery('${r['product_name'] ?? ''} ${r['sku'] ?? ''}', q)) return false;
      return true;
    }).toList();
  }

  String _key(Map<String, dynamic> r) =>
      '${r['product_id']}|${r['branch_id']}';

  bool _isBuyActionable(Map<String, dynamic> r) =>
      (r['plan_kind'] as String? ?? 'buy') == 'buy' && _num(r['suggested_qty']) > 0;

  // ── number / text helpers (mirrors purchase report) ─────────────────────────
  double _num(dynamic v) => v == null ? 0.0 : (v as num).toDouble();
  String _group(String s) {
    final neg = s.startsWith('-');
    s = neg ? s.substring(1) : s;
    final dot = s.indexOf('.');
    final intPart = dot == -1 ? s : s.substring(0, dot);
    final frac = dot == -1 ? '' : s.substring(dot);
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return '${neg ? '-' : ''}$buf$frac';
  }

  String _num0(num? n) {
    final v = (n ?? 0).toDouble();
    final whole = v.roundToDouble() == v;
    return _group(whole ? v.toStringAsFixed(0) : v.toStringAsFixed(2));
  }

  String _num2(num? n) => _group((n ?? 0).toDouble().toStringAsFixed(2));
  String _cover(dynamic v) => v == null ? '—' : _num0(v as num);

  String _ascii(String s) => s
      .replaceAll('\u2014', '-').replaceAll('\u2013', '-').replaceAll('\u2026', '...')
      .replaceAll('\u201c', '"').replaceAll('\u201d', '"')
      .replaceAll('\u2018', "'").replaceAll('\u2019', "'")
      .replaceAll(RegExp(r'[^\x20-\x7E]'), '');

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'Stockout': return AppTheme.danger;
      case 'Reorder now': return Colors.orange.shade800;
      case 'Watch': return Colors.amber.shade800;
      case 'Overstock': return Colors.blue.shade700;
      case 'OK': return AppTheme.success;
      default: return AppTheme.textSecondary; // No demand
    }
  }

  String _branchName(String? id) {
    if (id == null) return '';
    for (final b in _branches) { if (b['id'] == id) return b['name'] as String? ?? ''; }
    return '';
  }

  // ── draft PO from selected buy rows ─────────────────────────────────────────
  Future<void> _createDraftPo() async {
    final selectedRows = _rows.where((r) => _selected.contains(_key(r))).toList();
    final buyRows = selectedRows.where(_isBuyActionable).toList();
    final makeSkipped = selectedRows.where((r) => (r['plan_kind'] as String?) == 'make').length;
    if (buyRows.isEmpty) {
      _showSnack(makeSkipped > 0
          ? 'Only "make" items selected — those are produced, not purchased. Pick buy items for a PO.'
          : 'Select buy items with a suggested quantity first.');
      return;
    }

    // pick supplier
    final supplierId = await showDialog<String?>(
      context: context,
      builder: (ctx) => _SupplierPickerDialog(suppliers: _suppliers),
    );
    if (supplierId == null) return;

    setState(() => _creatingPo = true);
    final client = Supabase.instance.client;
    final orgId = ref.read(currentUserProvider)?.orgId;
    final userId = ref.read(currentUserProvider)?.id;
    try {
      // fresh uom + cost for the products
      final pids = buyRows.map((r) => r['product_id'] as String).toSet().toList();
      final prods = await client.from('products')
          .select('id, base_uom_id, cost_price').inFilter('id', pids);
      final uomOf = <String, dynamic>{};
      final costOf = <String, double>{};
      for (final p in prods as List) {
        uomOf[p['id'] as String] = p['base_uom_id'];
        costOf[p['id'] as String] = (p['cost_price'] as num?)?.toDouble() ?? 0;
      }

      // group by branch (PO is branch-scoped) → one draft PO per branch
      final byBranch = <String, List<Map<String, dynamic>>>{};
      for (final r in buyRows) {
        (byBranch[r['branch_id'] as String] ??= []).add(r);
      }

      final created = <String>[];
      final year = DateTime.now().year;
      final today = _ymd(DateTime.now());
      for (final entry in byBranch.entries) {
        final branchId = entry.key;
        final voucherNum = await client.rpc('next_voucher_number',
            params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'PO', 'p_year': year});
        final poId = 'po_${DateTime.now().millisecondsSinceEpoch}';
        await client.from('purchase_orders').insert({
          'id': poId, 'org_id': orgId, 'branch_id': branchId,
          'voucher_number': voucherNum,
          'voucher_date': today,
          'supplier_id': supplierId,
          'remarks': 'Auto-created from Demand Planner',
          'status': 'draft', 'is_locked': false, 'created_by': userId,
        });
        var n = 0;
        for (final r in entry.value) {
          final pid = r['product_id'] as String;
          await client.from('purchase_order_items').insert({
            'id': 'poi_${DateTime.now().microsecondsSinceEpoch}_${n++}',
            'purchase_order_id': poId,
            'product_id': pid,
            'uom_id': uomOf[pid],
            'quantity_ordered': _num(r['suggested_qty']),
            'quantity_received': 0,
            'unit_cost': costOf[pid] ?? 0,
          });
        }
        created.add(voucherNum.toString());
      }

      setState(() { _creatingPo = false; _selected.clear(); });
      _showSnack(
        'Draft PO created: ${created.join(', ')}'
        '${makeSkipped > 0 ? ' — $makeSkipped make item(s) skipped (produce via Manufacturing)' : ''}'
        '. Open Purchase Orders to review and order.',
      );
    } catch (e) {
      setState(() => _creatingPo = false);
      _showSnack('Failed to create PO: $e');
    }
  }

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ── build ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Demand & Replenishment Planner',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text(
              'Average daily demand, days of cover, and suggested order/production quantities per product and branch.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          if (_loadingFilters)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator())
          else
            _filterBar(),
          const SizedBox(height: 12),
          if (_hasRun && _runError == null && _rows.isNotEmpty) _actionRow(),
          Expanded(child: _results()),
        ],
      ),
    );
  }

  Widget _filterBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Wrap(
        spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(width: 200, child: DropdownButtonFormField<String?>(
            value: _branchId, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Branch'),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('All branches')),
              ..._branches.map((b) => DropdownMenuItem<String?>(
                  value: b['id'] as String, child: Text(b['name'] as String? ?? ''))),
            ],
            onChanged: (v) => setState(() => _branchId = v),
          )),
          SizedBox(width: 120, child: TextField(
            controller: _leadCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Lead days'),
          )),
          SizedBox(width: 140, child: TextField(
            controller: _targetCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Target cover (days)'),
          )),
          ElevatedButton.icon(
            onPressed: _running ? null : _run,
            icon: const Icon(Icons.insights_outlined, size: 18),
            label: Text(_running ? 'Running…' : 'Run Planner'),
          ),
          if (_hasRun && _rows.isNotEmpty) ...[
            const SizedBox(width: 4),
            SizedBox(width: 150, child: DropdownButtonFormField<String>(
              value: _kind, isExpanded: true,
              decoration: const InputDecoration(labelText: 'Type'),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('Make + Buy')),
                DropdownMenuItem(value: 'buy', child: Text('Buy only')),
                DropdownMenuItem(value: 'make', child: Text('Make only')),
              ],
              onChanged: (v) => setState(() => _kind = v ?? 'all'),
            )),
            SizedBox(width: 160, child: DropdownButtonFormField<String>(
              value: _status, isExpanded: true,
              decoration: const InputDecoration(labelText: 'Status'),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All statuses')),
                DropdownMenuItem(value: 'Stockout', child: Text('Stockout')),
                DropdownMenuItem(value: 'Reorder now', child: Text('Reorder now')),
                DropdownMenuItem(value: 'Watch', child: Text('Watch')),
                DropdownMenuItem(value: 'OK', child: Text('OK')),
                DropdownMenuItem(value: 'Overstock', child: Text('Overstock')),
                DropdownMenuItem(value: 'No demand', child: Text('No demand')),
              ],
              onChanged: (v) => setState(() => _status = v ?? 'all'),
            )),
            SizedBox(width: 200, child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                  labelText: 'Search product / SKU', isDense: true),
              onChanged: (_) => setState(() {}),
            )),
          ],
        ],
      ),
    );
  }

  Widget _actionRow() {
    final rows = _filtered;
    final selectableKeys = rows.where(_isBuyActionable).map(_key).toSet();
    final allSelected = selectableKeys.isNotEmpty && selectableKeys.every(_selected.contains);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        Text('${rows.length} line(s)',
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        const SizedBox(width: 16),
        if (selectableKeys.isNotEmpty)
          TextButton.icon(
            icon: Icon(allSelected ? Icons.check_box_outlined : Icons.check_box_outline_blank, size: 18),
            label: Text(allSelected ? 'Clear buy selection' : 'Select all buy rows'),
            onPressed: () => setState(() {
              if (allSelected) {
                _selected.removeAll(selectableKeys);
              } else {
                _selected.addAll(selectableKeys);
              }
            }),
          ),
        const Spacer(),
        if (_selected.isNotEmpty)
          ElevatedButton.icon(
            onPressed: _creatingPo ? null : _createDraftPo,
            icon: const Icon(Icons.add_shopping_cart_outlined, size: 18),
            label: Text(_creatingPo ? 'Creating…' : 'Create draft PO (${_selected.length})'),
          ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: _printPdf,
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
          label: const Text('Print / PDF'),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: _exportExcel,
          icon: const Icon(Icons.grid_on_outlined, size: 18),
          label: const Text('Export Excel'),
        ),
      ]),
    );
  }

  Widget _results() {
    if (_running) return const Center(child: CircularProgressIndicator());
    if (!_hasRun) {
      return const Center(child: Text('Set the lead time and target cover, then tap Run Planner.',
          style: TextStyle(color: AppTheme.textSecondary)));
    }
    if (_runError != null) {
      return Center(child: Text('Failed to run planner:\n$_runError',
          textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.danger)));
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return const Center(child: Text('No lines match the current filters.',
          style: TextStyle(color: AppTheme.textSecondary)));
    }
    final showBranch = _branchId == null;
    return SingleChildScrollView(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _tableHeader(showBranch),
          const Divider(height: 1),
          ...rows.map((r) => _row(r, showBranch)),
        ]),
      ),
    );
  }

  Widget _tableHeader(bool showBranch) {
    TextStyle h() => const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        const SizedBox(width: 36),
        Expanded(flex: 5, child: Text('Product', style: h())),
        if (showBranch) Expanded(flex: 3, child: Text('Branch', style: h())),
        Expanded(flex: 2, child: Text('Demand/day', textAlign: TextAlign.right, style: h())),
        Expanded(flex: 2, child: Text('Confidence', textAlign: TextAlign.right, style: h())),
        Expanded(flex: 2, child: Text('Stock', textAlign: TextAlign.right, style: h())),
        Expanded(flex: 2, child: Text('Cover (d)', textAlign: TextAlign.right, style: h())),
        Expanded(flex: 2, child: Text('Reorder Point', textAlign: TextAlign.right, style: h())),
        Expanded(flex: 2, child: Text('Already Ordered', textAlign: TextAlign.right, style: h())),
        Expanded(flex: 2, child: Text('Suggest Qty', textAlign: TextAlign.right, style: h())),
        Expanded(flex: 3, child: Text('Status', textAlign: TextAlign.right, style: h())),
      ]),
    );
  }

  Widget _row(Map<String, dynamic> r, bool showBranch) {
    final kind = r['plan_kind'] as String? ?? 'buy';
    final status = r['status'] as String? ?? '';
    final neg = r['negative_stock'] == true;
    final conf = r['confidence'] as String? ?? '-';
    final actionable = _isBuyActionable(r);
    final key = _key(r);
    final selected = _selected.contains(key);

    return Container(
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFF1F1F1)))),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 36, child: actionable
            ? Checkbox(
                value: selected, visualDensity: VisualDensity.compact,
                onChanged: (v) => setState(() {
                  if (v == true) { _selected.add(key); } else { _selected.remove(key); }
                }))
            : Tooltip(
                message: kind == 'make' ? 'Manufactured — produce, not purchase' : 'No suggested quantity',
                child: const Icon(Icons.remove, size: 14, color: Color(0xFFCBD5E1)))),
        Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text(r['product_name'] as String? ?? '-',
                style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 6),
            _tag(kind == 'make' ? 'MAKE' : 'BUY',
                kind == 'make' ? Colors.purple.shade400 : AppTheme.textSecondary),
            if (neg) ...[const SizedBox(width: 4), _tag('NEG STOCK', AppTheme.danger)],
          ]),
          if ((r['sku'] as String?)?.isNotEmpty == true)
            Text('SKU ${r['sku']}',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
        if (showBranch) Expanded(flex: 3, child: Text(_branchName(r['branch_id'] as String?),
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        Expanded(flex: 2, child: Text(_num0(r['avg_daily_demand'] as num?),
            textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
        Expanded(flex: 2, child: Align(alignment: Alignment.centerRight,
            child: _confidenceChip(conf))),
        Expanded(flex: 2, child: Text(_num0(r['stock_on_hand'] as num?),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 13, color: neg ? AppTheme.danger : null,
                fontWeight: neg ? FontWeight.w700 : FontWeight.normal))),
        Expanded(flex: 2, child: Text(_cover(r['days_of_cover']),
            textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
        Expanded(flex: 2, child: Text(_num0(r['reorder_point'] as num?),
            textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
        Expanded(flex: 2, child: Text(_num0(r['on_order'] as num?),
            textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
        Expanded(flex: 2, child: Text(_num0(r['suggested_qty'] as num?),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                color: _num(r['suggested_qty']) > 0 ? AppTheme.primary : AppTheme.textSecondary))),
        Expanded(flex: 3, child: Align(alignment: Alignment.centerRight,
            child: _statusChip(status))),
      ]),
    );
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
            color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color)),
      );

  Color _confidenceColor(String c) {
    switch (c) {
      case 'High': return AppTheme.success;
      case 'Medium': return Colors.amber.shade800;
      case 'Low': return AppTheme.danger;
      default: return const Color(0xFFCBD5E1); // '-' (no demand)
    }
  }

  Widget _confidenceChip(String conf) {
    if (conf == '-') {
      return const Text('—', textAlign: TextAlign.right,
          style: TextStyle(fontSize: 13, color: Color(0xFFCBD5E1)));
    }
    final c = _confidenceColor(conf);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
      child: Text(conf, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
    );
  }

  Widget _statusChip(String status) {
    final c = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
      child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
    );
  }

  // ── PDF ─────────────────────────────────────────────────────────────────────
  Future<void> _printPdf() async {
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final rows = _filtered;
    final showBranch = _branchId == null;
    final headers = [
      'Product', if (showBranch) 'Branch', 'Type', 'Demand/day', 'Confidence', 'Stock',
      'Cover', 'Reorder Pt', 'Already Ordered', 'Suggest Qty', 'Status',
    ];
    final data = rows.map((r) => [
      _ascii('${r['product_name'] ?? ''}'),
      if (showBranch) _ascii(_branchName(r['branch_id'] as String?)),
      (r['plan_kind'] as String? ?? 'buy') == 'make' ? 'Make' : 'Buy',
      _num0(r['avg_daily_demand'] as num?),
      _ascii('${r['confidence'] ?? '-'}'),
      _num0(r['stock_on_hand'] as num?),
      _cover(r['days_of_cover']),
      _num0(r['reorder_point'] as num?),
      _num0(r['on_order'] as num?),
      _num0(r['suggested_qty'] as num?),
      _ascii('${r['status'] ?? ''}'),
    ]).toList();

    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      build: (ctx) => [
        if (org.isNotEmpty)
          pw.Text(_ascii(org), style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        pw.Text('Demand & Replenishment Planner',
            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text(
            'Branch: ${_ascii(showBranch ? 'All branches' : _branchName(_branchId))}     |     '
            'Lead: ${_leadCtrl.text} d     |     Target cover: ${_targetCtrl.text} d',
            style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: headers,
          data: data,
          headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 8),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          cellAlignments: {
            for (var i = 1; i < headers.length; i++) i: pw.Alignment.centerRight,
            0: pw.Alignment.centerLeft,
          },
          rowDecoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5))),
        ),
      ],
    ));
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat f) async => doc.save(),
      name: 'demand-plan-${_ymd(DateTime.now())}.pdf',
    );
  }

  // ── Excel ─────────────────────────────────────────────────────────────────────
  Future<void> _exportExcel() async {
    try {
      final excel = xls.Excel.createExcel();
      const sheetName = 'Demand Plan';
      final sheet = excel[sheetName];
      final def = excel.getDefaultSheet();
      if (def != null && def != sheetName) excel.delete(def);

      sheet.appendRow([xls.TextCellValue('Demand & Replenishment Planner')]);
      sheet.appendRow([
        xls.TextCellValue('Branch'),
        xls.TextCellValue(_branchId == null ? 'All branches' : _branchName(_branchId)),
        xls.TextCellValue('Lead days'), xls.TextCellValue(_leadCtrl.text),
        xls.TextCellValue('Target cover'), xls.TextCellValue(_targetCtrl.text),
      ]);
      sheet.appendRow([xls.TextCellValue('')]);
      sheet.appendRow([
        xls.TextCellValue('Product'), xls.TextCellValue('SKU'), xls.TextCellValue('Branch'),
        xls.TextCellValue('Type'), xls.TextCellValue('Confidence'),
        xls.TextCellValue('Days history'), xls.TextCellValue('Demand/day'),
        xls.TextCellValue('Stock'), xls.TextCellValue('Negative stock'),
        xls.TextCellValue('On order'), xls.TextCellValue('Days cover'),
        xls.TextCellValue('Reorder point'), xls.TextCellValue('Suggested qty'),
        xls.TextCellValue('Status'),
      ]);
      for (final r in _filtered) {
        sheet.appendRow([
          xls.TextCellValue('${r['product_name'] ?? ''}'),
          xls.TextCellValue('${r['sku'] ?? ''}'),
          xls.TextCellValue(_branchName(r['branch_id'] as String?)),
          xls.TextCellValue((r['plan_kind'] as String? ?? 'buy') == 'make' ? 'Make' : 'Buy'),
          xls.TextCellValue('${r['confidence'] ?? ''}'),
          xls.IntCellValue(((r['days_of_history'] as num?)?.toInt()) ?? 0),
          xls.DoubleCellValue(_num(r['avg_daily_demand'])),
          xls.DoubleCellValue(_num(r['stock_on_hand'])),
          xls.TextCellValue(r['negative_stock'] == true ? 'YES' : ''),
          xls.DoubleCellValue(_num(r['on_order'])),
          r['days_of_cover'] == null
              ? xls.TextCellValue('')
              : xls.DoubleCellValue(_num(r['days_of_cover'])),
          xls.DoubleCellValue(_num(r['reorder_point'])),
          xls.DoubleCellValue(_num(r['suggested_qty'])),
          xls.TextCellValue('${r['status'] ?? ''}'),
        ]);
      }
      excel.save(fileName: 'demand-plan-${_ymd(DateTime.now())}.xlsx');
    } catch (e) {
      _showSnack('Excel export failed: $e');
    }
  }
}

// ─── Supplier picker ──────────────────────────────────────────────────────────
class _SupplierPickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> suppliers;
  const _SupplierPickerDialog({required this.suppliers});
  @override
  State<_SupplierPickerDialog> createState() => _SupplierPickerDialogState();
}

class _SupplierPickerDialogState extends State<_SupplierPickerDialog> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final list = widget.suppliers.where((s) =>
        matchesQuery('${s['name'] ?? ''}', _q)).toList();
    return AlertDialog(
      title: const Text('Choose supplier for the draft PO', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 420, height: 460,
        child: Column(children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search), hintText: 'Search suppliers', isDense: true),
            onChanged: (v) => setState(() => _q = v),
          ),
          const SizedBox(height: 8),
          Expanded(child: list.isEmpty
              ? const Center(child: Text('No suppliers found',
                  style: TextStyle(color: AppTheme.textSecondary)))
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final s = list[i];
                    return ListTile(
                      dense: true,
                      title: Text(s['name'] as String? ?? '-'),
                      onTap: () => Navigator.of(context).pop(s['id'] as String),
                    );
                  },
                )),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      ],
    );
  }
}
