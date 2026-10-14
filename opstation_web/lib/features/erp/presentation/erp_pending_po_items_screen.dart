// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:excel/excel.dart' as xls;

import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart' show selectedBranchProvider;
import '../../auth/auth_controller.dart';
import 'package:opstation_web/core/pdf/pdf_output.dart';

/// Purchase → Pending PO Items.
/// Everything still to arrive on confirmed, open Purchase Orders, totalled per
/// item across all POs of a supplier (or every supplier). Short-closed /
/// fully received / voided POs are left out. Tap an item for its PO-wise split.
class ErpPendingPoItemsScreen extends ConsumerStatefulWidget {
  const ErpPendingPoItemsScreen({super.key});
  @override
  ConsumerState<ErpPendingPoItemsScreen> createState() => _ErpPendingPoItemsScreenState();
}

class _PoLine {
  final String poId, poNumber;
  final DateTime? poDate;
  final double ordered, received, rate;
  _PoLine(this.poId, this.poNumber, this.poDate, this.ordered, this.received, this.rate);
  double get pending => (ordered - received) > 0 ? ordered - received : 0;
}

class _Item {
  final String supplierId, supplierName, name, sku, uom;
  final List<_PoLine> lines = [];
  _Item(this.supplierId, this.supplierName, this.name, this.sku, this.uom);
  double get ordered => lines.fold(0.0, (a, l) => a + l.ordered);
  double get received => lines.fold(0.0, (a, l) => a + l.received);
  double get pending => lines.fold(0.0, (a, l) => a + l.pending);
  double get value => lines.fold(0.0, (a, l) => a + l.pending * l.rate);
  bool get missingRate => lines.any((l) => l.rate <= 0);
}

class _ErpPendingPoItemsScreenState extends ConsumerState<ErpPendingPoItemsScreen> {
  List<Map<String, dynamic>> _suppliers = [];
  List<Map<String, dynamic>> _branches = [];
  String? _supplierId; // null = all
  String _branchId = 'all';
  bool _includeDrafts = false;
  String _search = '';
  bool _loading = false;
  bool _hasRun = false;
  String? _error;
  List<_Item> _items = [];
  int _poCount = 0;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    final b = ref.read(selectedBranchProvider)?['id'] as String?;
    if (b != null) _branchId = b;
    _loadFilters().then((_) => _run());
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  Future<void> _loadFilters() async {
    final orgId = _orgId;
    if (orgId == null) return;
    final client = Supabase.instance.client;
    try {
      final s = await client.from('suppliers').select('id, name').eq('org_id', orgId).order('name');
      _suppliers = List<Map<String, dynamic>>.from(s);
    } catch (_) {}
    try {
      final b = await client.from('branches').select('id, name, is_virtual')
          .eq('org_id', orgId).eq('is_active', true).order('name');
      _branches = List<Map<String, dynamic>>.from(b).where((x) => x['is_virtual'] != true).toList();
    } catch (_) {}
    if (_branchId != 'all' && !_branches.any((b) => b['id'] == _branchId)) _branchId = 'all';
    if (mounted) setState(() {});
  }

  double _d(dynamic v) => v == null ? 0.0 : (v as num).toDouble();

  Future<void> _run() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final client = Supabase.instance.client;
      var q = client.from('purchase_orders')
          .select('id, voucher_number, voucher_date, status, is_locked, supplier_id, suppliers(name)')
          .eq('org_id', orgId)
          .isFilter('voided_at', null);
      if (_supplierId != null) q = q.eq('supplier_id', _supplierId!);
      if (_branchId != 'all') q = q.eq('branch_id', _branchId);
      if (!_includeDrafts) q = q.eq('is_locked', true);
      final pos = List<Map<String, dynamic>>.from(await q.limit(5000))
          // "received" = fully received or short-closed: nothing left to come.
          .where((p) => p['status'] != 'received')
          .toList();
      final poById = {for (final p in pos) p['id'] as String: p};

      final lines = <Map<String, dynamic>>[];
      final ids = poById.keys.toList();
      for (var i = 0; i < ids.length; i += 150) {
        final chunk = ids.sublist(i, i + 150 > ids.length ? ids.length : i + 150);
        final r = await client.from('purchase_order_items')
            .select('purchase_order_id, product_id, uom_id, quantity_ordered, quantity_received, unit_cost, description, products(name, sku, is_free_text), uoms(abbreviation)')
            .inFilter('purchase_order_id', chunk);
        lines.addAll(List<Map<String, dynamic>>.from(r));
      }

      final items = <String, _Item>{};
      final openPos = <String>{};
      for (final l in lines) {
        final ordered = _d(l['quantity_ordered']);
        final received = _d(l['quantity_received']);
        if (ordered - received <= 0.0000001) continue;
        final po = poById[l['purchase_order_id']];
        if (po == null) continue;
        openPos.add(po['id'] as String);
        final prod = (l['products'] as Map?) ?? const {};
        final freeText = prod['is_free_text'] == true;
        final desc = (l['description'] as String?)?.trim() ?? '';
        final name = freeText && desc.isNotEmpty ? desc : '${prod['name'] ?? 'Item'}';
        final uom = '${(l['uoms'] as Map?)?['abbreviation'] ?? ''}';
        final supId = '${po['supplier_id'] ?? ''}';
        final key = '$supId|${l['product_id']}|${l['uom_id']}|${freeText ? desc.toLowerCase() : ''}';
        final it = items.putIfAbsent(key, () => _Item(supId, '${(po['suppliers'] as Map?)?['name'] ?? '—'}',
            name, '${prod['sku'] ?? ''}', uom));
        it.lines.add(_PoLine(po['id'] as String, '${po['voucher_number'] ?? ''}',
            DateTime.tryParse('${po['voucher_date'] ?? ''}'), ordered, received, _d(l['unit_cost'])));
      }
      final list = items.values.toList()
        ..sort((a, b) {
          final s = a.supplierName.toLowerCase().compareTo(b.supplierName.toLowerCase());
          return s != 0 ? s : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      for (final it in list) {
        it.lines.sort((a, b) => (a.poDate ?? DateTime(2000)).compareTo(b.poDate ?? DateTime(2000)));
      }
      if (!mounted) return;
      setState(() { _items = list; _poCount = openPos.length; _loading = false; _hasRun = true; _expanded.clear(); });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _hasRun = true; _error = '$e'; _items = []; });
    }
  }

  // ── formatting ──────────────────────────────────────────────────────────
  final _qf = NumberFormat('#,##0.##');
  final _mf = NumberFormat('#,##0');
  String _q(double v) => _qf.format(v);
  String _m(double v) => _mf.format(v.round());
  String _date(DateTime? d) => d == null ? '' : DateFormat('d MMM yyyy').format(d);
  String _ascii(String s) => s
      .replaceAll('—', '-').replaceAll('–', '-').replaceAll('·', '-')
      .replaceAll(RegExp(r'[^\x20-\x7E]'), '');

  List<_Item> get _visible {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return _items.where((i) => '${i.name} ${i.sku} ${i.supplierName}'.toLowerCase().contains(q)).toList();
  }

  Map<String, List<_Item>> _bySupplier(List<_Item> list) {
    final m = <String, List<_Item>>{};
    for (final i in list) {
      (m[i.supplierId] ??= []).add(i);
    }
    return m;
  }

  String get _supLabel => _supplierId == null ? 'All suppliers'
      : '${_suppliers.firstWhere((s) => s['id'] == _supplierId, orElse: () => {'name': ''})['name']}';
  String get _branchLabel => _branchId == 'all' ? 'All branches'
      : '${_branches.firstWhere((b) => b['id'] == _branchId, orElse: () => {'name': ''})['name']}';

  // ── PDF / Excel ─────────────────────────────────────────────────────────
  Future<void> _pdf() async {
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final list = _visible;
    final groups = _bySupplier(list);
    final data = <List<String>>[];
    for (final g in groups.values) {
      if (_supplierId == null) {
        data.add([_ascii(g.first.supplierName), '', '', '', '', _m(g.fold(0.0, (a, i) => a + i.value))]);
      }
      for (final i in g) {
        data.add([
          '${_supplierId == null ? '   ' : ''}${_ascii(i.name)}${i.uom.isNotEmpty ? ' (${_ascii(i.uom)})' : ''}',
          _q(i.ordered), _q(i.received), _q(i.pending),
          _ascii(i.lines.map((l) => '${l.poNumber}: ${_q(l.pending)}').join(', ')),
          i.value > 0 ? _m(i.value) : '-',
        ]);
      }
    }
    final total = list.fold(0.0, (a, i) => a + i.value);
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (ctx) => [
        if (org.isNotEmpty) pw.Text(_ascii(org), style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        pw.Text('Pending PO Items', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text('Supplier: ${_ascii(_supLabel)}     |     Branch: ${_ascii(_branchLabel)}     |     As of ${_date(DateTime.now())}',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: ['Item', 'Ordered', 'Received', 'Pending', 'POs', 'Value'],
          data: data,
          headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 8.5),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          columnWidths: {
            0: const pw.FlexColumnWidth(4), 1: const pw.FlexColumnWidth(1.4), 2: const pw.FlexColumnWidth(1.4),
            3: const pw.FlexColumnWidth(1.4), 4: const pw.FlexColumnWidth(3.4), 5: const pw.FlexColumnWidth(1.6),
          },
          cellAlignments: {
            0: pw.Alignment.centerLeft, 1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight,
            3: pw.Alignment.centerRight, 4: pw.Alignment.centerLeft, 5: pw.Alignment.centerRight,
          },
        ),
        pw.SizedBox(height: 8),
        pw.Text('Pending value (at PO rates): Rs ${_m(total)}',
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
      ],
    ));
    await outputPdf(await doc.save(), 'Pending PO Items');
  }

  void _excel() {
    try {
      final excel = xls.Excel.createExcel();
      final sheet = excel[excel.getDefaultSheet() ?? 'Sheet1'];
      sheet.appendRow([xls.TextCellValue('Pending PO Items')]);
      sheet.appendRow([xls.TextCellValue('Supplier'), xls.TextCellValue(_supLabel),
        xls.TextCellValue('Branch'), xls.TextCellValue(_branchLabel),
        xls.TextCellValue('As of'), xls.TextCellValue(_date(DateTime.now()))]);
      sheet.appendRow([xls.TextCellValue('')]);
      sheet.appendRow(['Supplier', 'Item', 'SKU', 'Unit', 'PO', 'PO date', 'Ordered', 'Received', 'Pending', 'Rate', 'Pending value']
          .map((h) => xls.TextCellValue(h)).toList());
      for (final i in _visible) {
        for (final l in i.lines) {
          sheet.appendRow([
            xls.TextCellValue(i.supplierName), xls.TextCellValue(i.name), xls.TextCellValue(i.sku),
            xls.TextCellValue(i.uom), xls.TextCellValue(l.poNumber), xls.TextCellValue(_date(l.poDate)),
            xls.DoubleCellValue(l.ordered), xls.DoubleCellValue(l.received), xls.DoubleCellValue(l.pending),
            xls.DoubleCellValue(l.rate), xls.DoubleCellValue(l.pending * l.rate),
          ]);
        }
      }
      excel.save(fileName: 'pending-po-items-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.xlsx');
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Excel export failed: $e')));
    }
  }

  // ── UI ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 700;
    final list = _visible;
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(narrow ? 16 : 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Pending PO Items', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
          if (_hasRun && list.isNotEmpty) ...[
            IconButton(onPressed: _pdf, tooltip: 'Print / PDF', icon: const Icon(Icons.picture_as_pdf_outlined)),
            IconButton(onPressed: _excel, tooltip: 'Export Excel', icon: const Icon(Icons.grid_on_outlined)),
          ],
          IconButton(onPressed: _loading ? null : _run, tooltip: 'Refresh', icon: const Icon(Icons.refresh)),
        ]),
        const Text('What is still to arrive on confirmed, open Purchase Orders — totalled per item.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 14),
        _filters(),
        const SizedBox(height: 14),
        if (_hasRun && _error == null && _items.isNotEmpty) ...[
          _summary(list),
          const SizedBox(height: 14),
        ],
        Expanded(child: _results(list)),
      ]),
    );
  }

  Widget _filters() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border)),
      child: Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(width: 240, child: DropdownButtonFormField<String?>(
          value: _supplierId, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Supplier', isDense: true),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('All suppliers')),
            for (final s in _suppliers)
              DropdownMenuItem<String?>(value: s['id'] as String, child: Text('${s['name'] ?? ''}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) { setState(() => _supplierId = v); _run(); },
        )),
        SizedBox(width: 200, child: DropdownButtonFormField<String>(
          value: _branchId, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Branch', isDense: true),
          items: [
            const DropdownMenuItem(value: 'all', child: Text('All branches')),
            for (final b in _branches)
              DropdownMenuItem(value: b['id'] as String, child: Text('${b['name'] ?? ''}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) { setState(() => _branchId = v ?? 'all'); _run(); },
        )),
        SizedBox(width: 220, child: TextField(
          decoration: const InputDecoration(hintText: 'Search item…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
          onChanged: (v) => setState(() => _search = v),
        )),
        FilterChip(
          label: const Text('Include unconfirmed (draft) POs'),
          selected: _includeDrafts,
          onSelected: (v) { setState(() => _includeDrafts = v); _run(); },
        ),
      ]),
    );
  }

  Widget _summary(List<_Item> list) {
    final value = list.fold(0.0, (a, i) => a + i.value);
    final vendors = list.map((i) => i.supplierId).toSet().length;
    final pos = list.expand((i) => i.lines.map((l) => l.poId)).toSet().length;
    final noRate = list.where((i) => i.missingRate).length;
    Widget tile(String label, String value, {String? hint}) => Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        if (hint != null) Text(hint, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
      ]),
    );
    return Wrap(spacing: 10, runSpacing: 10, children: [
      if (_supplierId == null) tile('Suppliers', '$vendors'),
      tile('Open POs', '$pos'),
      tile('Items pending', '${list.length}'),
      tile('Pending value', 'Rs ${_m(value)}', hint: noRate > 0 ? '$noRate item${noRate == 1 ? '' : 's'} without a PO rate' : 'at PO rates'),
    ]);
  }

  Widget _results(List<_Item> list) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text('Could not load: ${_error!.split('\n').first}',
          textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.danger)));
    }
    if (!_hasRun) return const SizedBox.shrink();
    if (list.isEmpty) {
      return Center(child: Text(_items.isEmpty
          ? 'Nothing pending — every confirmed PO for these filters has been fully received.'
          : 'No items match "$_search".',
          textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSecondary)));
    }
    final groups = _bySupplier(list);
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border)),
      child: ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
        for (final g in groups.values) ...[
          if (_supplierId == null)
            Container(
              color: AppTheme.background,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(children: [
                Expanded(child: Text(g.first.supplierName, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800))),
                Text('${g.length} item${g.length == 1 ? '' : 's'} · Rs ${_m(g.fold(0.0, (a, i) => a + i.value))}',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
              ]),
            ),
          _header(),
          for (final i in g) _row(i),
        ],
      ]),
    );
  }

  Widget _header() {
    const st = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Row(children: [
        Expanded(flex: 5, child: Text('Item', style: st)),
        Expanded(flex: 2, child: Text('Ordered', textAlign: TextAlign.right, style: st)),
        Expanded(flex: 2, child: Text('Received', textAlign: TextAlign.right, style: st)),
        Expanded(flex: 2, child: Text('Pending', textAlign: TextAlign.right, style: st)),
        Expanded(flex: 2, child: Text('Value', textAlign: TextAlign.right, style: st)),
        SizedBox(width: 28),
      ]),
    );
  }

  Widget _row(_Item i) {
    final key = '${i.supplierId}|${i.name}|${i.uom}|${i.sku}';
    final open = _expanded.contains(key);
    final unit = i.uom.isNotEmpty ? ' ${i.uom}' : '';
    return Column(children: [
      const Divider(height: 1),
      InkWell(
        onTap: () => setState(() => open ? _expanded.remove(key) : _expanded.add(key)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
          child: Row(children: [
            Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              Text('${i.sku.isNotEmpty ? '${i.sku} · ' : ''}${i.lines.length} PO${i.lines.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ])),
            Expanded(flex: 2, child: Text(_q(i.ordered), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
            Expanded(flex: 2, child: Text(_q(i.received), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
            Expanded(flex: 2, child: Text('${_q(i.pending)}$unit', textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: AppTheme.primary))),
            Expanded(flex: 2, child: Text(i.value > 0 ? _m(i.value) : '—', textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13))),
            SizedBox(width: 28, child: Icon(open ? Icons.expand_less : Icons.expand_more, size: 18, color: AppTheme.textSecondary)),
          ]),
        ),
      ),
      if (open)
        Container(
          color: AppTheme.primary.withOpacity(0.03),
          padding: const EdgeInsets.fromLTRB(32, 4, 16, 8),
          child: Column(children: [
            for (final l in i.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(flex: 5, child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                    InkWell(
                      onTap: () => context.go('/erp/purchase?focus=${l.poId}'),
                      child: Text(l.poNumber, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700,
                          color: AppTheme.primary, decoration: TextDecoration.underline)),
                    ),
                    Text(_date(l.poDate), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                    if (l.rate > 0) Text('@ ${_qf.format(l.rate)}', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                  ])),
                  Expanded(flex: 2, child: Text(_q(l.ordered), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
                  Expanded(flex: 2, child: Text(_q(l.received), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
                  Expanded(flex: 2, child: Text(_q(l.pending), textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  Expanded(flex: 2, child: Text(l.rate > 0 ? _m(l.pending * l.rate) : '—', textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12))),
                  const SizedBox(width: 28),
                ]),
              ),
          ]),
        ),
    ]);
  }
}
