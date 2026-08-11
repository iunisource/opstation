import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';
import '../../intelligence/widgets/searchable_dropdown.dart';

/// Customer Aging: outstanding receivables grouped by customer with 0-30 /
/// 31-60 / 61-90 / 90+ day buckets. Sources unpaid sales_invoices.
class ErpCustomerAgingScreen extends ConsumerStatefulWidget {
  const ErpCustomerAgingScreen({super.key});
  @override
  ConsumerState<ErpCustomerAgingScreen> createState() => _ErpCustomerAgingScreenState();
}

class _AgingRow {
  final String customerId;
  final String customerName;
  final String? code;
  double current = 0;   // 0-30 days
  double bucket1 = 0;   // 31-60
  double bucket2 = 0;   // 61-90
  double bucket3 = 0;   // 91-120
  double bucket4 = 0;   // 120+
  int invoiceCount = 0;
  DateTime? oldestInvoiceDate;
  final List<Map<String, dynamic>> openInvoices = [];
  double get total => current + bucket1 + bucket2 + bucket3 + bucket4;
  _AgingRow(this.customerId, this.customerName, this.code);
}

class _ErpCustomerAgingScreenState extends ConsumerState<ErpCustomerAgingScreen> {
  DateTime _asOf = DateTime.now();
  bool _loading = true;
  List<_AgingRow> _rows = [];
  String _search = '';
  String _sortBy = 'total';
  bool _sortDesc = true;
  final ScrollController _listCtrl = ScrollController();
  final ScrollController _detailCtrl = ScrollController();
  // Route (market) + salesperson filters
  String? _fRoute;
  String? _fSalesperson;
  List<Map<String, dynamic>> _routes = [];        // {id, name}
  List<Map<String, dynamic>> _salespeople = [];   // {id, name}
  Map<String, Set<String>> _custToRoutes = {};    // customer_id -> {route_id}
  Map<String, String> _routeToSalesperson = {};   // route_id -> user_id (salesperson)

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _listCtrl.dispose(); _detailCtrl.dispose(); super.dispose(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _load() async {
    setState(() => _loading = true);
    final orgId = _orgId;
    if (orgId == null) { setState(() => _loading = false); return; }
    try {
      final client = Supabase.instance.client;
      final asOfStr = DateFormat('yyyy-MM-dd').format(_asOf);
      // All-branches so the grand total ties to the Balance Sheet (1210),
      // which is not branch-filtered. (Pass p_branch_id only if you also
      // branch-filter the Balance Sheet.)
      final params = {'p_org_id': orgId, 'p_as_of': asOfStr};

      // Aggregate buckets + GL-true net per customer (ties to 1210).
      final agg = await client.rpc('rpc_customer_aging', params: params).limit(10000) as List;

      // Resolve names/codes for exactly the customer ids in the result.
      // Org-agnostic on purpose: some (imported) customers carry a different
      // org_id tag, so filtering by org_id would drop them -> "(Unknown)".
      // Falls back to pos_customers for POS-created ids.
      final names = <String, String>{};
      final codes = <String, String?>{};
      final cidList = <String>[
        for (final a in agg)
          if ((a as Map)['customer_id'] != null) (a as Map)['customer_id'] as String
      ];
      if (cidList.isNotEmpty) {
        try {
          final cs = await client.from('customers')
              .select('id, shop_name, code').inFilter('id', cidList).limit(10000);
          for (final c in cs as List) {
            final m = c as Map;
            final sn = m['shop_name'] as String?;
            if (sn != null && sn.isNotEmpty) names[m['id'] as String] = sn;
            codes[m['id'] as String] = m['code'] as String?;
          }
        } catch (e) { /* names are best-effort */ }
        final missing = [for (final id in cidList) if (!names.containsKey(id)) id];
        if (missing.isNotEmpty) {
          try {
            final pcs = await client.from('pos_customers')
                .select('id, name').inFilter('id', missing).limit(10000);
            for (final c in pcs as List) {
              final m = c as Map;
              final nm = m['name'] as String?;
              if (nm != null && nm.isNotEmpty) names[m['id'] as String] = nm;
            }
          } catch (e) { /* names are best-effort */ }
        }
      }

      // Open GL lines per customer for the drill-down (best-effort).
      final detailByCust = <String, List<Map<String, dynamic>>>{};
      try {
        final det = await client.rpc('rpc_customer_aging_detail', params: params).limit(10000) as List;
        for (final d in det) {
          final m = d as Map;
          final key = (m['customer_id'] as String?) ?? '__unallocated__';
          (detailByCust[key] ??= []).add({
            'voucher_number': (m['reference_number'] as String?) ?? '-',
            'voucher_date': DateTime.tryParse('${m['ref_date']}') ?? _asOf,
            'outstanding': (m['open_amt'] as num?)?.toDouble() ?? 0,
            'ageDays': (m['age_days'] as num?)?.toInt() ?? 0,
          });
        }
      } catch (e) { /* detail is optional */ }

      final rows = <_AgingRow>[];
      for (final a in agg) {
        final m = a as Map;
        final cid = m['customer_id'] as String?;
        final key = cid ?? '__unallocated__';
        final name = cid == null
            ? 'Unallocated (no customer)'
            : (names[cid] ?? '(Unknown)');
        final row = _AgingRow(cid ?? key, name, cid == null ? null : codes[cid]);
        final b1 = (m['b1'] as num?)?.toDouble() ?? 0;
        final b2 = (m['b2'] as num?)?.toDouble() ?? 0;
        final b3 = (m['b3'] as num?)?.toDouble() ?? 0;
        final b4 = (m['b4'] as num?)?.toDouble() ?? 0;
        final net = (m['total'] as num?)?.toDouble() ?? 0;
        // total is a getter (sum of buckets). Fold the GL net into `current`
        // so the row total equals the true 1210 balance, including credit
        // (overpaid) balances which carry no open debits.
        row.current = net - b1 - b2 - b3 - b4;
        row.bucket1 = b1; row.bucket2 = b2; row.bucket3 = b3; row.bucket4 = b4;
        final lines = detailByCust[key] ?? const <Map<String, dynamic>>[];
        row.openInvoices.addAll(lines);
        row.invoiceCount = lines.length;
        for (final ln in lines) {
          final dt = ln['voucher_date'] as DateTime;
          if (row.oldestInvoiceDate == null || dt.isBefore(row.oldestInvoiceDate!)) {
            row.oldestInvoiceDate = dt;
          }
        }
        rows.add(row);
      }
      // Route (market) + salesperson mapping for filters.
      List<Map<String, dynamic>> routeList = [];
      List<Map<String, dynamic>> salespeople = [];
      final custToRoutes = <String, Set<String>>{};
      final routeToSp = <String, String>{};
      try {
        final routesRes = await client.from('sales_routes')
            .select('id, name').eq('org_id', orgId).order('name');
        routeList = List<Map<String, dynamic>>.from(routesRes);
        salespeople = List<Map<String, dynamic>>.from(await client.from('users')
            .select('id, name').eq('org_id', orgId).eq('role', 'salesperson').order('name'));
        final routeIds = [for (final r in routeList) r['id'] as String];
        if (routeIds.isNotEmpty) {
          final stops = await client.from('route_stops').select('route_id, customer_id').inFilter('route_id', routeIds);
          for (final s in stops as List) {
            final m = s as Map;
            (custToRoutes[m['customer_id'] as String] ??= <String>{}).add(m['route_id'] as String);
          }
          final asg = await client.from('route_assignments').select('user_id, route_id').inFilter('route_id', routeIds);
          for (final a in asg as List) {
            final m = a as Map;
            routeToSp[m['route_id'] as String] = m['user_id'] as String;
          }
        }
      } catch (e) { /* filters are best-effort */ }

      setState(() {
        _rows = rows;
        _routes = routeList;
        _salespeople = salespeople;
        _custToRoutes = custToRoutes;
        _routeToSalesperson = routeToSp;
        _loading = false;
      });
    } catch (e) {
      // ignore: avoid_print
      print('[CustomerAging] load error: $e');
      setState(() => _loading = false);
    }
  }
  List<_AgingRow> get _filteredSorted {
    final q = _search.toLowerCase().trim();
    var list = _rows.where((r) {
      if (q.isNotEmpty &&
          !(r.customerName.toLowerCase().contains(q) || (r.code ?? '').toLowerCase().contains(q))) {
        return false;
      }
      final routeIds = _custToRoutes[r.customerId] ?? const <String>{};
      if (_fRoute != null && !routeIds.contains(_fRoute)) return false;
      if (_fSalesperson != null && !routeIds.any((rid) => _routeToSalesperson[rid] == _fSalesperson)) return false;
      return true;
    }).toList();
    int cmp(_AgingRow a, _AgingRow b) {
      switch (_sortBy) {
        case 'name': return a.customerName.compareTo(b.customerName);
        case 'current': return a.current.compareTo(b.current);
        case 'b1': return a.bucket1.compareTo(b.bucket1);
        case 'b2': return a.bucket2.compareTo(b.bucket2);
        case 'b3': return a.bucket3.compareTo(b.bucket3);
        case 'b4': return a.bucket4.compareTo(b.bucket4);
        default: return a.total.compareTo(b.total);
      }
    }
    list.sort((a, b) => _sortDesc ? cmp(b, a) : cmp(a, b));
    return list;
  }

  void _toggleSort(String col) {
    setState(() {
      if (_sortBy == col) _sortDesc = !_sortDesc;
      else { _sortBy = col; _sortDesc = true; }
    });
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    final branch = ref.read(selectedBranchProvider);
    final rows = _filteredSorted;
    final fmt = const MoneyFmt();
    List<List<String>> detailRows = [];
    String detailTitle = '';
    if (rows.length == 1) {
      final r = rows.first;
      final invs = List<Map<String, dynamic>>.from(r.openInvoices)
        ..sort((a, b) => (a['voucher_date'] as DateTime).compareTo(b['voucher_date'] as DateTime));
      detailTitle = r.customerName;
      for (final inv in invs) {
        final age = inv['ageDays'] as int;
        final bucket = age <= 30 ? '0-30' : age <= 60 ? '31-60' : age <= 90 ? '61-90' : age <= 120 ? '91-120' : '120+';
        detailRows.add([
          inv['voucher_number'] as String,
          DateFormat('d MMM yyyy').format(inv['voucher_date'] as DateTime),
          age.toString(),
          bucket,
          fmt.format(inv['outstanding'] as double),
        ]);
      }
    }
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      build: (ctx) => [
        pw.Text(user?.orgName ?? 'Opstation', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text('Customer Aging Report', style: pw.TextStyle(fontSize: 13, color: PdfColors.grey700)),
        if (branch != null) pw.Text('Branch: ${branch['name']}', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
        pw.Text('As of: ${DateFormat('d MMM yyyy').format(_asOf)}', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
        if (_fRoute != null) pw.Text('Route: ' + ((_routes.firstWhere((r) => r['id'] == _fRoute, orElse: () => const {})['name'] as String?) ?? '-'), style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
        if (_fSalesperson != null) pw.Text('Salesperson: ' + ((_salespeople.firstWhere((u) => u['id'] == _fSalesperson, orElse: () => const {})['name'] as String?) ?? '-'), style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
        pw.SizedBox(height: 12),
        pw.Table.fromTextArray(
          headers: ['#', 'Customer', 'Code', 'Invoices', '0-30', '31-60', '61-90', '91-120', '120+', 'Total'],
          data: [
            for (var i = 0; i < rows.length; i++) [
              '${i + 1}',
              rows[i].customerName,
              rows[i].code ?? '-',
              '${rows[i].invoiceCount}',
              fmt.format(rows[i].current),
              fmt.format(rows[i].bucket1),
              fmt.format(rows[i].bucket2),
              fmt.format(rows[i].bucket3),
              fmt.format(rows[i].bucket4),
              fmt.format(rows[i].total),
            ],
          ],
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
          cellStyle: const pw.TextStyle(fontSize: 9),
          cellAlignments: {
            3: pw.Alignment.centerRight,
            4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight,
            6: pw.Alignment.centerRight, 7: pw.Alignment.centerRight,
            8: pw.Alignment.centerRight, 9: pw.Alignment.centerRight,
          },
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF1F5F9)),
        ),
        pw.SizedBox(height: 10),
        pw.Text('Grand Total: ${fmt.format(rows.fold<double>(0, (s, r) => s + r.total))}',
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        if (detailRows.isNotEmpty) ...[
          pw.SizedBox(height: 16),
          pw.Text('Invoice Detail - ' + detailTitle + '  (oldest first)', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Table.fromTextArray(
            headers: const ['Voucher #', 'Date', 'Days Old', 'Bucket', 'Outstanding'],
            data: detailRows,
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellAlignments: const {2: pw.Alignment.centerRight, 4: pw.Alignment.centerRight},
            headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF1F5F9)),
          ),
        ],
      ],
    ));
    await Printing.layoutPdf(onLayout: (f) async => doc.save(), name: 'customer_aging_${DateFormat('yyyyMMdd').format(_asOf)}.pdf');
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(selectedBranchProvider);
    ref.listen(selectedBranchProvider, (_, __) => _load());

    final rows = _filteredSorted;
    final totalAll  = rows.fold<double>(0, (s, r) => s + r.total);
    final totalCur  = rows.fold<double>(0, (s, r) => s + r.current);
    final totalB1   = rows.fold<double>(0, (s, r) => s + r.bucket1);
    final totalB2   = rows.fold<double>(0, (s, r) => s + r.bucket2);
    final totalB3   = rows.fold<double>(0, (s, r) => s + r.bucket3);
    final totalB4   = rows.fold<double>(0, (s, r) => s + r.bucket4);
    final fmt = const MoneyFmt();

    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Customer Aging', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
          IconButton(onPressed: _print, icon: const Icon(Icons.print_outlined), tooltip: 'Print / PDF'),
        ]),
        const SizedBox(height: 4),
        Text(branch == null ? 'All branches' : 'Branch: ${branch['name']}',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 20),

        // Filters
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.calendar_today, size: 16),
            label: Text('As of: ${DateFormat('d MMM yyyy').format(_asOf)}'),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context, initialDate: _asOf,
                firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 30)),
              );
              if (picked != null) { setState(() => _asOf = picked); _load(); }
            },
          ),
          SizedBox(
            width: 260,
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Search customer / code',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          SizedBox(width: 220, child: SearchableDropdown(
            label: 'Route / Market',
            value: _fRoute,
            allLabel: 'All routes',
            options: [
              for (final r in _routes)
                MapEntry(r['id'] as String?, (r['name'] as String?) ?? '-'),
            ],
            onChanged: (v) => setState(() => _fRoute = v),
          )),
          SizedBox(width: 220, child: SearchableDropdown(
            label: 'Salesperson',
            value: _fSalesperson,
            allLabel: 'All salespersons',
            options: [
              for (final u in _salespeople)
                MapEntry(u['id'] as String?, (u['name'] as String?) ?? '-'),
            ],
            onChanged: (v) => setState(() => _fSalesperson = v),
          )),
          if (_fRoute != null || _fSalesperson != null)
            TextButton.icon(onPressed: () => setState(() { _fRoute = null; _fSalesperson = null; }),
                icon: const Icon(Icons.clear, size: 16), label: const Text('Clear')),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh, size: 20), tooltip: 'Refresh'),
        ]),
        const SizedBox(height: 12),

        // Summary cards
        if (!_loading)
          Row(children: [
            _summary('Current (0-30)', totalCur, AppTheme.success),
            const SizedBox(width: 12),
            _summary('31-60', totalB1, AppTheme.warning),
            const SizedBox(width: 12),
            _summary('61-90', totalB2, Colors.orange),
            const SizedBox(width: 12),
            _summary('91-120', totalB3, Colors.deepOrange),
            const SizedBox(width: 12),
            _summary('120+', totalB4, AppTheme.danger),
            const SizedBox(width: 12),
            _summary('Total Outstanding', totalAll, AppTheme.primary, bold: true),
          ]),
        const SizedBox(height: 16),

        Expanded(
          child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : rows.isEmpty
                    ? const Center(child: Text('No customers found.', style: TextStyle(color: AppTheme.textSecondary)))
                    : Column(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                          child: Row(children: [
                            SizedBox(width: 40, child: _hdr('#', null)),
                            Expanded(flex: 3, child: _hdr('Customer', 'name')),
                            Expanded(flex: 2, child: _hdr('Code', null)),
                            Expanded(flex: 1, child: _hdrRight('Invoices', null)),
                            Expanded(flex: 2, child: _hdrRight('0-30', 'current')),
                            Expanded(flex: 2, child: _hdrRight('31-60', 'b1')),
                            Expanded(flex: 2, child: _hdrRight('61-90', 'b2')),
                            Expanded(flex: 2, child: _hdrRight('91-120', 'b3')),
                            Expanded(flex: 2, child: _hdrRight('120+', 'b4')),
                            Expanded(flex: 2, child: _hdrRight('Total', 'total')),
                          ]),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: Scrollbar(
                            controller: _listCtrl,
                            thumbVisibility: true,
                            child: ListView.separated(
                            controller: _listCtrl,
                            primary: false,
                            itemCount: rows.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final r = rows[i];
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                child: Row(children: [
                                  SizedBox(width: 40, child: Text('${i + 1}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                                  Expanded(flex: 3, child: Text(r.customerName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                                  Expanded(flex: 2, child: Text(r.code ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                                  Expanded(flex: 1, child: Align(alignment: Alignment.centerRight, child: Text('${r.invoiceCount}', style: const TextStyle(fontSize: 12)))),
                                  _cell(r.current, AppTheme.success),
                                  _cell(r.bucket1, AppTheme.warning),
                                  _cell(r.bucket2, Colors.orange),
                                  _cell(r.bucket3, Colors.deepOrange),
                                  _cell(r.bucket4, AppTheme.danger),
                                  Expanded(flex: 2, child: Align(alignment: Alignment.centerRight,
                                      child: Text(fmt.format(r.total),
                                          style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary, fontSize: 13)))),
                                ]),
                              );
                            },
                          ),
                          ),
                        ),
                      ]),
          ),
        ),
        if (rows.length == 1) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 220,
            child: _buildInvoiceDetail(rows.first),
          ),
        ],
      ]),
    );
  }

  Widget _buildInvoiceDetail(_AgingRow row) {
    final fmt = const MoneyFmt();
    final dateFmt = DateFormat('d MMM yyyy');
    final invs = List<Map<String, dynamic>>.from(row.openInvoices)
      ..sort((a, b) => (a['voucher_date'] as DateTime).compareTo(b['voucher_date'] as DateTime));
    final show = invs.length > 8 ? invs.sublist(0, 8) : invs;
    final remaining = invs.length - show.length;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            const Icon(Icons.receipt_long_outlined, size: 18, color: AppTheme.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Open Invoices - ${row.customerName}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            ),
            Text('${invs.length} invoice${invs.length == 1 ? "" : "s"}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
        ),
        const Divider(height: 1),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: AppTheme.background,
          child: Row(children: const [
            Expanded(flex: 2, child: Text('Voucher #', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Date', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
            Expanded(flex: 1, child: Align(alignment: Alignment.centerRight, child: Text('Days Old', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)))),
            Expanded(flex: 2, child: Align(alignment: Alignment.center, child: Text('Bucket', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)))),
            Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: Text('Outstanding', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)))),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            controller: _detailCtrl,
            primary: false,
            itemCount: show.length + (remaining > 0 ? 1 : 0),
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              if (i == show.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Text('+ $remaining more open invoice${remaining == 1 ? "" : "s"}, see ledger for full detail',
                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontStyle: FontStyle.italic)),
                );
              }
              final inv = show[i];
              final age = inv['ageDays'] as int;
              final bucket = age <= 30 ? '0-30' : age <= 60 ? '31-60' : age <= 90 ? '61-90' : age <= 120 ? '91-120' : '120+';
              final color = age <= 30 ? AppTheme.success : age <= 60 ? AppTheme.warning : age <= 90 ? Colors.orange : age <= 120 ? Colors.deepOrange : AppTheme.danger;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Expanded(flex: 2, child: Text(inv['voucher_number'] as String, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                  Expanded(flex: 2, child: Text(dateFmt.format(inv['voucher_date'] as DateTime), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 1, child: Align(alignment: Alignment.centerRight, child: Text('$age', style: const TextStyle(fontSize: 12)))),
                  Expanded(flex: 2, child: Align(alignment: Alignment.center, child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                    child: Text(bucket, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
                  ))),
                  Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: Text(fmt.format(inv['outstanding'] as double), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary)))),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }

  Widget _summary(String label, double v, Color c, {bool bold = false}) {
    final fmt = const MoneyFmt();
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          Text(fmt.format(v), style: TextStyle(fontSize: bold ? 18 : 16, fontWeight: FontWeight.w700, color: c)),
        ]),
      ),
    );
  }

  Widget _hdr(String label, String? sortKey) {
    final isActive = _sortBy == sortKey;
    final w = Row(children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
      if (isActive) Icon(_sortDesc ? Icons.arrow_drop_down : Icons.arrow_drop_up, size: 14, color: AppTheme.primary),
    ]);
    return sortKey == null ? w : InkWell(onTap: () => _toggleSort(sortKey), child: w);
  }

  Widget _hdrRight(String label, String? sortKey) {
    final isActive = _sortBy == sortKey;
    final w = Row(mainAxisAlignment: MainAxisAlignment.end, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
      if (isActive) Icon(_sortDesc ? Icons.arrow_drop_down : Icons.arrow_drop_up, size: 14, color: AppTheme.primary),
    ]);
    return sortKey == null ? w : InkWell(onTap: () => _toggleSort(sortKey), child: w);
  }

  Widget _cell(double v, Color c) {
    final fmt = const MoneyFmt();
    return Expanded(flex: 2, child: Align(alignment: Alignment.centerRight,
        child: Text(v > 0.005 ? fmt.format(v) : '-',
            style: TextStyle(fontWeight: FontWeight.w600, color: v > 0.005 ? c : AppTheme.textSecondary, fontSize: 12))));
  }
}
