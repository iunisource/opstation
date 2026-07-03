import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'dart:html' as html;
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class ErpMarginReportScreen extends ConsumerStatefulWidget {
  const ErpMarginReportScreen({super.key});
  @override
  ConsumerState<ErpMarginReportScreen> createState() => _State();
}

class _State extends ConsumerState<ErpMarginReportScreen> {
  // filters
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _to = DateTime.now();
  String? _branchId;
  String? _customerId; String _customerLabel = '';
  String? _productId; String _productLabel = '';
  String? _group;
  String? _mainGroup;
  String? _subGroup;

  // option lists
  List<Map<String, dynamic>> _branches = [];
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _products = [];
  List<String> _groups = [];
  List<String> _mainGroups = [];
  List<String> _subGroups = [];
  String _userName = '';

  // results
  List<Map<String, dynamic>> _rows = [];
  bool _running = false;
  bool _hasRun = false;
  String _search = '';
  String _sortKey = '';
  bool _sortAsc = true;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  static final _money = NumberFormat('#,##0.00');
  static String _fmtMoney(num? v) => _money.format(v ?? 0);
  static String _fmtQty(num? v) {
    final d = (v ?? 0).toDouble();
    if (d == d.roundToDouble()) return d.toStringAsFixed(0);
    return d.toString();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadBranches(); _loadGroups(); _loadCustomers(); _loadProducts(); _loadUserName();
    });
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadUserName() async {
    final uid = ref.read(currentUserProvider)?.id;
    if (uid == null) return;
    try {
      final row = await Supabase.instance.client.from('users').select('name').eq('id', uid).maybeSingle();
      if (mounted && row != null) setState(() => _userName = (row['name'] as String?) ?? '');
    } catch (_) {}
  }

  Future<void> _loadBranches() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 400)); if (mounted) _loadBranches(); return; }
    try {
      final rows = await Supabase.instance.client.from('branches').select('id, name').eq('org_id', orgId).order('name');
      if (mounted) setState(() => _branches = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  Future<void> _loadGroups() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('product_taxonomies')
          .select('taxonomy_type, name').eq('org_id', orgId)
          .inFilter('taxonomy_type', ['group', 'main_group', 'sub_group']).order('name');
      final g = <String>[]; final mg = <String>[]; final sg = <String>[];
      for (final r in List<Map<String, dynamic>>.from(rows)) {
        final n = (r['name'] as String?)?.trim() ?? '';
        if (n.isEmpty) continue;
        final t = r['taxonomy_type'];
        if (t == 'group') { if (!g.contains(n)) g.add(n); }
        else if (t == 'sub_group') { if (!sg.contains(n)) sg.add(n); }
        else { if (!mg.contains(n)) mg.add(n); }
      }
      if (mounted) setState(() { _groups = g; _mainGroups = mg; _subGroups = sg; });
    } catch (_) {}
  }

  Future<void> _loadCustomers() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final List<Map<String, dynamic>> all = [];
      int from = 0; const page = 1000;
      while (true) {
        final rows = await Supabase.instance.client.from('customers')
            .select('id, shop_name, code').eq('org_id', orgId).order('shop_name').range(from, from + page - 1);
        final list = List<Map<String, dynamic>>.from(rows);
        all.addAll(list);
        if (list.length < page) break;
        from += page; if (from > 50000) break;
      }
      if (mounted) setState(() => _customers = all.map((c) => {
        'id': c['id'],
        'label': "${c['shop_name'] ?? ''}${(c['code'] != null && (c['code'] as String).isNotEmpty) ? ' (${c['code']})' : ''}",
      }).toList());
    } catch (_) {}
  }

  Future<void> _loadProducts() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final List<Map<String, dynamic>> all = [];
      int from = 0; const page = 1000;
      while (true) {
        final rows = await Supabase.instance.client.from('products')
            .select('id, name, sku').eq('org_id', orgId).eq('is_active', true).order('name').range(from, from + page - 1);
        final list = List<Map<String, dynamic>>.from(rows);
        all.addAll(list);
        if (list.length < page) break;
        from += page; if (from > 100000) break;
      }
      if (mounted) setState(() => _products = all.map((p) => {
        'id': p['id'],
        'label': "${p['sku'] != null && (p['sku'] as String).isNotEmpty ? '${p['sku']} — ' : ''}${p['name'] ?? ''}",
      }).toList());
    } catch (_) {}
  }

  List<Map<String, dynamic>> _filter(List<Map<String, dynamic>> src, String q) {
    if (q.isEmpty) return src.take(60).toList();
    final ql = q.toLowerCase();
    return src.where((e) => (e['label'] as String).toLowerCase().contains(ql)).take(200).toList();
  }

  Future<void> _pickDate(bool isFrom) async {
    final init = isFrom ? _from : _to;
    final picked = await showDatePicker(context: context, initialDate: init, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked != null) setState(() { if (isFrom) _from = picked; else _to = picked; });
  }

  void _reset() {
    setState(() {
      _from = DateTime(DateTime.now().year, DateTime.now().month, 1);
      _to = DateTime.now();
      _branchId = null; _customerId = null; _customerLabel = '';
      _productId = null; _productLabel = ''; _group = null; _mainGroup = null; _subGroup = null;
      _rows = []; _hasRun = false; _search = '';
    });
  }

  Future<void> _run() async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return; }
    if (_to.isBefore(_from)) { _snack('"To" date is before "From" date'); return; }
    setState(() => _running = true);
    try {
      final res = await Supabase.instance.client.rpc('rpc_margin_report', params: {
        'p_org': orgId,
        'p_from': DateFormat('yyyy-MM-dd').format(_from),
        'p_to': DateFormat('yyyy-MM-dd').format(_to),
        'p_branch': _branchId,
        'p_customer': _customerId,
        'p_product': _productId,
        'p_group': _group,
        'p_main_group': _mainGroup,
        'p_sub_group': _subGroup,
      });
      final list = List<Map<String, dynamic>>.from((res as List?) ?? const []);
      if (mounted) setState(() { _rows = list; _hasRun = true; _running = false; });
    } catch (e) {
      if (mounted) { _snack('Report failed: $e'); setState(() => _running = false); }
    }
  }

  List<Map<String, dynamic>> get _visible {
    var out = _search.isEmpty ? List<Map<String, dynamic>>.from(_rows) : _rows.where((r) =>
      (r['product']?.toString().toLowerCase().contains(_search.toLowerCase()) ?? false) ||
      (r['sku']?.toString().toLowerCase().contains(_search.toLowerCase()) ?? false) ||
      (r['party']?.toString().toLowerCase().contains(_search.toLowerCase()) ?? false) ||
      (r['sale_number']?.toString().toLowerCase().contains(_search.toLowerCase()) ?? false)
    ).toList();
    if (_sortKey.isNotEmpty) {
      final dir = _sortAsc ? 1 : -1;
      out.sort((a, b) {
        final av = a[_sortKey]; final bv = b[_sortKey];
        int c;
        if (av is num && bv is num) { c = av.compareTo(bv); }
        else { c = (av?.toString() ?? '').toLowerCase().compareTo((bv?.toString() ?? '').toLowerCase()); }
        return c * dir;
      });
    }
    return out;
  }

  void _toggleSort(String key) {
    setState(() {
      if (_sortKey != key) { _sortKey = key; _sortAsc = true; }
      else if (_sortAsc) { _sortAsc = false; }
      else { _sortKey = ''; _sortAsc = true; }
    });
  }

  Widget _sortHeader(String label, String key, {bool right = false}) {
    final active = _sortKey == key;
    return InkWell(
      onTap: () => _toggleSort(key),
      child: Row(
        mainAxisAlignment: right ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(child: Text(label, textAlign: right ? TextAlign.right : TextAlign.left,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          if (active) Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: AppTheme.textSecondary),
        ],
      ),
    );
  }

  // ---------- totals ----------
  double get _totQty => _visible.fold(0.0, (s, r) => s + (r['qty'] as num? ?? 0));
  double get _totAmount => _visible.fold(0.0, (s, r) => s + (r['amount'] as num? ?? 0));
  double get _totCost => _visible.fold(0.0, (s, r) => s + (r['cost_amount'] as num? ?? 0));
  double get _totMargin => _visible.fold(0.0, (s, r) => s + (r['margin'] as num? ?? 0));

  String get _periodLabel => '${DateFormat('dd/MM/yyyy').format(_from)} – ${DateFormat('dd/MM/yyyy').format(_to)}';

  String _filterSummary() {
    final parts = <String>['Period: $_periodLabel'];
    if (_branchId != null) parts.add('Branch: ${_branches.firstWhere((b) => b['id'] == _branchId, orElse: () => {'name': _branchId})['name']}');
    if (_customerLabel.isNotEmpty) parts.add('Customer: $_customerLabel');
    if (_productLabel.isNotEmpty) parts.add('Product: $_productLabel');
    if (_group != null) parts.add('Group: $_group');
    if (_subGroup != null) parts.add('Sub Group: $_subGroup');
    if (_mainGroup != null) parts.add('Main Group: $_mainGroup');
    return parts.join('  •  ');
  }

  // ---------- exports ----------
  String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  void _exportPdf() {
    final rows = _visible;
    final b = StringBuffer();
    b.write('<!doctype html><html><head><meta charset="utf-8"><title>Margin Report</title>');
    b.write('<style>body{font-family:Arial,Helvetica,sans-serif;margin:22px;color:#1a1a1a}'
      'h1{font-size:18px;margin:0 0 4px}.meta{font-size:12px;color:#555;margin-bottom:12px}'
      'table{border-collapse:collapse;width:100%;font-size:11px}'
      'th,td{border:1px solid #ddd;padding:4px 6px}th{background:#1e2a78;color:#fff;text-align:left}'
      'td.num,th.num{text-align:right}tr.total td{font-weight:700;background:#f3f4f6}'
      '.neg{color:#c00;font-weight:700}'
      '.foot{margin-top:16px;font-size:11px;color:#666;border-top:1px solid #eee;padding-top:8px}'
      '.no-print{margin-bottom:12px}@media print{.no-print{display:none}}</style></head><body>');
    b.write('<div class="no-print"><button onclick="window.print()">&#x1F5A8; Print / Save as PDF</button></div>');
    b.write('<h1>Margin Report</h1><div class="meta">${_esc(_filterSummary())}</div>');
    b.write('<table><thead><tr>'
      '<th>Sr</th><th>Date</th><th>Sale Type</th><th>Sale #</th><th>Pur. Type</th><th>Pur. #</th>'
      '<th>Party</th><th>Product</th><th class="num">Qty</th><th class="num">Rate</th>'
      '<th class="num">Amount</th><th>Unit</th><th class="num">Unit Cost</th>'
      '<th class="num">Cost Amount</th><th class="num">Margin</th><th>Branch</th></tr></thead><tbody>');
    var i = 0;
    for (final r in rows) {
      i++;
      final m = (r['margin'] as num? ?? 0).toDouble();
      final prod = '${(r['sku'] ?? '') == '' ? '' : '${r['sku']} - '}${r['product'] ?? ''}';
      b.write('<tr>'
        '<td>$i</td>'
        '<td>${_esc(_fmtDate(r['doc_date']))}</td>'
        '<td>${_esc((r['sale_type'] ?? '').toString())}</td>'
        '<td>${_esc((r['sale_number'] ?? '').toString())}</td>'
        '<td>${_esc((r['pu_type'] ?? '').toString())}</td>'
        '<td>${_esc((r['pu_number'] ?? '').toString())}</td>'
        '<td>${_esc((r['party'] ?? '').toString())}</td>'
        '<td>${_esc(prod)}</td>'
        '<td class="num">${_fmtQty(r['qty'] as num?)}</td>'
        '<td class="num">${_fmtMoney(r['rate'] as num?)}</td>'
        '<td class="num">${_fmtMoney(r['amount'] as num?)}</td>'
        '<td>${_esc((r['unit'] ?? '').toString())}</td>'
        '<td class="num">${_fmtMoney(r['unit_cost'] as num?)}</td>'
        '<td class="num">${_fmtMoney(r['cost_amount'] as num?)}</td>'
        '<td class="num ${m < 0 ? 'neg' : ''}">${_fmtMoney(m)}</td>'
        '<td>${_esc((r['branch'] ?? '').toString())}</td>'
        '</tr>');
    }
    b.write('<tr class="total"><td colspan="8">Total (${rows.length} lines)</td>'
      '<td class="num">${_fmtQty(_totQty)}</td><td class="num"></td>'
      '<td class="num">${_fmtMoney(_totAmount)}</td><td></td><td class="num"></td>'
      '<td class="num">${_fmtMoney(_totCost)}</td>'
      '<td class="num ${_totMargin < 0 ? 'neg' : ''}">${_fmtMoney(_totMargin)}</td><td></td></tr>');
    b.write('</tbody></table>');
    final ts = DateFormat('d MMM yyyy, HH:mm').format(DateTime.now());
    b.write('<div class="foot">Created by ${_esc(_userName.isEmpty ? '—' : _userName)} &nbsp;•&nbsp; Created at $ts</div>');
    b.write('</body></html>');
    final blob = html.Blob([b.toString()], 'text/html;charset=utf-8');
    html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
  }

  void _exportCsv() {
    String c(Object? v) {
      final s = (v ?? '').toString();
      return '"${s.replaceAll('"', '""')}"';
    }
    final sb = StringBuffer();
    sb.writeln(['Sr', 'Date', 'Sale Type', 'Sale #', 'Pur. Type', 'Pur. #', 'Party', 'Product', 'Qty', 'Rate', 'Amount', 'Unit', 'Unit Cost', 'Cost Amount', 'Margin', 'Branch'].map(c).join(','));
    var i = 0;
    for (final r in _visible) {
      i++;
      sb.writeln([
        i, _fmtDate(r['doc_date']), r['sale_type'] ?? '', r['sale_number'] ?? '', r['pu_type'] ?? '', r['pu_number'] ?? '',
        r['party'] ?? '', '${(r['sku'] ?? '') == '' ? '' : '${r['sku']} - '}${r['product'] ?? ''}',
        _fmtQty(r['qty'] as num?), r['rate'] ?? 0, r['amount'] ?? 0, r['unit'] ?? '',
        r['unit_cost'] ?? 0, r['cost_amount'] ?? 0, r['margin'] ?? 0, r['branch'] ?? '',
      ].map(c).join(','));
    }
    final blob = html.Blob([sb.toString()], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final safe = 'margin_report_${DateFormat('yyyyMMdd').format(_from)}_${DateFormat('yyyyMMdd').format(_to)}.csv';
    html.AnchorElement(href: url)..setAttribute('download', safe)..click();
    html.Url.revokeObjectUrl(url);
  }

  static String _fmtDate(Object? v) {
    if (v == null) return '';
    final d = DateTime.tryParse(v.toString());
    return d != null ? DateFormat('dd/MM/yyyy').format(d) : v.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Container(color: AppTheme.background, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // header
      Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          const Text('Margin Report', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(width: 10),
          const Expanded(child: Text('Line-wise sale price vs. cost — flags negative-margin lines.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
          OutlinedButton.icon(onPressed: _rows.isEmpty ? null : _exportCsv, icon: const Icon(Icons.grid_on, size: 16), label: const Text('Excel')),
          const SizedBox(width: 8),
          OutlinedButton.icon(onPressed: _rows.isEmpty ? null : _exportPdf, icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print / PDF')),
        ])),
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _filterCard(),
        const SizedBox(height: 16),
        _resultsCard(),
        if (_hasRun && _rows.isNotEmpty) ...[
          const SizedBox(height: 16),
          _summaryCard('Group-wise Summary', 'group'),
          const SizedBox(height: 16),
          _summaryCard('Sub Group-wise Summary', 'sub_group'),
        ],
      ]))),
    ]));
  }

  // Aggregates the currently-visible rows by the given key (group / sub_group)
  // into qty / amount / cost / margin subtotals, sorted by margin desc.
  List<Map<String, dynamic>> _summaryBy(String key) {
    final map = <String, Map<String, double>>{};
    for (final r in _visible) {
      final k = (r[key] as String?)?.trim();
      final label = (k == null || k.isEmpty) ? '(Unspecified)' : k;
      final m = map.putIfAbsent(label, () => {'qty': 0, 'amount': 0, 'cost': 0, 'margin': 0});
      m['qty'] = m['qty']! + ((r['qty'] as num?)?.toDouble() ?? 0);
      m['amount'] = m['amount']! + ((r['amount'] as num?)?.toDouble() ?? 0);
      m['cost'] = m['cost']! + ((r['cost_amount'] as num?)?.toDouble() ?? 0);
      m['margin'] = m['margin']! + ((r['margin'] as num?)?.toDouble() ?? 0);
    }
    final out = map.entries.map((e) => {
      'label': e.key,
      'qty': e.value['qty'], 'amount': e.value['amount'],
      'cost': e.value['cost'], 'margin': e.value['margin'],
    }).toList();
    out.sort((a, b) => (b['margin'] as double).compareTo(a['margin'] as double));
    return out;
  }

  Widget _summaryCard(String title, String key) {
    final rows = _summaryBy(key);
    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
        const Divider(height: 1),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
          headingRowHeight: 40, dataRowMinHeight: 36, dataRowMaxHeight: 44,
          columns: [
            DataColumn(label: Text(key == 'group' ? 'Group' : 'Sub Group', style: _h)),
            DataColumn(label: Text('Qty', style: _h), numeric: true),
            DataColumn(label: Text('Amount', style: _h), numeric: true),
            DataColumn(label: Text('Cost', style: _h), numeric: true),
            DataColumn(label: Text('Margin', style: _h), numeric: true),
            DataColumn(label: Text('Margin %', style: _h), numeric: true),
          ],
          rows: [
            for (final r in rows)
              DataRow(cells: [
                DataCell(Text(r['label'] as String, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                DataCell(Text(_fmtQty(r['qty'] as double), style: const TextStyle(fontSize: 12))),
                DataCell(Text(_fmtMoney(r['amount'] as double), style: const TextStyle(fontSize: 12))),
                DataCell(Text(_fmtMoney(r['cost'] as double), style: const TextStyle(fontSize: 12))),
                DataCell(Text(_fmtMoney(r['margin'] as double),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                        color: (r['margin'] as double) < 0 ? AppTheme.danger : AppTheme.textPrimary))),
                DataCell(Text(
                    (r['amount'] as double) == 0 ? '-' : '${(((r['margin'] as double) / (r['amount'] as double)) * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(fontSize: 12))),
              ]),
          ],
        )),
      ]),
    );
  }

  Widget _filterCard() {
    return Container(padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Filters', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Wrap(spacing: 14, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.end, children: [
          _field('From', 150, InkWell(onTap: () => _pickDate(true), child: _box(DateFormat('dd/MM/yyyy').format(_from)))),
          _field('To', 150, InkWell(onTap: () => _pickDate(false), child: _box(DateFormat('dd/MM/yyyy').format(_to)))),
          _field('Branch', 200, DropdownButtonFormField<String?>(
            value: _branchId, isExpanded: true,
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
            items: [const DropdownMenuItem<String?>(value: null, child: Text('All')),
              ..._branches.map((b) => DropdownMenuItem<String?>(value: b['id'] as String, child: Text(b['name'] as String? ?? '-', overflow: TextOverflow.ellipsis)))],
            onChanged: (v) => setState(() => _branchId = v))),
          _field('Customer', 240, _SearchField(
            key: ValueKey('cust_$_customerId'),
            initialLabel: _customerLabel, hint: 'All customers',
            filterFn: (q) => _filter(_customers, q),
            onPick: (e) => setState(() { _customerId = e['id'] as String?; _customerLabel = e['label'] as String? ?? ''; }),
            onClear: () => setState(() { _customerId = null; _customerLabel = ''; }))),
          _field('Product', 260, _SearchField(
            key: ValueKey('prod_$_productId'),
            initialLabel: _productLabel, hint: 'All products',
            filterFn: (q) => _filter(_products, q),
            onPick: (e) => setState(() { _productId = e['id'] as String?; _productLabel = e['label'] as String? ?? ''; }),
            onClear: () => setState(() { _productId = null; _productLabel = ''; }))),
          _field('Product Group', 200, DropdownButtonFormField<String?>(
            value: _group, isExpanded: true,
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
            items: [const DropdownMenuItem<String?>(value: null, child: Text('All')),
              ..._groups.map((g) => DropdownMenuItem<String?>(value: g, child: Text(g, overflow: TextOverflow.ellipsis)))],
            onChanged: (v) => setState(() => _group = v))),
          _field('Product Sub Group', 200, DropdownButtonFormField<String?>(
            value: _subGroup, isExpanded: true,
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
            items: [const DropdownMenuItem<String?>(value: null, child: Text('All')),
              ..._subGroups.map((g) => DropdownMenuItem<String?>(value: g, child: Text(g, overflow: TextOverflow.ellipsis)))],
            onChanged: (v) => setState(() => _subGroup = v))),
          _field('Product Main Group', 200, DropdownButtonFormField<String?>(
            value: _mainGroup, isExpanded: true,
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
            items: [const DropdownMenuItem<String?>(value: null, child: Text('All')),
              ..._mainGroups.map((g) => DropdownMenuItem<String?>(value: g, child: Text(g, overflow: TextOverflow.ellipsis)))],
            onChanged: (v) => setState(() => _mainGroup = v))),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          ElevatedButton.icon(onPressed: _running ? null : _run,
            icon: _running ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.assessment_outlined, size: 18),
            label: const Text('Load Report'), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12))),
          const SizedBox(width: 10),
          OutlinedButton(onPressed: _reset, child: const Text('Reset')),
        ]),
      ]));
  }

  Widget _field(String label, double width, Widget child) => SizedBox(width: width, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
    const SizedBox(height: 5), child,
  ]));

  Widget _box(String text) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
    child: Row(children: [const Icon(Icons.event, size: 15, color: AppTheme.textSecondary), const SizedBox(width: 8),
      Expanded(child: Text(text, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis))]));

  Widget _resultsCard() {
    if (!_hasRun) {
      return Container(padding: const EdgeInsets.all(40), alignment: Alignment.center,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
        child: const Text('Set your filters and tap Load Report.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)));
    }
    final rows = _visible;
    final negCount = _rows.where((r) => (r['margin'] as num? ?? 0) < 0).length;
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 8), child: Row(children: [
          Text('$_periodLabel  ·  ${_rows.length} lines', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(width: 12),
          if (negCount > 0) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: Colors.red.withOpacity(0.10), borderRadius: BorderRadius.circular(4)),
            child: Text('$negCount below cost', style: const TextStyle(fontSize: 11, color: Colors.red, fontWeight: FontWeight.w700))),
          const Spacer(),
          SizedBox(width: 240, child: TextField(
            decoration: const InputDecoration(hintText: 'Search product / party / voucher', isDense: true, prefixIcon: Icon(Icons.search, size: 16)),
            onChanged: (v) => setState(() => _search = v))),
        ])),
        if (rows.isEmpty) const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('No lines match.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary))))
        else SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
          headingRowHeight: 40, dataRowMinHeight: 34, dataRowMaxHeight: 56, columnSpacing: 18,
          headingRowColor: MaterialStateProperty.all(AppTheme.background),
          columns: [
            DataColumn(label: Text('Sr', style: _h)),
            DataColumn(label: Text('Date', style: _h)),
            DataColumn(label: Text('Sale Type', style: _h)),
            DataColumn(label: _sortHeader('Sale #', 'sale_number')),
            DataColumn(label: Text('Pur. Type', style: _h)),
            DataColumn(label: Text('Pur. #', style: _h)),
            DataColumn(label: _sortHeader('Party', 'party')),
            DataColumn(label: _sortHeader('Product', 'product')),
            DataColumn(label: _sortHeader('Qty', 'qty', right: true), numeric: true),
            DataColumn(label: _sortHeader('Rate', 'rate', right: true), numeric: true),
            DataColumn(label: _sortHeader('Amount', 'amount', right: true), numeric: true),
            DataColumn(label: Text('Unit', style: _h)),
            DataColumn(label: _sortHeader('Unit Cost', 'unit_cost', right: true), numeric: true),
            DataColumn(label: _sortHeader('Cost Amount', 'cost_amount', right: true), numeric: true),
            DataColumn(label: _sortHeader('Margin', 'margin', right: true), numeric: true),
            DataColumn(label: Text('Branch', style: _h)),
          ],
          rows: [
            for (var i = 0; i < rows.length; i++) _dataRow(i + 1, rows[i]),
            DataRow(color: MaterialStateProperty.all(AppTheme.background), cells: [
              const DataCell(Text('Total', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800))),
              const DataCell(Text('')), const DataCell(Text('')), const DataCell(Text('')),
              const DataCell(Text('')), const DataCell(Text('')), const DataCell(Text('')), const DataCell(Text('')),
              DataCell(Text(_fmtQty(_totQty), style: _bt)),
              const DataCell(Text('')),
              DataCell(Text(_fmtMoney(_totAmount), style: _bt)),
              const DataCell(Text('')),
              const DataCell(Text('')),
              DataCell(Text(_fmtMoney(_totCost), style: _bt)),
              DataCell(Text(_fmtMoney(_totMargin), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _totMargin < 0 ? Colors.red : AppTheme.textPrimary))),
              const DataCell(Text('')),
            ]),
          ],
        )),
        const SizedBox(height: 8),
      ]));
  }

  DataRow _dataRow(int sr, Map<String, dynamic> r) {
    final m = (r['margin'] as num? ?? 0).toDouble();
    final neg = m < 0;
    final prod = '${(r['sku'] ?? '') == '' ? '' : '${r['sku']} — '}${r['product'] ?? ''}';
    Widget t(String s, {bool num = false}) => Text(s, style: const TextStyle(fontSize: 12), textAlign: num ? TextAlign.right : TextAlign.left);
    return DataRow(
      color: neg ? MaterialStateProperty.all(Colors.red.withOpacity(0.05)) : null,
      cells: [
        DataCell(Text('$sr', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        DataCell(t(_fmtDate(r['doc_date']))),
        DataCell(t((r['sale_type'] ?? '').toString())),
        DataCell(t((r['sale_number'] ?? '').toString())),
        DataCell(t((r['pu_type'] ?? '').toString())),
        DataCell(t((r['pu_number'] ?? '').toString())),
        DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 200), child: Text((r['party'] ?? '').toString(), style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
        DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 240), child: Text(prod, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
        DataCell(t(_fmtQty(r['qty'] as num?), num: true)),
        DataCell(t(_fmtMoney(r['rate'] as num?), num: true)),
        DataCell(t(_fmtMoney(r['amount'] as num?), num: true)),
        DataCell(t((r['unit'] ?? '').toString())),
        DataCell(t(_fmtMoney(r['unit_cost'] as num?), num: true)),
        DataCell(t(_fmtMoney(r['cost_amount'] as num?), num: true)),
        DataCell(Text(_fmtMoney(m), textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: neg ? Colors.red : Colors.green.shade700))),
        DataCell(t((r['branch'] ?? '').toString())),
      ],
    );
  }

  static const _h = TextStyle(fontSize: 12, fontWeight: FontWeight.w700);
  static const _bt = TextStyle(fontSize: 12, fontWeight: FontWeight.w700);
}

class _SearchField extends StatefulWidget {
  final String initialLabel;
  final String hint;
  final List<Map<String, dynamic>> Function(String) filterFn;
  final void Function(Map<String, dynamic>) onPick;
  final VoidCallback onClear;
  const _SearchField({super.key, required this.initialLabel, required this.hint, required this.filterFn, required this.onPick, required this.onClear});
  @override State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _open = false; String _q = ''; bool _picked = false;

  @override void initState() {
    super.initState();
    _ctrl.text = widget.initialLabel;
    _picked = widget.initialLabel.isNotEmpty;
    _focus.addListener(() { if (!_focus.hasFocus) Future.delayed(const Duration(milliseconds: 160), () { if (mounted && !_focus.hasFocus) setState(() => _open = false); }); });
  }
  @override void dispose() { _ctrl.dispose(); _focus.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) {
    final res = widget.filterFn(_q);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(controller: _ctrl, focusNode: _focus,
        decoration: InputDecoration(hintText: widget.hint, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          border: OutlineInputBorder(borderSide: BorderSide(color: _picked ? Colors.green : const Color(0xFFE0E0E0))),
          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: _picked ? Colors.green : const Color(0xFFE0E0E0))),
          suffixIcon: _picked
            ? InkWell(onTap: () { _ctrl.clear(); setState(() { _picked = false; _q = ''; _open = false; }); widget.onClear(); }, child: const Icon(Icons.close, size: 15, color: AppTheme.textSecondary))
            : null),
        style: const TextStyle(fontSize: 12),
        onChanged: (v) => setState(() { _q = v; _open = true; _picked = false; }),
        onTap: () => setState(() { _q = _picked ? '' : _ctrl.text; _open = true; })),
      if (_open && res.isNotEmpty) Container(constraints: const BoxConstraints(maxHeight: 220), margin: const EdgeInsets.only(top: 2),
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)]),
        child: ListView(shrinkWrap: true, children: res.map((e) => InkWell(
          onTap: () { widget.onPick(e); _ctrl.text = e['label'] as String? ?? ''; setState(() { _open = false; _picked = true; _q = ''; }); _focus.unfocus(); },
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Text(e['label'] as String? ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
        )).toList())),
    ]);
  }
}
