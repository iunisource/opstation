import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpBalanceSheetScreen extends ConsumerStatefulWidget {
  const ErpBalanceSheetScreen({super.key});
  @override
  ConsumerState<ErpBalanceSheetScreen> createState() => _ErpBalanceSheetScreenState();
}

class _ErpBalanceSheetScreenState extends ConsumerState<ErpBalanceSheetScreen> {
  DateTime _asOf   = DateTime.now();
  bool _loading    = false;
  List<Map<String, dynamic>> _bsRows = [];
  double _netIncome = 0;

  @override void initState() { super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load()); }

  Future<void> _load() async {
    String? orgId = ref.read(currentUserProvider)?.orgId;
    orgId ??= ref.read(selectedBranchProvider)?['org_id'] as String?;
    if (orgId == null) { WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _load(); }); return; }
    setState(() => _loading = true);
    try {
      final branch = ref.read(selectedBranchProvider);
      final branchId = branch?['id'] as String?;
      // Balance sheet rows
      List<Map<String, dynamic>> bsRows = [];
      try {
        final params = <String, dynamic>{
          'p_org_id': orgId,
          'p_as_of': DateFormat('yyyy-MM-dd').format(_asOf),
        };        final bsRes = await Supabase.instance.client.rpc('rpc_balance_sheet', params: params);
        bsRows = List<Map<String, dynamic>>.from(bsRes as List);
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Balance sheet error: \$e'), duration: const Duration(seconds: 6)));
      }

      // Net income from P&L
      double ni = 0;
      try {
        final params = <String, dynamic>{
          'p_org_id': orgId,
          'p_date_from': DateFormat('yyyy-MM-dd').format(DateTime(_asOf.year, 1, 1)),
          'p_date_to':   DateFormat('yyyy-MM-dd').format(_asOf),
        };        final plRes = await Supabase.instance.client.rpc('rpc_profit_loss', params: params);
        for (final r in plRes as List) {
          final net = (r['net'] as num? ?? 0).toDouble();
          ni += r['account_type'] == 'revenue' ? net : -net;
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('P&L error: \$e'), duration: const Duration(seconds: 6)));
      }

      setState(() { _bsRows = bsRows; _netIncome = ni; _loading = false; });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: \$e')));
    }
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

    final assets  = _bsRows.where((r) => r['account_type'] == 'asset').toList();
    final liabs   = _bsRows.where((r) => r['account_type'] == 'liability').toList();
    final equity  = _bsRows.where((r) => r['account_type'] == 'equity').toList();

    double sumBal(List<Map<String, dynamic>> rows) =>
        rows.fold(0.0, (s, r) => s + _n(r['balance']));
    final totalAssets = sumBal(assets);
    final totalLiabs  = sumBal(liabs);
    final totalEquity = sumBal(equity) + _netIncome;
    final balanced    = (totalAssets - (totalLiabs + totalEquity)).abs() < 0.01;

    return Container(
      color: AppTheme.background, padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Balance Sheet', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ]),
        const SizedBox(height: 4),
        Text(branch == null ? 'All Branches' : 'Branch: ${branch['name']}', style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          icon: const Icon(Icons.calendar_today, size: 16),
          label: Text('As of: ${DateFormat('d MMM yyyy').format(_asOf)}'),
          onPressed: () async {
            final d = await showDatePicker(context: context, initialDate: _asOf, firstDate: DateTime(2020), lastDate: DateTime(2100));
            if (d != null) { setState(() => _asOf = d); _load(); }
          },
        ),
        if (!_loading && _bsRows.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(children: [
            _card('Total Assets', fmt.format(totalAssets), AppTheme.primary),
            const SizedBox(width: 12),
            _card('Total Liabilities', fmt.format(totalLiabs), AppTheme.danger),
            const SizedBox(width: 12),
            _card('Total Equity', fmt.format(totalEquity), AppTheme.success),
            const SizedBox(width: 12),
            _card('Check', balanced ? 'Balanced ✓' : 'Off by ${fmt.format((totalAssets - totalLiabs - totalEquity).abs())}',
                balanced ? AppTheme.success : AppTheme.danger),
          ]),
        ],
        const SizedBox(height: 16),
        Expanded(child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: _loading ? const Center(child: CircularProgressIndicator())
            : _bsRows.isEmpty ? const Center(child: Text('No data.', style: TextStyle(color: AppTheme.textSecondary)))
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _column(fmt, 'ASSETS', assets, totalAssets, AppTheme.primary,
                    footer: 'TOTAL ASSETS')),
                const VerticalDivider(width: 1),
                Expanded(child: ListView(padding: const EdgeInsets.all(20), children: [
                  _section(fmt, 'LIABILITIES', liabs, totalLiabs, AppTheme.danger),
                  const SizedBox(height: 12),
                  _section(fmt, 'EQUITY', equity, totalEquity, AppTheme.success, netIncome: _netIncome),
                  const Divider(thickness: 2),
                  Padding(padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      const Expanded(child: Text('TOTAL LIABILITIES + EQUITY',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13))),
                      Text(fmt.format(totalLiabs + totalEquity),
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppTheme.primary)),
                    ])),
                ])),
              ]),
        )),
      ]),
    );
  }

  Widget _column(NumberFormat fmt, String title, List<Map<String, dynamic>> rows, double total, Color color, {required String footer}) =>
    ListView(padding: const EdgeInsets.all(20), children: [
      _section(fmt, title, rows, total, color),
      const Divider(thickness: 2),
      Padding(padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(child: Text(footer, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13))),
          Text(fmt.format(total), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppTheme.primary)),
        ])),
    ]);

  Widget _section(NumberFormat fmt, String title, List<Map<String, dynamic>> rows, double total, Color color, {double? netIncome}) =>
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: color))),
      for (final r in rows)
        Padding(padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Row(children: [
            SizedBox(width: 48, child: Text(r['code']??'', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
            Expanded(child: Text(r['name']??'', style: const TextStyle(fontSize: 12))),
            Text(fmt.format(_n(r['balance'])), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ])),
      if (netIncome != null && netIncome!.abs() > 0.005)
        Padding(padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Row(children: [
            const SizedBox(width: 48, child: Text('P&L', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
            const Expanded(child: Text('Current Year Profit / Loss', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic))),
            Text(netIncome! < 0 ? '(${fmt.format(netIncome!.abs())})' : fmt.format(netIncome!),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: netIncome! >= 0 ? AppTheme.success : AppTheme.danger)),
          ])),
      const Divider(),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(children: [
          Expanded(child: Text('Total $title', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          Text(fmt.format(total), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: color)),
        ])),
      const SizedBox(height: 8),
    ]);

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
