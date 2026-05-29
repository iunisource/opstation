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

class ErpTrialBalanceScreen extends ConsumerStatefulWidget {
  const ErpTrialBalanceScreen({super.key});
  @override
  ConsumerState<ErpTrialBalanceScreen> createState() => _ErpTrialBalanceScreenState();
}

class _ErpTrialBalanceScreenState extends ConsumerState<ErpTrialBalanceScreen> {
  DateTime _from = DateTime(DateTime.now().year, 1, 1);
  DateTime _to   = DateTime.now();
  bool _loading  = false;
  List<Map<String, dynamic>> _rows = [];

  @override void initState() { super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load()); }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final branch = ref.read(selectedBranchProvider);
      final res = await Supabase.instance.client.rpc('rpc_trial_balance', params: {
        'p_org_id': orgId,
        'p_date_from': DateFormat('yyyy-MM-dd').format(_from),
        'p_date_to':   DateFormat('yyyy-MM-dd').format(_to),
        'p_branch_id': branch?['id'],
      });
      setState(() { _rows = List<Map<String, dynamic>>.from(res as List); _loading = false; });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    final branch = ref.read(selectedBranchProvider);
    final fmt = NumberFormat('#,##0.00');
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(20),
      build: (ctx) => [
        pw.Text(user?.orgName ?? '', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text('Trial Balance', style: pw.TextStyle(fontSize: 13, color: PdfColors.grey700)),
        if (branch != null) pw.Text('Branch: ${branch['name']}', style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
        pw.Text('Period: ${DateFormat('d MMM yyyy').format(_from)} to ${DateFormat('d MMM yyyy').format(_to)}',
            style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
        pw.SizedBox(height: 10),
        pw.Table.fromTextArray(
          headers: ['Code','Account','Open Dr','Open Cr','Period Dr','Period Cr','Close Dr','Close Cr'],
          data: [for (final r in _rows) [
            r['code']??'', r['name']??'',
            fmt.format((r['opening_dr'] as num?? 0).toDouble()),
            fmt.format((r['opening_cr'] as num?? 0).toDouble()),
            fmt.format((r['period_dr']  as num?? 0).toDouble()),
            fmt.format((r['period_cr']  as num?? 0).toDouble()),
            fmt.format((r['closing_dr'] as num?? 0).toDouble()),
            fmt.format((r['closing_cr'] as num?? 0).toDouble()),
          ]],
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7),
          cellStyle: const pw.TextStyle(fontSize: 7),
          cellAlignments: {for (int i = 2; i <= 7; i++) i: pw.Alignment.centerRight},
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF1F5F9)),
        ),
      ],
    ));
    await Printing.layoutPdf(onLayout: (_) async => doc.save(), name: 'trial_balance.pdf');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) => _load());
    final branch = ref.watch(selectedBranchProvider);
    final fmt = NumberFormat('#,##0.00');
    double tDr = _rows.fold(0.0, (s, r) => s + (r['closing_dr'] as num? ?? 0));
    double tCr = _rows.fold(0.0, (s, r) => s + (r['closing_cr'] as num? ?? 0));
    final balanced = (tDr - tCr).abs() < 0.01;

    return Container(
      color: AppTheme.background, padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Trial Balance', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
          IconButton(onPressed: _print, icon: const Icon(Icons.print_outlined), tooltip: 'Print / PDF'),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ]),
        const SizedBox(height: 4),
        Text(branch == null ? 'All Branches' : 'Branch: ${branch['name']}', style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        Row(children: [
          _datePicker('From', _from, (d) { setState(() => _from = d); _load(); }, maxDate: _to),
          const SizedBox(width: 12),
          _datePicker('To', _to, (d) { setState(() => _to = d); _load(); }, minDate: _from),
        ]),
        if (!_loading && _rows.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(children: [
            _card('Accounts', '${_rows.length}', AppTheme.primary),
            const SizedBox(width: 12),
            _card('Total Debit', fmt.format(tDr), AppTheme.primary),
            const SizedBox(width: 12),
            _card('Total Credit', fmt.format(tCr), AppTheme.primary),
            const SizedBox(width: 12),
            _card('Status', balanced ? 'Balanced ✓' : 'Unbalanced ✗', balanced ? AppTheme.success : AppTheme.danger),
          ]),
        ],
        const SizedBox(height: 16),
        Expanded(child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: _loading ? const Center(child: CircularProgressIndicator())
            : _rows.isEmpty ? const Center(child: Text('No data for period.', style: TextStyle(color: AppTheme.textSecondary)))
            : Column(children: [
                _hdr(),
                const Divider(height: 1),
                Expanded(child: ListView.separated(
                  itemCount: _rows.length + 1,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    if (i == _rows.length) return _totals(fmt, tDr, tCr);
                    return _row(fmt, _rows[i]);
                  },
                )),
              ]),
        )),
      ]),
    );
  }

  Widget _datePicker(String label, DateTime date, void Function(DateTime) onPick, {DateTime? minDate, DateTime? maxDate}) =>
    OutlinedButton.icon(
      icon: const Icon(Icons.calendar_today, size: 16),
      label: Text('$label: ${DateFormat('d MMM yyyy').format(date)}'),
      onPressed: () async {
        final d = await showDatePicker(context: context, initialDate: date,
          firstDate: minDate ?? DateTime(2020), lastDate: maxDate ?? DateTime(2100));
        if (d != null) onPick(d);
      },
    );

  Widget _hdr() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
    child: Row(children: [
      const SizedBox(width: 56, child: Text('Code', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
      const Expanded(flex: 3, child: Text('Account', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
      for (final l in ['Open Dr','Open Cr','Period Dr','Period Cr','Close Dr','Close Cr'])
        Expanded(child: Text(l, textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
    ]),
  );

  Widget _row(NumberFormat fmt, Map r) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(children: [
      SizedBox(width: 56, child: Text(r['code']??'', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
      Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(r['name']??'', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        Text(r['account_group']??'', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      ])),
      for (final k in ['opening_dr','opening_cr','period_dr','period_cr','closing_dr','closing_cr'])
        Expanded(child: _amt(fmt, r[k])),
    ]),
  );

  Widget _totals(NumberFormat fmt, double dr, double cr) => Container(
    color: AppTheme.background,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(children: [
      const SizedBox(width: 56),
      const Expanded(flex: 3, child: Text('TOTALS', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12))),
      for (final v in [
        _rows.fold(0.0, (s, r) => s + (r['opening_dr'] as num?? 0)),
        _rows.fold(0.0, (s, r) => s + (r['opening_cr'] as num?? 0)),
        _rows.fold(0.0, (s, r) => s + (r['period_dr']  as num?? 0)),
        _rows.fold(0.0, (s, r) => s + (r['period_cr']  as num?? 0)),
        dr, cr,
      ])
        Expanded(child: Text(fmt.format(v), textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.primary))),
    ]),
  );

  Widget _amt(NumberFormat fmt, dynamic v) {
    final d = (v as num? ?? 0).toDouble();
    return Text(d > 0.005 ? fmt.format(d) : '-', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11));
  }

  Widget _card(String label, String value, Color color) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
    ]),
  );
}
