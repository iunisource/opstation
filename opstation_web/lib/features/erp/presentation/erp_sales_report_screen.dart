import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Sales Report — all sales in a date range, from Sales Invoices and/or POS,
/// filterable by customer Category and Group, broken down Product-wise or
/// Customer-wise, with a post-load search and PDF/print.
class ErpSalesReportScreen extends ConsumerStatefulWidget {
  const ErpSalesReportScreen({super.key});
  @override
  ConsumerState<ErpSalesReportScreen> createState() => _ErpSalesReportScreenState();
}

class _ErpSalesReportScreenState extends ConsumerState<ErpSalesReportScreen> {
  bool _loading = true;
  bool _running = false;
  bool _ran = false;
  String? _orgId;

  // reference data
  final Map<String, Map<String, dynamic>> _customers = {}; // id -> row
  final Map<String, String> _productNames = {};
  final Map<String, String> _posCustomerNames = {};
  final Map<String, String> _sessionBranch = {}; // pos session -> branch_id
  List<Map<String, dynamic>> _branches = [];
  List<String> _categories = [];
  List<String> _groups = [];

  // filters
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _to = DateTime.now();
  String _source = 'both'; // both | invoice | pos
  String _branch = 'all';
  String _category = 'all';
  String _group = 'all';
  String _breakdown = 'product'; // product | customer

  // result
  List<Map<String, dynamic>> _rows = [];
  double _grandAmount = 0;
  double _grandQty = 0;
  int _docCount = 0;
  final _searchCtrl = TextEditingController();

  final _money = NumberFormat('#,##0');
  final _qtyFmt = NumberFormat('#,##0.##');

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
    _loadRefs();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  double _d(dynamic v) => v == null ? 0.0 : (v as num).toDouble();

  Future<void> _loadRefs() async {
    setState(() => _loading = true);
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    _orgId = orgId;
    try {
      final c = Supabase.instance.client;
      final custs = await c
          .from('customers')
          .select('id, shop_name, code, category, group_name')
          .eq('org_id', orgId);
      final prods = await c.from('products').select('id, name').eq('org_id', orgId);
      final branches = await c
          .from('branches')
          .select('id, name')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');

      final cats = <String>{};
      final grps = <String>{};
      _customers.clear();
      for (final r in custs) {
        _customers[r['id'] as String] = Map<String, dynamic>.from(r);
        final cat = (r['category'] as String?)?.trim();
        final grp = (r['group_name'] as String?)?.trim();
        if (cat != null && cat.isNotEmpty) cats.add(cat);
        if (grp != null && grp.isNotEmpty) grps.add(grp);
      }
      _productNames
        ..clear()
        ..addEntries(prods.map((p) => MapEntry(p['id'] as String, '${p['name']}')));

      // best-effort POS extras (walk-in customer names + session->branch)
      try {
        final pc = await c.from('pos_customers').select('id, name').eq('org_id', orgId);
        _posCustomerNames
          ..clear()
          ..addEntries(pc.map((p) => MapEntry(p['id'] as String, '${p['name']}')));
      } catch (_) {}
      try {
        final ss = await c.from('pos_sessions').select('id, branch_id').eq('org_id', orgId);
        _sessionBranch
          ..clear()
          ..addEntries(ss
              .where((s) => s['branch_id'] != null)
              .map((s) => MapEntry(s['id'] as String, s['branch_id'] as String)));
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _branches = List<Map<String, dynamic>>.from(branches);
        _categories = cats.toList()..sort();
        _groups = grps.toList()..sort();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Load failed: $e');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  bool _custPassesFilter(String? customerId) {
    if (_category == 'all' && _group == 'all') return true;
    final cust = customerId == null ? null : _customers[customerId];
    final cat = (cust?['category'] as String?)?.trim() ?? '';
    final grp = (cust?['group_name'] as String?)?.trim() ?? '';
    if (_category != 'all' && cat != _category) return false;
    if (_group != 'all' && grp != _group) return false;
    return true;
  }

  List<List<T>> _chunk<T>(List<T> list, int size) {
    final out = <List<T>>[];
    for (var i = 0; i < list.length; i += size) {
      out.add(list.sublist(i, i + size > list.length ? list.length : i + size));
    }
    return out;
  }

  Future<void> _run() async {
    if (_orgId == null) return;
    if (_to.isBefore(_from)) {
      _snack('"To" date is before "From" date.');
      return;
    }
    setState(() => _running = true);
    final c = Supabase.instance.client;
    final fromStr = _ymd(_from);
    final toStr = _ymd(_to);
    final toExclusive = _ymd(_to.add(const Duration(days: 1)));
    final productMode = _breakdown == 'product';
    // key -> aggregate
    final agg = <String, Map<String, dynamic>>{};

    void add(String key, String name, String sub, double qty, double amount) {
      final a = agg.putIfAbsent(
          key, () => {'name': name, 'sub': sub, 'qty': 0.0, 'amount': 0.0, 'count': 0});
      a['qty'] = (a['qty'] as double) + qty;
      a['amount'] = (a['amount'] as double) + amount;
    }

    void bumpCount(String key) {
      final a = agg[key];
      if (a != null) a['count'] = (a['count'] as int) + 1;
    }

    int docs = 0;
    try {
      // ───────── Sales Invoices ─────────
      if (_source == 'both' || _source == 'invoice') {
        var q = c
            .from('sales_invoices')
            .select('id, customer_id, branch_id, voucher_date, grand_total')
            .eq('org_id', _orgId!)
            .eq('is_voided', false)
            .gte('voucher_date', fromStr)
            .lte('voucher_date', toStr);
        if (_branch != 'all') q = q.eq('branch_id', _branch);
        final invs = await q;
        final kept = <Map<String, dynamic>>[];
        for (final inv in invs) {
          if (!_custPassesFilter(inv['customer_id'] as String?)) continue;
          kept.add(Map<String, dynamic>.from(inv));
        }
        docs += kept.length;

        if (productMode) {
          final ids = kept.map((e) => e['id'] as String).toList();
          for (final part in _chunk(ids, 300)) {
            if (part.isEmpty) continue;
            final items = await c
                .from('sales_invoice_items')
                .select('invoice_id, product_id, qty_delivered, line_total')
                .inFilter('invoice_id', part);
            for (final it in items) {
              final pid = it['product_id'] as String?;
              final key = pid ?? 'unknown';
              add(key, pid == null ? '(unknown product)' : (_productNames[pid] ?? pid),
                  'Invoice', _d(it['qty_delivered']), _d(it['line_total']));
            }
          }
        } else {
          for (final inv in kept) {
            final cid = inv['customer_id'] as String?;
            final key = cid ?? 'walkin';
            final cust = cid == null ? null : _customers[cid];
            add(
              key,
              cust == null ? '(no customer)' : '${cust['shop_name']}',
              cust == null ? '' : '${cust['code'] ?? ''}',
              0,
              _d(inv['grand_total']),
            );
            bumpCount(key);
          }
        }
      }

      // ───────── POS sales ─────────
      if (_source == 'both' || _source == 'pos') {
        final txAll = await c
            .from('pos_transactions')
            .select(
                'id, customer_id, pos_customer_id, total, transacted_at, transaction_type, reference_transaction_id, session_id')
            .eq('org_id', _orgId!)
            .gte('transacted_at', fromStr)
            .lt('transacted_at', toExclusive);
        final kept = <Map<String, dynamic>>[];
        for (final tx in txAll) {
          // sales only — skip returns
          if ('${tx['transaction_type']}'.toLowerCase() == 'return') continue;
          // branch scoping via session (if a specific branch is chosen)
          if (_branch != 'all') {
            final b = _sessionBranch[tx['session_id']];
            if (b != _branch) continue;
          }
          if (!_custPassesFilter(tx['customer_id'] as String?)) continue;
          kept.add(Map<String, dynamic>.from(tx));
        }
        docs += kept.length;

        if (productMode) {
          final ids = kept.map((e) => e['id'] as String).toList();
          for (final part in _chunk(ids, 300)) {
            if (part.isEmpty) continue;
            final items = await c
                .from('pos_transaction_items')
                .select(
                    'transaction_id, product_id, item_name, quantity, unit_price, discount, discount_type')
                .inFilter('transaction_id', part);
            for (final it in items) {
              final pid = it['product_id'] as String?;
              final qty = _d(it['quantity']);
              final gross = qty * _d(it['unit_price']);
              final disc = '${it['discount_type']}'.toLowerCase() == 'percent'
                  ? gross * _d(it['discount']) / 100.0
                  : _d(it['discount']);
              final name = pid != null
                  ? (_productNames[pid] ?? it['item_name'] ?? pid)
                  : (it['item_name'] ?? '(unknown product)');
              final key = pid ?? 'name:${it['item_name']}';
              add(key, '$name', 'POS', qty, gross - disc);
            }
          }
        } else {
          for (final tx in kept) {
            final cid = tx['customer_id'] as String?;
            final pcid = tx['pos_customer_id'] as String?;
            String key;
            String name;
            String sub;
            if (cid != null) {
              key = cid;
              final cust = _customers[cid];
              name = cust == null ? '(customer)' : '${cust['shop_name']}';
              sub = cust == null ? '' : '${cust['code'] ?? ''}';
            } else if (pcid != null) {
              key = 'pos:$pcid';
              name = _posCustomerNames[pcid] ?? 'POS customer';
              sub = 'POS';
            } else {
              key = 'pos:walkin';
              name = 'Walk-in';
              sub = 'POS';
            }
            add(key, name, sub, 0, _d(tx['total']));
            bumpCount(key);
          }
        }
      }

      final rows = agg.entries.map((e) => {'key': e.key, ...e.value}).toList()
        ..sort((a, b) => (b['amount'] as double).compareTo(a['amount'] as double));
      final grandAmt = rows.fold<double>(0, (s, r) => s + (r['amount'] as double));
      final grandQty = rows.fold<double>(0, (s, r) => s + (r['qty'] as double));

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _grandAmount = grandAmt;
        _grandQty = grandQty;
        _docCount = docs;
        _ran = true;
        _running = false;
        _searchCtrl.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      _snack('Report failed: $e');
    }
  }

  List<Map<String, dynamic>> get _visibleRows {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows.where((r) {
      return '${r['name']}'.toLowerCase().contains(q) ||
          '${r['sub']}'.toLowerCase().contains(q);
    }).toList();
  }

  // ───────────────────────────────────────────────── build
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Sales Report',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('Sales across invoices and POS for any period',
            style: TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        _filterBar(),
        const SizedBox(height: 16),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : !_ran
                  ? const Center(
                      child: Text('Set your filters and run the report.',
                          style: TextStyle(color: AppTheme.textSecondary)))
                  : _resultArea(),
        ),
      ]),
    );
  }

  Widget _filterBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _dateField('From', _from, (d) => setState(() => _from = d)),
        _dateField('To', _to, (d) => setState(() => _to = d)),
        _dropdown('Source', _source, const {
          'both': 'Invoices + POS',
          'invoice': 'Invoices only',
          'pos': 'POS only',
        }, (v) => setState(() => _source = v)),
        _dropdown('Branch', _branch, {
          'all': 'All branches',
          for (final b in _branches) b['id'] as String: '${b['name']}',
        }, (v) => setState(() => _branch = v)),
        _dropdown('Customer Category', _category, {
          'all': 'All categories',
          for (final c in _categories) c: c,
        }, (v) => setState(() => _category = v)),
        _dropdown('Customer Group', _group, {
          'all': 'All groups',
          for (final g in _groups) g: g,
        }, (v) => setState(() => _group = v)),
        _dropdown('Breakdown', _breakdown, const {
          'product': 'Product-wise',
          'customer': 'Customer-wise',
        }, (v) => setState(() => _breakdown = v)),
        ElevatedButton.icon(
          icon: _running
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_arrow, size: 18),
          label: Text(_running ? 'Running…' : 'Run report'),
          onPressed: _running ? null : _run,
        ),
      ]),
    );
  }

  Widget _dateField(String label, DateTime value, ValueChanged<DateTime> onPick) {
    return SizedBox(
      width: 160,
      child: InkWell(
        onTap: () async {
          final d = await showDatePicker(
            context: context,
            initialDate: value,
            firstDate: DateTime(2020),
            lastDate: DateTime(2100),
          );
          if (d != null) onPick(d);
        },
        child: InputDecorator(
          decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
          child: Text(DateFormat('d MMM y').format(value)),
        ),
      ),
    );
  }

  Widget _dropdown(String label, String value, Map<String, String> items,
      ValueChanged<String> onChanged) {
    return SizedBox(
      width: 190,
      child: DropdownButtonFormField<String>(
        value: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
        items: [
          for (final e in items.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) => onChanged(v ?? value),
      ),
    );
  }

  Widget _resultArea() {
    final rows = _visibleRows;
    final productMode = _breakdown == 'product';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Wrap(spacing: 18, runSpacing: 4, children: [
            _kv('Period', '${DateFormat('d MMM y').format(_from)} – ${DateFormat('d MMM y').format(_to)}'),
            _kv(productMode ? 'Products' : 'Customers', '${_rows.length}'),
            _kv('Documents', '$_docCount'),
            if (productMode) _kv('Total qty', _qtyFmt.format(_grandQty)),
            _kv('Total sales', _money.format(_grandAmount)),
          ]),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
          label: const Text('Print / PDF'),
          onPressed: rows.isEmpty ? null : _printPdf,
        ),
      ]),
      const SizedBox(height: 12),
      SizedBox(
        width: 360,
        child: TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: productMode ? 'Search product…' : 'Search customer…',
            prefixIcon: const Icon(Icons.search, size: 20),
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: _searchCtrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () => _searchCtrl.clear()),
          ),
        ),
      ),
      const SizedBox(height: 10),
      _tableHeader(productMode),
      const Divider(height: 1),
      Expanded(
        child: rows.isEmpty
            ? const Center(
                child: Text('No matching rows.',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _tableRow(i + 1, rows[i], productMode),
              ),
      ),
      const Divider(height: 1, thickness: 1),
      _totalsRow(productMode, rows),
    ]);
  }

  Widget _kv(String k, String v) => RichText(
        text: TextSpan(style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13), children: [
          TextSpan(text: '$k: '),
          TextSpan(text: v, style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _tableHeader(bool productMode) {
    const s = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        const SizedBox(width: 36, child: Text('#', style: s)),
        Expanded(flex: 4, child: Text(productMode ? 'Product' : 'Customer', style: s)),
        if (!productMode) const Expanded(flex: 2, child: Text('Cat / Group', style: s)),
        Expanded(
            flex: 2,
            child: Text(productMode ? 'Qty' : 'Orders', style: s, textAlign: TextAlign.right)),
        Expanded(flex: 2, child: Text('Amount', style: s, textAlign: TextAlign.right)),
        const SizedBox(
            width: 60, child: Text('%', style: s, textAlign: TextAlign.right)),
      ]),
    );
  }

  Widget _tableRow(int n, Map<String, dynamic> r, bool productMode) {
    final amount = r['amount'] as double;
    final pct = _grandAmount == 0 ? 0.0 : amount / _grandAmount * 100;
    final cust = productMode ? null : _customers[r['key']];
    final catGrp = cust == null
        ? '${r['sub']}'
        : [cust['category'], cust['group_name']].where((x) => x != null && '$x'.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [
        SizedBox(width: 36, child: Text('$n', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
        Expanded(
          flex: 4,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${r['name']}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            if (!productMode && '${r['sub']}'.isNotEmpty)
              Text('${r['sub']}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
        ),
        if (!productMode)
          Expanded(
            flex: 2,
            child: Text(catGrp,
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        Expanded(
          flex: 2,
          child: Text(
              productMode ? _qtyFmt.format(r['qty']) : '${r['count']}',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          flex: 2,
          child: Text(_money.format(amount),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          width: 60,
          child: Text('${pct.toStringAsFixed(1)}%',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ),
      ]),
    );
  }

  Widget _totalsRow(bool productMode, List<Map<String, dynamic>> rows) {
    final amt = rows.fold<double>(0, (s, r) => s + (r['amount'] as double));
    final qty = rows.fold<double>(0, (s, r) => s + (r['qty'] as double));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        const SizedBox(width: 36),
        const Expanded(flex: 4, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w800))),
        if (!productMode) const Expanded(flex: 2, child: SizedBox()),
        Expanded(
          flex: 2,
          child: Text(productMode ? _qtyFmt.format(qty) : '',
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
        Expanded(
          flex: 2,
          child: Text(_money.format(amt),
              textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 60),
      ]),
    );
  }

  // ───────────────────────────────────────────────── PDF
  Future<void> _printPdf() async {
    final productMode = _breakdown == 'product';
    final rows = _visibleRows;
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final doc = pw.Document();

    final srcLabel = {'both': 'Invoices + POS', 'invoice': 'Invoices', 'pos': 'POS'}[_source];
    final filterBits = <String>[
      'Source: $srcLabel',
      if (_branch != 'all')
        'Branch: ${_branches.firstWhere((b) => b['id'] == _branch, orElse: () => {'name': _branch})['name']}',
      if (_category != 'all') 'Category: $_category',
      if (_group != 'all') 'Group: $_group',
    ];

    final headers = productMode
        ? ['#', 'Product', 'Qty', 'Amount', '%']
        : ['#', 'Customer', 'Cat / Group', 'Orders', 'Amount', '%'];

    final data = <List<String>>[];
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final amount = r['amount'] as double;
      final pct = _grandAmount == 0 ? 0.0 : amount / _grandAmount * 100;
      if (productMode) {
        data.add([
          '${i + 1}',
          '${r['name']}',
          _qtyFmt.format(r['qty']),
          _money.format(amount),
          '${pct.toStringAsFixed(1)}%',
        ]);
      } else {
        final cust = _customers[r['key']];
        final catGrp = cust == null
            ? '${r['sub']}'
            : [cust['category'], cust['group_name']]
                .where((x) => x != null && '$x'.isNotEmpty)
                .join(' · ');
        data.add([
          '${i + 1}',
          '${r['name']}${'${r['sub']}'.isNotEmpty ? '  (${r['sub']})' : ''}',
          catGrp,
          '${r['count']}',
          _money.format(amount),
          '${pct.toStringAsFixed(1)}%',
        ]);
      }
    }
    final totalAmt = rows.fold<double>(0, (s, r) => s + (r['amount'] as double));
    final totalQty = rows.fold<double>(0, (s, r) => s + (r['qty'] as double));
    final totalRow = productMode
        ? ['', 'Total', _qtyFmt.format(totalQty), _money.format(totalAmt), '']
        : ['', 'Total', '', '', _money.format(totalAmt), ''];

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (ctx) => [
        if (org.isNotEmpty)
          pw.Text(org, style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        pw.Text('Sales Report — ${productMode ? 'Product-wise' : 'Customer-wise'}',
            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text(
            '${DateFormat('d MMM y').format(_from)} – ${DateFormat('d MMM y').format(_to)}   •   ${filterBits.join('   •   ')}',
            style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: headers,
          data: [...data, totalRow],
          headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 9),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          cellAlignments: productMode
              ? {0: pw.Alignment.centerLeft, 2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight}
              : {0: pw.Alignment.centerLeft, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight},
          rowDecoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5))),
        ),
        pw.SizedBox(height: 8),
        pw.Text('Total sales: ${_money.format(totalAmt)}',
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
      ],
    ));

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat f) async => doc.save(),
      name: 'sales-report-${_ymd(_from)}_${_ymd(_to)}.pdf',
    );
  }
}
