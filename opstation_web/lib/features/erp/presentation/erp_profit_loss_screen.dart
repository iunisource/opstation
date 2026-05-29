import 'package:flutter/material.dart';
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
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final branch = ref.read(selectedBranchProvider);
      final res = await Supabase.instance.client.rpc('rpc_profit_loss', params: {
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

  double _sum(List<Map<String, dynamic>> rows) =>
      rows.fold(0.0, (s, r) => s + (r['net'] as num? ?? 0).toDouble());

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
            Text(_fmtNet(fmt, (r['net'] as num?? 0).toDouble()),
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
