import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/format/money.dart';
import '../../auth/auth_controller.dart';
import '../../../core/widgets/responsive.dart';

/// Supplier Aging: outstanding payables grouped by supplier with 0-30 /
/// 31-60 / 61-90 / 91-120 / 120+ day buckets. Reads the GL Accounts-Payable
/// account via rpc_supplier_aging (mirror of customer aging on AR), so the
/// total reconciles to Accounts Payable on the balance sheet.
class ErpSupplierAgingScreen extends ConsumerStatefulWidget {
  const ErpSupplierAgingScreen({super.key});
  @override
  ConsumerState<ErpSupplierAgingScreen> createState() => _ErpSupplierAgingScreenState();
}

class _AgingRow {
  final String supplierId;
  final String supplierName;
  final String? code;
  double current = 0;   // 0-30 days
  double bucket1 = 0;   // 31-60
  double bucket2 = 0;   // 61-90
  double bucket3 = 0;   // 91-120
  double bucket4 = 0;   // 120+
  double netTotal = 0;  // GL AP balance (credit - debit) for this supplier;
                        // authoritative — reconciles to the balance-sheet AP.
  int invoiceCount = 0;
  DateTime? oldestInvoiceDate;
  final List<Map<String, dynamic>> openInvoices = [];
  double get total => netTotal;
  _AgingRow(this.supplierId, this.supplierName, this.code);
}

class _ErpSupplierAgingScreenState extends ConsumerState<ErpSupplierAgingScreen> {
  DateTime _asOf = DateTime.now();
  bool _loading = true;
  String? _err; // surfaced inline so an RPC failure never silently blanks
  List<_AgingRow> _rows = [];
  String _search = '';
  String _sortBy = 'total';
  bool _sortDesc = true;
  final ScrollController _listCtrl = ScrollController();
  final ScrollController _detailCtrl = ScrollController();

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _listCtrl.dispose(); _detailCtrl.dispose(); super.dispose(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  /// Call a supplier-aging RPC resiliently: try WITH the branch filter first,
  /// and if the function signature doesn't accept p_branch_id (PostgREST can't
  /// resolve the overload — PGRST202 / "function ... does not exist"), retry
  /// WITHOUT it. This mirrors customer aging (org + as_of only), which ties to
  /// the balance-sheet AP, and makes the screen robust to an RPC signature that
  /// changed on the server. Any OTHER error is rethrown so it surfaces.
  Future<List> _callAgingRpc(
      SupabaseClient client, String fn, String orgId, String asOf, String? branchId) async {
    try {
      final r = await client.rpc(fn, params: {
        'p_org_id': orgId, 'p_as_of': asOf, 'p_branch_id': branchId,
      });
      return (r as List? ?? const []);
    } on PostgrestException catch (e) {
      final msg = e.message.toLowerCase();
      final signatureMismatch = e.code == 'PGRST202' ||
          (msg.contains('function') &&
              (msg.contains('does not exist') || msg.contains('could not find')));
      if (!signatureMismatch) rethrow;
      final r = await client.rpc(fn, params: {
        'p_org_id': orgId, 'p_as_of': asOf,
      });
      return (r as List? ?? const []);
    }
  }

  Future<void> _load() async {
    setState(() { _loading = true; _err = null; });
    final orgId = _orgId;
    if (orgId == null) { setState(() => _loading = false); return; }
    final client = Supabase.instance.client;
    // Org-wide (branch = null), exactly like Customer Aging and the Supplier
    // Balance Report. The AP journal lines for a supplier can be tagged to any
    // branch (a payment entered at another branch, an opening balance with no
    // branch, etc.); branch-filtering them here dropped those lines and made the
    // aging disagree with the ledger / balance sheet. Aging the full AP account
    // makes the grand total reconcile to the Supplier Balance Report exactly.
    const String? branchId = null;
    final asOfStr = DateFormat('yyyy-MM-dd').format(_asOf);

    // Supplier master (names/codes) — seed the full roster so zero-balance
    // suppliers still appear. A failure HERE is the only thing that should
    // leave the list empty, so it's handled on its own.
    final Map<String, Map<String, dynamic>> supInfo = {};
    try {
      for (int from = 0; ; from += 1000) {
        // NOTE: the suppliers table has no `code` column (unlike customers),
        // so selecting it throws 42703 and blanks the report. Select id+name
        // only; code stays null (rendered as "-").
        final page = List.from(await client.from('suppliers')
            .select('id, name').eq('org_id', orgId).range(from, from + 999));
        for (final s in page) {
          final m = s as Map;
          supInfo[m['id'] as String] = {'name': m['name'], 'code': null};
        }
        if (page.length < 1000 || from > 200000) break;
      }
    } catch (e) {
      // ignore: avoid_print
      print('[SupplierAging] suppliers error: $e');
      if (mounted) setState(() {
        _err = 'Could not load suppliers: ${e.toString().split('\n').first}';
        _loading = false;
      });
      return;
    }

    try {
      // Aging buckets straight from the GL Accounts-Payable account, so the
      // total reconciles to the balance sheet (same as customer aging on AR).
      // Wrapped so an RPC failure shows the roster (with zeros) + an inline
      // message instead of blanking the whole screen.
      List aging = const [];
      try {
        aging = await _callAgingRpc(client, 'rpc_supplier_aging', orgId, asOfStr, branchId);
      } catch (e) {
        // ignore: avoid_print
        print('[SupplierAging] aging error: $e');
        _err = 'Aging balances unavailable: ${e.toString().split('\n').first}';
      }

      // Open-item detail — powers the single-supplier panel + invoice count.
      final Map<String, List<Map<String, dynamic>>> detail = {};
      try {
        final det = await _callAgingRpc(
            client, 'rpc_supplier_aging_detail', orgId, asOfStr, branchId);
        for (final d in det) {
          final m = d as Map;
          final sid = m['supplier_id'] as String?;
          if (sid == null) continue;
          (detail[sid] ??= []).add({
            'voucher_number': m['reference_number'] as String? ?? '-',
            'voucher_date': DateTime.tryParse((m['ref_date'] as String?) ?? '') ?? _asOf,
            'outstanding': -((m['open_amt'] as num?)?.toDouble() ?? 0), // payable negative
            'ageDays': (m['age_days'] as num?)?.toInt() ?? 0,
          });
        }
      } catch (e) {
        // ignore: avoid_print
        print('[SupplierAging] detail error: $e');
      }

      // Seed every supplier as a zero row, then overlay the GL buckets.
      final rows = <String, _AgingRow>{};
      for (final e in supInfo.entries) {
        rows[e.key] = _AgingRow(e.key, e.value['name'] as String? ?? '(Unknown)', e.value['code'] as String?);
      }
      for (final a in (aging as List? ?? const [])) {
        final m = a as Map;
        final sid = m['supplier_id'] as String?;
        if (sid == null) continue; // unallocated (no supplier) rows are skipped
        final info = supInfo[sid];
        final row = rows.putIfAbsent(sid,
            () => _AgingRow(sid, info?['name'] as String? ?? '(Unknown)', info?['code'] as String?));
        // Sign convention: payable NEGATIVE, advance POSITIVE (matches the
        // ledger / balance report / old ERP). The RPC returns payable-positive,
        // so negate.
        row.current  = -((m['cur']   as num?)?.toDouble() ?? 0);
        row.bucket1  = -((m['b1']    as num?)?.toDouble() ?? 0);
        row.bucket2  = -((m['b2']    as num?)?.toDouble() ?? 0);
        row.bucket3  = -((m['b3']    as num?)?.toDouble() ?? 0);
        row.bucket4  = -((m['b4']    as num?)?.toDouble() ?? 0);
        row.netTotal = -((m['total'] as num?)?.toDouble() ?? 0);
        final det = detail[sid];
        if (det != null && det.isNotEmpty) {
          det.sort((a, b) => (a['voucher_date'] as DateTime).compareTo(b['voucher_date'] as DateTime));
          row.openInvoices..clear()..addAll(det);
          row.invoiceCount = det.length;
          row.oldestInvoiceDate = det.first['voucher_date'] as DateTime;
        }
      }

      setState(() {
        _rows = rows.values.toList();
        _loading = false;
      });
    } catch (e) {
      // ignore: avoid_print
      print('[SupplierAging] load error: $e');
      setState(() => _loading = false);
    }
  }

  List<_AgingRow> get _filteredSorted {
    final q = _search.toLowerCase().trim();
    var list = _rows.where((r) {
      if (q.isEmpty) return true;
      return r.supplierName.toLowerCase().contains(q) ||
             (r.code ?? '').toLowerCase().contains(q);
    }).toList();
    int cmp(_AgingRow a, _AgingRow b) {
      switch (_sortBy) {
        case 'name': return a.supplierName.compareTo(b.supplierName);
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
    final rows = _filteredSorted;
    final fmt = const MoneyFmt();
    List<List<String>> detailRows = [];
    String detailTitle = '';
    if (rows.length == 1) {
      final r = rows.first;
      final invs = List<Map<String, dynamic>>.from(r.openInvoices)
        ..sort((a, b) => (a['voucher_date'] as DateTime).compareTo(b['voucher_date'] as DateTime));
      detailTitle = r.supplierName;
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
        pw.Text('Supplier Aging Report', style: pw.TextStyle(fontSize: 13, color: PdfColors.grey700)),
        pw.Text('All branches (reconciles to balance-sheet Accounts Payable)', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
        pw.Text('As of: ${DateFormat('d MMM yyyy').format(_asOf)}', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
        pw.SizedBox(height: 12),
        pw.Table.fromTextArray(
          headers: ['#', 'Supplier', 'Code', 'Invoices', '0-30', '31-60', '61-90', '91-120', '120+', 'Total'],
          data: [
            for (var i = 0; i < rows.length; i++) [
              '${i + 1}',
              rows[i].supplierName,
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
    await Printing.layoutPdf(onLayout: (f) async => doc.save(), name: 'supplier_aging_${DateFormat('yyyyMMdd').format(_asOf)}.pdf');
  }

  @override
  Widget build(BuildContext context) {
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
          const Expanded(child: Text('Supplier Aging', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
          IconButton(onPressed: _print, icon: const Icon(Icons.print_outlined), tooltip: 'Print / PDF'),
        ]),
        const SizedBox(height: 4),
        const Text('All branches · reconciles to balance-sheet Accounts Payable',
            style: TextStyle(color: AppTheme.textSecondary)),
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
                labelText: 'Search supplier / code',
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
        if (_err != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.warning.withOpacity(0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.warning.withOpacity(0.4)),
            ),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded, size: 18, color: AppTheme.warning),
              const SizedBox(width: 8),
              Expanded(child: Text(_err!, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
            ]),
          ),
        ],
        const SizedBox(height: 16),

        Expanded(
          child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : rows.isEmpty
                    ? const Center(child: Text('No suppliers found.', style: TextStyle(color: AppTheme.textSecondary)))
                    : HScrollOnNarrow(minWidth: 920, child: Column(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                          child: Row(children: [
                            SizedBox(width: 40, child: _hdr('#', null)),
                            Expanded(flex: 3, child: _hdr('Supplier', 'name')),
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
                                  Expanded(flex: 3, child: Text(r.supplierName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
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
                      ])),
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
              child: Text('Open Invoices - ${row.supplierName}',
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
        child: Text(v.abs() > 0.005 ? fmt.format(v) : '-',
            style: TextStyle(fontWeight: FontWeight.w600, color: v.abs() > 0.005 ? c : AppTheme.textSecondary, fontSize: 12))));
  }
}
