import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:excel/excel.dart' as xls;

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Production Material Planner (BOM explosion / raw-material MRP).
///
/// Calls fn_production_plan(org, branch, lead_days, target_cover): explodes each
/// manufactured product's planned production through its BOM into raw-material
/// requirements, netted against component stock, open POs, and open production
/// (WIP). Shortfall components can be ticked and turned into a draft Purchase
/// Order (the user picks the supplier).
class ErpProductionPlanScreen extends ConsumerStatefulWidget {
  const ErpProductionPlanScreen({super.key});
  @override
  ConsumerState<ErpProductionPlanScreen> createState() => _ErpProductionPlanScreenState();
}

class _ErpProductionPlanScreenState extends ConsumerState<ErpProductionPlanScreen> {
  String? _branchId; // null = all branches
  String _mode = 'jobcard'; // 'jobcard' = explode scheduled job cards; 'forecast' = consumption forecast
  final _leadCtrl = TextEditingController(text: '14');
  final _targetCtrl = TextEditingController(text: '30');

  String _status = 'all'; // all | Shortfall | Covered
  final _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _branches = [];
  List<Map<String, dynamic>> _suppliers = [];
  List<Map<String, dynamic>> _rows = [];
  final Set<String> _selected = {}; // key = component_id|branch_id

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
      final res = await Supabase.instance.client.rpc('fn_production_plan', params: {
        'p_org_id': orgId,
        'p_branch_id': _branchId,
        'p_lead_days': double.tryParse(_leadCtrl.text.trim()) ?? 14,
        'p_target_cover': double.tryParse(_targetCtrl.text.trim()) ?? 30,
        'p_mode': _mode,
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

  List<Map<String, dynamic>> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _rows.where((r) {
      if (_status != 'all' && (r['status'] as String? ?? '') != _status) return false;
      if (q.isNotEmpty) {
        final name = (r['component_name'] as String? ?? '').toLowerCase();
        final sku = (r['component_sku'] as String? ?? '').toLowerCase();
        final drv = (r['driven_by'] as String? ?? '').toLowerCase();
        if (!name.contains(q) && !sku.contains(q) && !drv.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  String _key(Map<String, dynamic> r) => '${r['component_id']}|${r['branch_id']}';
  bool _isActionable(Map<String, dynamic> r) =>
      (r['status'] as String? ?? '') == 'Shortfall' && _num(r['net_required']) > 0;

  // number / text helpers
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

  String _ascii(String s) => s
      .replaceAll('\u2014', '-').replaceAll('\u2013', '-').replaceAll('\u2026', '...')
      .replaceAll('\u201c', '"').replaceAll('\u201d', '"')
      .replaceAll('\u2018', "'").replaceAll('\u2019', "'")
      .replaceAll(RegExp(r'[^\x20-\x7E]'), '');

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Color _statusColor(String s) => s == 'Shortfall' ? AppTheme.danger : AppTheme.success;

  String _branchName(String? id) {
    if (id == null) return '';
    for (final b in _branches) { if (b['id'] == id) return b['name'] as String? ?? ''; }
    return '';
  }

  // ── draft PO from selected shortfall components ─────────────────────────────
  Future<void> _createDraftPo() async {
    final selectedRows = _rows.where((r) => _selected.contains(_key(r))).toList();
    final buyRows = selectedRows.where(_isActionable).toList();
    if (buyRows.isEmpty) {
      _showSnack('Select shortfall components with a net quantity first.');
      return;
    }
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
      final pids = buyRows.map((r) => r['component_id'] as String).toSet().toList();
      final prods = await client.from('products')
          .select('id, base_uom_id, cost_price').inFilter('id', pids);
      final uomOf = <String, dynamic>{};
      final costOf = <String, double>{};
      for (final p in prods as List) {
        uomOf[p['id'] as String] = p['base_uom_id'];
        costOf[p['id'] as String] = (p['cost_price'] as num?)?.toDouble() ?? 0;
      }

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
          'remarks': 'Auto-created from Production Material Planner',
          'status': 'draft', 'is_locked': false, 'created_by': userId,
        });
        var n = 0;
        for (final r in entry.value) {
          final pid = r['component_id'] as String;
          await client.from('purchase_order_items').insert({
            'id': 'poi_${DateTime.now().microsecondsSinceEpoch}_${n++}',
            'purchase_order_id': poId,
            'product_id': pid,
            'uom_id': uomOf[pid],
            'quantity_ordered': _num(r['net_required']),
            'quantity_received': 0,
            'unit_cost': costOf[pid] ?? 0,
          });
        }
        created.add(voucherNum.toString());
      }

      setState(() { _creatingPo = false; _selected.clear(); });
      _showSnack('Draft PO created: ${created.join(', ')}. Open Purchase Orders to review and order.');
    } catch (e) {
      setState(() => _creatingPo = false);
      _showSnack('Failed to create PO: $e');
    }
  }

  // ── build ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Production Material Planner',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text(
              'Raw-material requirements exploded from planned production, netted against stock, open POs and work-in-progress.',
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
          // Where demand comes from: scheduled job cards (deterministic) or the
          // consumption forecast. Job Cards is the default.
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.only(left: 2, bottom: 4),
              child: Text('Demand source',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'jobcard', label: Text('Job Cards'), icon: Icon(Icons.assignment_outlined, size: 16)),
                ButtonSegment(value: 'forecast', label: Text('Forecast'), icon: Icon(Icons.trending_up, size: 16)),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
              ),
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ]),
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
            icon: const Icon(Icons.account_tree_outlined, size: 18),
            label: Text(_running ? 'Running…' : 'Run Planner'),
          ),
          if (_hasRun && _rows.isNotEmpty) ...[
            const SizedBox(width: 4),
            SizedBox(width: 160, child: DropdownButtonFormField<String>(
              value: _status, isExpanded: true,
              decoration: const InputDecoration(labelText: 'Status'),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All')),
                DropdownMenuItem(value: 'Shortfall', child: Text('Shortfall')),
                DropdownMenuItem(value: 'Covered', child: Text('Covered')),
              ],
              onChanged: (v) => setState(() => _status = v ?? 'all'),
            )),
            SizedBox(width: 220, child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                  labelText: 'Search component / driver', isDense: true),
              onChanged: (_) => setState(() {}),
            )),
          ],
        ],
      ),
    );
  }

  Widget _actionRow() {
    final rows = _filtered;
    final selectableKeys = rows.where(_isActionable).map(_key).toSet();
    final allSelected = selectableKeys.isNotEmpty && selectableKeys.every(_selected.contains);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        Text('${rows.length} component(s)',
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        const SizedBox(width: 16),
        if (selectableKeys.isNotEmpty)
          TextButton.icon(
            icon: Icon(allSelected ? Icons.check_box_outlined : Icons.check_box_outline_blank, size: 18),
            label: Text(allSelected ? 'Clear selection' : 'Select all shortfalls'),
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
      return const Center(child: Text(
          'No raw-material requirements. (Nothing manufactured needs building right now, '
          'or finished-goods demand is zero.)',
          textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary)));
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
        Expanded(flex: 5, child: Text('Component', style: h())),
        if (showBranch) Expanded(flex: 3, child: Text('Branch', style: h())),
        Expanded(flex: 2, child: Text('Gross need', textAlign: TextAlign.right, style: h())),
        Expanded(flex: 2, child: Text('Stock', textAlign: TextAlign.right, style: h())),
        Expanded(flex: 2, child: Text('Already Ordered', textAlign: TextAlign.right, style: h())),
        Expanded(flex: 2, child: Text('In Production', textAlign: TextAlign.right, style: h())),
        Expanded(flex: 2, child: Text('Net to Buy', textAlign: TextAlign.right, style: h())),
        Expanded(flex: 2, child: Text('Status', textAlign: TextAlign.right, style: h())),
      ]),
    );
  }

  Widget _row(Map<String, dynamic> r, bool showBranch) {
    final status = r['status'] as String? ?? '';
    final neg = r['comp_negative_stock'] == true;
    final actionable = _isActionable(r);
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
            : const Icon(Icons.check, size: 14, color: Color(0xFF86C99B))),
        Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text(r['component_name'] as String? ?? '-',
                style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
            if (neg) ...[const SizedBox(width: 6), _tag('NEG STOCK', AppTheme.danger)],
          ]),
          Text([
            if ((r['component_sku'] as String?)?.isNotEmpty == true) 'SKU ${r['component_sku']}',
            if ((r['driven_by'] as String?)?.isNotEmpty == true) 'for ${r['driven_by']}',
          ].join('   ·   '),
              style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
        if (showBranch) Expanded(flex: 3, child: Text(_branchName(r['branch_id'] as String?),
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        Expanded(flex: 2, child: Text(_num0(r['gross_required'] as num?),
            textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
        Expanded(flex: 2, child: Text(_num0(r['comp_stock'] as num?),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 13, color: neg ? AppTheme.danger : null,
                fontWeight: neg ? FontWeight.w700 : FontWeight.normal))),
        Expanded(flex: 2, child: Text(_num0(r['comp_on_order'] as num?),
            textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
        Expanded(flex: 2, child: Text(_num0(r['comp_in_wip'] as num?),
            textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
        Expanded(flex: 2, child: Text(_num0(r['net_required'] as num?),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                color: _num(r['net_required']) > 0 ? AppTheme.primary : AppTheme.textSecondary))),
        Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: _statusChip(status))),
      ]),
    );
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
            color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color)),
      );

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
      'Component', if (showBranch) 'Branch', 'Driven by', 'Gross need', 'Stock',
      'Already Ordered', 'In Production', 'Net to Buy', 'Status',
    ];
    final data = rows.map((r) => [
      _ascii('${r['component_name'] ?? ''}'),
      if (showBranch) _ascii(_branchName(r['branch_id'] as String?)),
      _ascii('${r['driven_by'] ?? ''}'),
      _num0(r['gross_required'] as num?),
      _num0(r['comp_stock'] as num?),
      _num0(r['comp_on_order'] as num?),
      _num0(r['comp_in_wip'] as num?),
      _num0(r['net_required'] as num?),
      _ascii('${r['status'] ?? ''}'),
    ]).toList();

    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      build: (ctx) => [
        if (org.isNotEmpty)
          pw.Text(_ascii(org), style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        pw.Text('Production Material Planner',
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
            for (var i = 0; i < headers.length; i++) i: pw.Alignment.centerRight,
            0: pw.Alignment.centerLeft,
          },
          rowDecoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5))),
        ),
      ],
    ));
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat f) async => doc.save(),
      name: 'production-material-plan-${_ymd(DateTime.now())}.pdf',
    );
  }

  // ── Excel ─────────────────────────────────────────────────────────────────────
  Future<void> _exportExcel() async {
    try {
      final excel = xls.Excel.createExcel();
      const sheetName = 'Production Plan';
      final sheet = excel[sheetName];
      final def = excel.getDefaultSheet();
      if (def != null && def != sheetName) excel.delete(def);

      sheet.appendRow([xls.TextCellValue('Production Material Planner')]);
      sheet.appendRow([
        xls.TextCellValue('Branch'),
        xls.TextCellValue(_branchId == null ? 'All branches' : _branchName(_branchId)),
        xls.TextCellValue('Lead days'), xls.TextCellValue(_leadCtrl.text),
        xls.TextCellValue('Target cover'), xls.TextCellValue(_targetCtrl.text),
      ]);
      sheet.appendRow([xls.TextCellValue('')]);
      sheet.appendRow([
        xls.TextCellValue('Component'), xls.TextCellValue('SKU'), xls.TextCellValue('Branch'),
        xls.TextCellValue('Driven by'), xls.TextCellValue('Gross need'),
        xls.TextCellValue('Stock'), xls.TextCellValue('Negative stock'),
        xls.TextCellValue('Already ordered'), xls.TextCellValue('In production'),
        xls.TextCellValue('Net to buy'), xls.TextCellValue('Status'),
      ]);
      for (final r in _filtered) {
        sheet.appendRow([
          xls.TextCellValue('${r['component_name'] ?? ''}'),
          xls.TextCellValue('${r['component_sku'] ?? ''}'),
          xls.TextCellValue(_branchName(r['branch_id'] as String?)),
          xls.TextCellValue('${r['driven_by'] ?? ''}'),
          xls.DoubleCellValue(_num(r['gross_required'])),
          xls.DoubleCellValue(_num(r['comp_stock'])),
          xls.TextCellValue(r['comp_negative_stock'] == true ? 'YES' : ''),
          xls.DoubleCellValue(_num(r['comp_on_order'])),
          xls.DoubleCellValue(_num(r['comp_in_wip'])),
          xls.DoubleCellValue(_num(r['net_required'])),
          xls.TextCellValue('${r['status'] ?? ''}'),
        ]);
      }
      excel.save(fileName: 'production-material-plan-${_ymd(DateTime.now())}.xlsx');
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
    final list = _q.isEmpty
        ? widget.suppliers
        : widget.suppliers.where((s) =>
            (s['name'] as String? ?? '').toLowerCase().contains(_q.toLowerCase())).toList();
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
