// ignore_for_file: avoid_web_libraries_in_flutter
import 'package:flutter/material.dart';
import 'dart:html' as html;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpProfitLossScreen extends ConsumerStatefulWidget {
  const ErpProfitLossScreen({super.key});
  @override
  ConsumerState<ErpProfitLossScreen> createState() => _ErpProfitLossScreenState();
}

class _ErpProfitLossScreenState extends ConsumerState<ErpProfitLossScreen> {
  DateTime _from = DateTime(DateTime.now().year, 1, 1);
  DateTime _to   = DateTime.now();
  bool _loading  = false;
  List<Map<String, dynamic>> _rows = [];

  @override void initState() { super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load()); }

  Future<void> _load() async {
    String? orgId = ref.read(currentUserProvider)?.orgId;
    orgId ??= ref.read(selectedBranchProvider)?['org_id'] as String?;
    if (orgId == null) { WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _load(); }); return; }
    setState(() => _loading = true);
    try {
      final branch = ref.read(selectedBranchProvider);
      final res = await Supabase.instance.client.rpc('rpc_profit_loss', params: {
        'p_org_id': orgId,
        'p_date_from': DateFormat('yyyy-MM-dd').format(_from),
        'p_date_to':   DateFormat('yyyy-MM-dd').format(_to),
        'p_branch_id': branch?['id'],
      });
      final rawList = res as List;
      debugPrint('=== P&L RPC rows: \${rawList.length}');
      if (rawList.isNotEmpty) {
        final first = rawList.first as Map<String, dynamic>;
        debugPrint('=== first row: \$first');
        final netVal = first['net'];
        debugPrint('=== net type: ${netVal.runtimeType} value: $netVal');
      }
      setState(() { _rows = List<Map<String, dynamic>>.from(rawList); _loading = false; });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  double _sum(List<Map<String, dynamic>> rows) =>
      rows.fold(0.0, (s, r) => s + _n(r['net']));


  void _print() {
    final fmt = NumberFormat('#,##0.00');
    final revenue = _rows.where((r) => r['account_type'] == 'revenue').toList();
    final cogs    = _rows.where((r) => r['account_type'] == 'expense' && r['account_group'] == 'Cost of Goods Sold').toList();
    final opex    = _rows.where((r) => r['account_type'] == 'expense' && r['account_group'] != 'Cost of Goods Sold').toList();
    final totalRevenue = _sum(revenue);
    final totalCogs = _sum(cogs);
    final grossProfit = totalRevenue - totalCogs;
    final totalOpex = _sum(opex);
    final netIncome = grossProfit - totalOpex;
    final branch = ref.read(selectedBranchProvider);
    final branchName = (branch?['name'] as String?) ?? 'All Branches';
    final period = DateFormat('d MMM yyyy').format(_from) + ' to ' + DateFormat('d MMM yyyy').format(_to);

    String fmtNet(double v) => v < 0 ? '(' + fmt.format(v.abs()) + ')' : fmt.format(v);
    String secRows(List<Map<String, dynamic>> rows) {
      final b = StringBuffer();
      for (final r in rows) {
        b.write('<tr><td>' + (r['code'] ?? '').toString() + '</td><td>' + (r['name'] ?? '').toString() + '</td><td class="num">' + fmtNet(_n(r['net'])) + '</td></tr>');
      }
      return b.toString();
    }
    String section(String title, List<Map<String, dynamic>> rows, double total) {
      if (rows.isEmpty) return '';
      return '<tr class="hd"><td colspan="3">' + title + '</td></tr>' + secRows(rows) +
        '<tr class="sub"><td colspan="2">Total ' + title + '</td><td class="num">' + fmt.format(total) + '</td></tr>';
    }

    final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Profit and Loss</title><style>'
      'body{font-family:Arial,sans-serif;padding:18px;color:#000;font-size:11px}h1{font-size:20px;margin:0 0 2px}'
      '.info{font-size:11px;margin:1px 0;color:#444}table{width:100%;border-collapse:collapse;margin-top:14px}'
      'td{padding:4px 8px;border-bottom:1px solid #eee;font-size:10.5px}.num{text-align:right;white-space:nowrap}'
      '.hd td{font-weight:800;background:#f0f4ff;border-top:1px solid #ccc}.sub td{font-weight:700;border-top:1px solid #999}'
      '.gp td{font-weight:800;background:#eef}.net td{font-weight:800;font-size:13px;background:#f5f5f5;border-top:2px solid #000}'
      '@page{margin:0.6cm}</style></head><body>'
      '<div class="no-print" style="margin-bottom:12px"><button onclick="window.print()">Print</button></div>'
      '<h1>Profit and Loss</h1>'
      '<div class="info"><b>Period:</b> ' + period + '</div>'
      '<div class="info"><b>Branch:</b> ' + branchName + '</div>'
      '<table><tbody>'
      + section('REVENUE', revenue, totalRevenue)
      + section('COST OF GOODS SOLD', cogs, totalCogs)
      + '<tr class="gp"><td colspan="2">GROSS PROFIT</td><td class="num">' + fmt.format(grossProfit) + '</td></tr>'
      + section('OPERATING EXPENSES', opex, totalOpex)
      + '<tr class="net"><td colspan="2">' + (netIncome >= 0 ? 'NET INCOME' : 'NET LOSS') + '</td><td class="num">' + fmt.format(netIncome.abs()) + '</td></tr>'
      + '</tbody></table></body></html>';
    final blob = html.Blob([doc], 'text/html;charset=utf-8');
    html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
  }

  static double _n(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }
  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) => _load());
    final branch = ref.watch(selectedBranchProvider);
    final fmt = NumberFormat('#,##0.00');

    final revenue = _rows.where((r) => r['account_type'] == 'revenue').toList();
    final cogs    = _rows.where((r) => r['account_type'] == 'expense' && r['account_group'] == 'Cost of Goods Sold').toList();
    final opex    = _rows.where((r) => r['account_type'] == 'expense' && r['account_group'] != 'Cost of Goods Sold').toList();

    final totalRevenue = _sum(revenue);
    final totalCogs    = _sum(cogs);
    final grossProfit  = totalRevenue - totalCogs;
    final totalOpex    = _sum(opex);
    final netIncome    = grossProfit - totalOpex;

    return Container(
      color: AppTheme.background, padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Profit & Loss', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
          IconButton(onPressed: (_loading || _rows.isEmpty) ? null : _print, icon: const Icon(Icons.print_outlined), tooltip: 'Print / PDF'),
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
            _card('Revenue', fmt.format(totalRevenue), AppTheme.success),
            const SizedBox(width: 12),
            _card('COGS', fmt.format(totalCogs), AppTheme.warning),
            const SizedBox(width: 12),
            _card('Gross Profit', fmt.format(grossProfit), AppTheme.primary),
            const SizedBox(width: 12),
            _card('Operating Expenses', fmt.format(totalOpex), Colors.orange),
            const SizedBox(width: 12),
            _card(netIncome >= 0 ? 'Net Income' : 'Net Loss', fmt.format(netIncome.abs()),
                netIncome >= 0 ? AppTheme.success : AppTheme.danger),
          ]),
        ],
        const SizedBox(height: 16),
        Expanded(child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: _loading ? const Center(child: CircularProgressIndicator())
            : _rows.isEmpty ? const Center(child: Text('No data for period.', style: TextStyle(color: AppTheme.textSecondary)))
            : ListView(padding: const EdgeInsets.all(24), children: [
                _section(fmt, 'REVENUE', revenue, totalRevenue, AppTheme.success),
                _section(fmt, 'COST OF GOODS SOLD', cogs, totalCogs, AppTheme.warning),
                _subtotal(fmt, 'GROSS PROFIT', grossProfit, AppTheme.primary),
                const SizedBox(height: 8),
                _section(fmt, 'OPERATING EXPENSES', opex, totalOpex, Colors.orange),
                const Divider(thickness: 2),
                const SizedBox(height: 8),
                _bigLine(fmt, netIncome >= 0 ? 'NET INCOME' : 'NET LOSS', netIncome,
                    netIncome >= 0 ? AppTheme.success : AppTheme.danger),
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

  Widget _section(NumberFormat fmt, String title, List<Map<String, dynamic>> rows, double total, Color color) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: color))),
      for (final r in rows)
        Padding(padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
          child: Row(children: [
            SizedBox(width: 48, child: Text(r['code']??'', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
            Expanded(child: Text(r['name']??'', style: const TextStyle(fontSize: 12))),
            Text(_fmtNet(fmt, _n(r['net'])),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: (r['net'] as num?? 0) < 0 ? AppTheme.danger : null)),
          ])),
      const Divider(),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          Expanded(child: Text('Total $title', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          Text(fmt.format(total), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: color)),
        ])),
      const SizedBox(height: 8),
    ]);
  }

  Widget _subtotal(NumberFormat fmt, String label, double value, Color color) => Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(color: color.withOpacity(0.07), borderRadius: BorderRadius.circular(6)),
    child: Row(children: [
      Expanded(child: Text(label, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: color))),
      Text(fmt.format(value), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: color)),
    ]),
  );

  Widget _bigLine(NumberFormat fmt, String label, double value, Color color) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3))),
    child: Row(children: [
      Expanded(child: Text(label, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: color))),
      Text(fmt.format(value.abs()), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, color: color)),
    ]),
  );

  String _fmtNet(NumberFormat fmt, double v) => v < 0 ? '(${fmt.format(v.abs())})' : fmt.format(v);

  Widget _card(String label, String value, Color color) => Expanded(child: Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
    ]),
  ));
}
