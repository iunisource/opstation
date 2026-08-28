import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/saving_overlay.dart';
import '../../auth/auth_controller.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../core/widgets/responsive.dart';

/// Dispatch Summary — what left the warehouse (Delivery Orders) over a period,
/// summarised customer-wise and product-wise. Quantities only: DO lines carry
/// dispatched quantity; pricing happens at the invoice, not the dispatch.
class ErpDispatchSummaryScreen extends ConsumerStatefulWidget {
  const ErpDispatchSummaryScreen({super.key});
  @override
  ConsumerState<ErpDispatchSummaryScreen> createState() => _ErpDispatchSummaryScreenState();
}

class _ErpDispatchSummaryScreenState extends ConsumerState<ErpDispatchSummaryScreen> {
  bool _loading = true;
  DateTime _from = DateTime.now().subtract(const Duration(days: 30));
  DateTime _to = DateTime.now();
  String _view = 'customer'; // customer | product
  String _branch = 'all';
  String _search = '';

  List<Map<String, dynamic>> _branches = [];
  final Map<String, Map<String, dynamic>> _productMap = {}; // id -> {name, sku, uom}
  List<Map<String, dynamic>> _lines = []; // raw dispatched lines in range

  final _qtyFmt = NumberFormat('#,##0.##');

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final res = await Future.wait([
        client.from('branches').select('id, name').eq('org_id', orgId).eq('is_active', true).order('name'),
        client.from('products').select('id, name, sku, base_uom_id').eq('org_id', orgId).limit(20000),
        client.from('uoms').select('id, abbreviation').eq('org_id', orgId),
      ]);
      final uomMap = {for (final u in res[2] as List) u['id'] as String: (u['abbreviation'] as String? ?? '')};
      _productMap.clear();
      for (final p in res[1] as List) {
        _productMap[p['id'] as String] = {
          'name': p['name'] ?? '', 'sku': p['sku'] ?? '', 'uom': uomMap[p['base_uom_id']] ?? '',
        };
      }
      _branches = List<Map<String, dynamic>>.from(res[0] as List);
    } catch (_) {}
    await _load();
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      var q = client
          .from('delivery_order_items')
          .select('qty_delivered, is_foc, product_id, delivery_order_id, '
              'delivery_orders!inner(voucher_number, voucher_date, customer_id, branch_id, is_voided, status, org_id, customers(shop_name, code))')
          .eq('delivery_orders.org_id', orgId)
          .gte('delivery_orders.voucher_date', _ymd(_from))
          .lte('delivery_orders.voucher_date', _ymd(_to));
      if (_branch != 'all') q = q.eq('delivery_orders.branch_id', _branch);
      final res = await q;
      final rows = <Map<String, dynamic>>[];
      for (final r in res as List) {
        final doh = r['delivery_orders'] as Map<String, dynamic>?;
        if (doh == null) continue;
        if (doh['is_voided'] == true) continue;
        if ((doh['status'] as String?) == 'cancelled') continue;
        final qty = (r['qty_delivered'] as num?)?.toDouble() ?? 0;
        if (qty <= 0) continue;
        rows.add({
          'qty': qty,
          'is_foc': r['is_foc'] == true,
          'product_id': r['product_id'] as String?,
          'do_id': r['delivery_order_id'] as String?,
          'customer_id': doh['customer_id'] as String?,
          'customer_name': (doh['customers'] as Map?)?['shop_name'] as String? ?? 'Walk-in',
          'customer_code': (doh['customers'] as Map?)?['code'] as String? ?? '',
        });
      }
      if (!mounted) return;
      setState(() { _lines = rows; _loading = false; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError('Could not load dispatch summary', e))));
    }
  }

  // Aggregations -----------------------------------------------------------
  List<Map<String, dynamic>> get _customerRows {
    final Map<String, Map<String, dynamic>> m = {};
    for (final r in _lines) {
      final key = (r['customer_id'] as String?) ?? 'walkin';
      final a = m.putIfAbsent(key, () => {
            'name': r['customer_name'], 'code': r['customer_code'],
            'qty': 0.0, 'foc': 0.0, 'dos': <String>{}, 'prods': <String>{},
          });
      a['qty'] = (a['qty'] as double) + (r['qty'] as double);
      if (r['is_foc'] == true) a['foc'] = (a['foc'] as double) + (r['qty'] as double);
      if (r['do_id'] != null) (a['dos'] as Set).add(r['do_id']);
      if (r['product_id'] != null) (a['prods'] as Set).add(r['product_id']);
    }
    final rows = m.values.map((a) => {
          'name': a['name'], 'code': a['code'],
          'qty': a['qty'], 'foc': a['foc'],
          'dos': (a['dos'] as Set).length, 'prods': (a['prods'] as Set).length,
        }).toList()
      ..sort((x, y) => (y['qty'] as double).compareTo(x['qty'] as double));
    return _applySearch(rows, (r) => '${r['name']} ${r['code']}');
  }

  List<Map<String, dynamic>> get _productRows {
    final Map<String, Map<String, dynamic>> m = {};
    for (final r in _lines) {
      final key = (r['product_id'] as String?) ?? 'unknown';
      final pm = _productMap[key] ?? const {};
      final a = m.putIfAbsent(key, () => {
            'name': pm['name'] ?? '(unknown)', 'sku': pm['sku'] ?? '', 'uom': pm['uom'] ?? '',
            'qty': 0.0, 'foc': 0.0, 'custs': <String>{}, 'dos': <String>{},
          });
      a['qty'] = (a['qty'] as double) + (r['qty'] as double);
      if (r['is_foc'] == true) a['foc'] = (a['foc'] as double) + (r['qty'] as double);
      if (r['customer_id'] != null) (a['custs'] as Set).add(r['customer_id']);
      if (r['do_id'] != null) (a['dos'] as Set).add(r['do_id']);
    }
    final rows = m.values.map((a) => {
          'name': a['name'], 'sku': a['sku'], 'uom': a['uom'],
          'qty': a['qty'], 'foc': a['foc'],
          'custs': (a['custs'] as Set).length, 'dos': (a['dos'] as Set).length,
        }).toList()
      ..sort((x, y) => (y['qty'] as double).compareTo(x['qty'] as double));
    return _applySearch(rows, (r) => '${r['name']} ${r['sku']}');
  }

  List<Map<String, dynamic>> _applySearch(List<Map<String, dynamic>> rows, String Function(Map<String, dynamic>) text) {
    if (_search.trim().isEmpty) return rows;
    final q = _search.toLowerCase();
    return rows.where((r) => text(r).toLowerCase().contains(q)).toList();
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context, firstDate: DateTime(2020), lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (r != null) { setState(() { _from = r.start; _to = r.end; }); _load(); }
  }

  // PDF --------------------------------------------------------------------
  Future<void> _pdf() async {
    final productMode = _view == 'product';
    final rows = productMode ? _productRows : _customerRows;
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final branchName = _branch == 'all' ? 'All branches' : (_branches.firstWhere((b) => b['id'] == _branch, orElse: () => {'name': _branch})['name'] as String);
    final doc = pw.Document();

    final headers = productMode
        ? ['#', 'Product', 'SKU', 'UOM', 'Qty', 'FOC', 'Customers']
        : ['#', 'Customer', 'Code', 'DOs', 'Products', 'Qty', 'FOC'];
    final data = <List<String>>[];
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (productMode) {
        data.add(['${i + 1}', '${r['name']}', '${r['sku']}', '${r['uom']}', _qtyFmt.format(r['qty']), _qtyFmt.format(r['foc']), '${r['custs']}']);
      } else {
        data.add(['${i + 1}', '${r['name']}', '${r['code']}', '${r['dos']}', '${r['prods']}', _qtyFmt.format(r['qty']), _qtyFmt.format(r['foc'])]);
      }
    }
    final totalQty = rows.fold<double>(0, (s, r) => s + (r['qty'] as double));
    final totalFoc = rows.fold<double>(0, (s, r) => s + (r['foc'] as double));
    final totalRow = productMode
        ? ['', 'Total', '', '', _qtyFmt.format(totalQty), _qtyFmt.format(totalFoc), '']
        : ['', 'Total', '', '', '', _qtyFmt.format(totalQty), _qtyFmt.format(totalFoc)];

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (ctx) => [
        if (org.isNotEmpty) pw.Text(org, style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        pw.Text('Dispatch Summary - ${productMode ? 'Product-wise' : 'Customer-wise'}', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text('${DateFormat('d MMM y').format(_from)} to ${DateFormat('d MMM y').format(_to)}     |     $branchName     |     Based on Delivery Orders (dispatched qty)', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: headers,
          data: [...data, totalRow],
          headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 9),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          cellAlignments: productMode
              ? {0: pw.Alignment.centerLeft, 4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight, 6: pw.Alignment.centerRight}
              : {0: pw.Alignment.centerLeft, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight, 6: pw.Alignment.centerRight},
          rowDecoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5))),
        ),
        pw.SizedBox(height: 8),
        pw.Text('Total dispatched: ${_qtyFmt.format(totalQty)} (incl. FOC ${_qtyFmt.format(totalFoc)})', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
      ],
    ));
    await Printing.layoutPdf(onLayout: (PdfPageFormat f) async => doc.save(), name: 'dispatch-summary-${_ymd(_from)}_${_ymd(_to)}.pdf');
  }

  @override
  Widget build(BuildContext context) {
    final productMode = _view == 'product';
    final rows = productMode ? _productRows : _customerRows;
    final totalQty = rows.fold<double>(0, (s, r) => s + (r['qty'] as double));
    final totalFoc = rows.fold<double>(0, (s, r) => s + (r['foc'] as double));

    return Container(
      color: AppTheme.background,
      child: Column(children: [
        // Header + controls
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.local_shipping_outlined, color: AppTheme.primary),
              const SizedBox(width: 10),
              const Text('Dispatch Summary', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const Spacer(),
              OutlinedButton.icon(onPressed: rows.isEmpty ? null : _pdf, icon: const Icon(Icons.picture_as_pdf_outlined, size: 16), label: const Text('PDF / Print')),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              OutlinedButton.icon(onPressed: _pickRange, icon: const Icon(Icons.event, size: 16), label: Text('${DateFormat('d MMM').format(_from)} – ${DateFormat('d MMM y').format(_to)}')),
              // View toggle
              Container(
                decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _viewTab('customer', 'Customer-wise', Icons.store_outlined),
                  _viewTab('product', 'Product-wise', Icons.inventory_2_outlined),
                ]),
              ),
              // Branch
              SizedBox(width: 200, child: DropdownButtonFormField<String>(
                value: _branch,
                isDense: true,
                decoration: const InputDecoration(labelText: 'Branch', isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('All branches', style: TextStyle(fontSize: 13))),
                  ..._branches.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String? ?? '-', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis))),
                ],
                onChanged: (v) { setState(() => _branch = v ?? 'all'); _load(); },
              )),
              SizedBox(width: 220, child: TextField(
                decoration: InputDecoration(hintText: productMode ? 'Search product...' : 'Search customer...', prefixIcon: const Icon(Icons.search, size: 18), isDense: true, border: const OutlineInputBorder()),
                onChanged: (v) => setState(() => _search = v),
              )),
            ]),
          ]),
        ),
        // Totals strip
        if (!_loading)
          Container(
            width: double.infinity,
            color: AppTheme.primary.withOpacity(0.05),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              '${rows.length} ${productMode ? 'product(s)' : 'customer(s)'}   ·   Total dispatched ${_qtyFmt.format(totalQty)} units   ·   FOC ${_qtyFmt.format(totalFoc)}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: BrandSpinner())
              : rows.isEmpty
                  ? const Center(child: Text('No dispatches in this period.', style: TextStyle(color: AppTheme.textSecondary)))
                  : productMode ? _productTable(rows) : _customerTable(rows),
        ),
      ]),
    );
  }

  Widget _viewTab(String value, String label, IconData ic) {
    final active = _view == value;
    return GestureDetector(
      onTap: () => setState(() => _view = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(color: active ? AppTheme.primary : Colors.transparent, borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ic, size: 15, color: active ? Colors.white : AppTheme.textSecondary),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: active ? Colors.white : AppTheme.textSecondary)),
        ]),
      ),
    );
  }

  Widget _customerTable(List<Map<String, dynamic>> rows) {
    return HScrollOnNarrow(minWidth: 640, child: ListView(padding: const EdgeInsets.all(16), children: [
      _tableHeader(const ['Customer', 'DOs', 'Products', 'Qty', 'FOC'], const [4, 1, 1, 2, 1]),
      ...rows.map((r) => _row([
            _cell('${r['name']}', flex: 4, sub: '${r['code']}'),
            _cell('${r['dos']}', flex: 1, right: true),
            _cell('${r['prods']}', flex: 1, right: true),
            _cell(_qtyFmt.format(r['qty']), flex: 2, right: true, bold: true),
            _cell(_qtyFmt.format(r['foc']), flex: 1, right: true),
          ])),
    ]));
  }

  Widget _productTable(List<Map<String, dynamic>> rows) {
    return HScrollOnNarrow(minWidth: 680, child: ListView(padding: const EdgeInsets.all(16), children: [
      _tableHeader(const ['Product', 'SKU', 'UOM', 'Qty', 'FOC', 'Cust.'], const [5, 2, 1, 2, 1, 1]),
      ...rows.map((r) => _row([
            _cell('${r['name']}', flex: 5),
            _cell('${r['sku']}', flex: 2),
            _cell('${r['uom']}', flex: 1),
            _cell(_qtyFmt.format(r['qty']), flex: 2, right: true, bold: true),
            _cell(_qtyFmt.format(r['foc']), flex: 1, right: true),
            _cell('${r['custs']}', flex: 1, right: true),
          ])),
    ]));
  }

  Widget _tableHeader(List<String> labels, List<int> flexes) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(6)),
      child: Row(children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(flex: flexes[i], child: Text(labels[i], textAlign: i >= 3 ? TextAlign.right : TextAlign.left, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
      ]),
    );
  }

  Widget _row(List<Widget> cells) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border, width: 0.5))),
        child: Row(children: cells),
      );

  Widget _cell(String text, {int flex = 1, bool right = false, bool bold = false, String? sub}) {
    return Expanded(
      flex: flex,
      child: Column(crossAxisAlignment: right ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
        Text(text, style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
        if (sub != null && sub.isNotEmpty) Text(sub, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ]),
    );
  }
}
