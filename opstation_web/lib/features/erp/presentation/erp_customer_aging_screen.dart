import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

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
  double current = 0;   // 0–30 days
  double bucket1 = 0;   // 31–60
  double bucket2 = 0;   // 61–90
  double bucket3 = 0;   // 91+
  int invoiceCount = 0;
  DateTime? oldestInvoiceDate;
  double get total => current + bucket1 + bucket2 + bucket3;
  _AgingRow(this.customerId, this.customerName, this.code);
}

class _ErpCustomerAgingScreenState extends ConsumerState<ErpCustomerAgingScreen> {
  DateTime _asOf = DateTime.now();
  bool _loading = true;
  List<_AgingRow> _rows = [];
  String _search = '';
  String _sortBy = 'total';
  bool _sortDesc = true;

  @override
  void initState() { super.initState(); _load(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _load() async {
    setState(() => _loading = true);
    final orgId = _orgId;
    if (orgId == null) { setState(() => _loading = false); return; }
    try {
      final client = Supabase.instance.client;
      final branchId = _branchId;
      var q = client.from('sales_invoices')
          .select('id, voucher_number, voucher_date, grand_total, customer_id, customers(shop_name, code)')
          .eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final invs = await q.lte('voucher_date', DateFormat('yyyy-MM-dd').format(_asOf)).limit(20000);

      // Pull receipts (payments) so we subtract from invoice totals. Receipts
      // table is `receipt_vouchers` (per existing code).
      var rq = client.from('receipt_vouchers')
          .select('customer_id, amount, voucher_date')
          .eq('org_id', orgId);
      if (branchId != null) rq = rq.eq('branch_id', branchId);
      final receipts = await rq.lte('voucher_date', DateFormat('yyyy-MM-dd').format(_asOf)).limit(20000);

      // Aggregate receipts per customer (lifetime up to as-of date)
      final paidByCustomer = <String, double>{};
      for (final r in receipts as List) {
        final cid = (r as Map)['customer_id'] as String?;
        if (cid == null) continue;
        paidByCustomer[cid] = (paidByCustomer[cid] ?? 0) + ((r['amount'] as num?)?.toDouble() ?? 0);
      }

      // Walk invoices oldest → newest, applying paid balance per customer.
      final list = List<Map<String, dynamic>>.from(invs)
        ..sort((a, b) => (a['voucher_date'] as String).compareTo(b['voucher_date'] as String));

      final rows = <String, _AgingRow>{};
      for (final inv in list) {
        final cid = inv['customer_id'] as String?;
        if (cid == null) continue;
        final cust = inv['customers'] as Map?;
        final name = cust?['shop_name'] as String? ?? '(Unknown)';
        final code = cust?['code'] as String?;
        final row = rows.putIfAbsent(cid, () => _AgingRow(cid, name, code));

        final total = (inv['grand_total'] as num?)?.toDouble() ?? 0;
        // Apply available receipt credit (FIFO across invoices)
        final available = paidByCustomer[cid] ?? 0;
        final applied = available >= total ? total : available;
        paidByCustomer[cid] = available - applied;
        final outstanding = total - applied;
        if (outstanding <= 0.005) continue;

        final invDate = DateTime.parse(inv['voucher_date'] as String);
        final ageDays = _asOf.difference(invDate).inDays;
        if (ageDays <= 30) row.current += outstanding;
        else if (ageDays <= 60) row.bucket1 += outstanding;
        else if (ageDays <= 90) row.bucket2 += outstanding;
        else row.bucket3 += outstanding;
        row.invoiceCount += 1;
        if (row.oldestInvoiceDate == null || invDate.isBefore(row.oldestInvoiceDate!)) {
          row.oldestInvoiceDate = invDate;
        }
      }

      setState(() {
        _rows = rows.values.where((r) => r.total > 0.005).toList();
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
      if (q.isEmpty) return true;
      return r.customerName.toLowerCase().contains(q) ||
             (r.code ?? '').toLowerCase().contains(q);
    }).toList();
    int cmp(_AgingRow a, _AgingRow b) {
      switch (_sortBy) {
        case 'name': return a.customerName.compareTo(b.customerName);
        case 'current': return a.current.compareTo(b.current);
        case 'b1': return a.bucket1.compareTo(b.bucket1);
        case 'b2': return a.bucket2.compareTo(b.bucket2);
        case 'b3': return a.bucket3.compareTo(b.bucket3);
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
    final fmt = NumberFormat('#,##0.00');
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
        pw.SizedBox(height: 12),
        pw.Table.fromTextArray(
          headers: ['#', 'Customer', 'Code', 'Invoices', '0–30', '31–60', '61–90', '91+', 'Total'],
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
              fmt.format(rows[i].total),
            ],
          ],
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
          cellStyle: const pw.TextStyle(fontSize: 9),
          cellAlignments: {
            3: pw.Alignment.centerRight,
            4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight,
            6: pw.Alignment.centerRight, 7: pw.Alignment.centerRight,
            8: pw.Alignment.centerRight,
          },
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF1F5F9)),
        ),
        pw.SizedBox(height: 10),
        pw.Text('Grand Total: ${fmt.format(rows.fold<double>(0, (s, r) => s + r.total))}',
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
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
    final fmt = NumberFormat('#,##0.00');

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
        Row(children: [
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
          const SizedBox(width: 12),
          SizedBox(
            width: 320,
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Search customer / code',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          const Spacer(),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh, size: 20), tooltip: 'Refresh'),
        ]),
        const SizedBox(height: 12),

        // Summary cards
        if (!_loading)
          Row(children: [
            _summary('Current (0–30)', totalCur, AppTheme.success),
            const SizedBox(width: 12),
            _summary('31–60', totalB1, AppTheme.warning),
            const SizedBox(width: 12),
            _summary('61–90', totalB2, Colors.orange),
            const SizedBox(width: 12),
            _summary('91+', totalB3, AppTheme.danger),
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
                    ? const Center(child: Text('No outstanding amounts.', style: TextStyle(color: AppTheme.textSecondary)))
                    : Column(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                          child: Row(children: [
                            SizedBox(width: 40, child: _hdr('#', null)),
                            Expanded(flex: 3, child: _hdr('Customer', 'name')),
                            Expanded(flex: 2, child: _hdr('Code', null)),
                            Expanded(flex: 1, child: _hdrRight('Invoices', null)),
                            Expanded(flex: 2, child: _hdrRight('0–30', 'current')),
                            Expanded(flex: 2, child: _hdrRight('31–60', 'b1')),
                            Expanded(flex: 2, child: _hdrRight('61–90', 'b2')),
                            Expanded(flex: 2, child: _hdrRight('91+', 'b3')),
                            Expanded(flex: 2, child: _hdrRight('Total', 'total')),
                          ]),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: ListView.separated(
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
                                  _cell(r.bucket3, AppTheme.danger),
                                  Expanded(flex: 2, child: Align(alignment: Alignment.centerRight,
                                      child: Text(fmt.format(r.total),
                                          style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary, fontSize: 13)))),
                                ]),
                              );
                            },
                          ),
                        ),
                      ]),
          ),
        ),
      ]),
    );
  }

  Widget _summary(String label, double v, Color c, {bool bold = false}) {
    final fmt = NumberFormat('#,##0.00');
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
    final fmt = NumberFormat('#,##0.00');
    return Expanded(flex: 2, child: Align(alignment: Alignment.centerRight,
        child: Text(v > 0.005 ? fmt.format(v) : '-',
            style: TextStyle(fontWeight: FontWeight.w600, color: v > 0.005 ? c : AppTheme.textSecondary, fontSize: 12))));
  }
}
