// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart' as xlsx;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

/// Account Activity Report — general-ledger drill-down for any Chart-of-Accounts
/// account (CoA only; not suppliers/customers). Shows opening balance, every
/// posted transaction in the period with a running balance, and the closing
/// balance. Backed by rpc_account_ledger + rpc_account_opening (SECURITY DEFINER).
class ErpAccountActivityScreen extends ConsumerStatefulWidget {
  const ErpAccountActivityScreen({super.key});
  @override
  ConsumerState<ErpAccountActivityScreen> createState() => _State();
}

class _State extends ConsumerState<ErpAccountActivityScreen> {
  List<Map<String, dynamic>> _accounts = [];   // level-3 CoA
  bool _loadingMaster = true;

  Map<String, dynamic>? _account;
  final _accCtrl = TextEditingController();
  final _accFocus = FocusNode();
  bool _showAccDrop = false;
  String _accQuery = '';

  late DateTime _dateFrom;
  late DateTime _dateTo;
  bool _accumulated = true;       // all branches vs current sidebar branch
  bool _detailed = true;          // Detailed (line table) vs Summary (totals only)

  bool _loading = false;
  bool _loaded = false;
  double _opening = 0;
  List<Map<String, dynamic>> _entries = [];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  Map<String, dynamic>? get _sidebarBranch => ref.read(selectedBranchProvider);
  bool get _isAdminTier { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.superAdmin || r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  String? get _effectiveBranchId => _isAdminTier ? (_accumulated ? null : _sidebarBranch?['id'] as String?) : (_sidebarBranch?['id'] as String?);

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    // Fiscal year start (Jul 1), matching common local convention.
    _dateFrom = now.month >= 7 ? DateTime(now.year, 7, 1) : DateTime(now.year - 1, 7, 1);
    _dateTo = now;
    _accFocus.addListener(() {
      if (!_accFocus.hasFocus) {
        Future.delayed(const Duration(milliseconds: 160), () { if (mounted && !_accFocus.hasFocus) setState(() => _showAccDrop = false); });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAccounts());
  }

  @override
  void dispose() { _accCtrl.dispose(); _accFocus.dispose(); super.dispose(); }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadAccounts() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 500)); if (mounted) _loadAccounts(); return; }
    try {
      final res = await Supabase.instance.client.rpc('get_voucher_master', params: {'p_org_id': orgId});
      final data = res as Map<String, dynamic>;
      final coa = List<Map<String, dynamic>>.from((data['coa'] as List?) ?? []);
      final items = coa.where((a) => !coa.any((b) => b['parent_id'] == a['id'])).map((a) => {
        'id': a['id'],
        'code': a['code'],
        'name': a['name'],
        'account_type': a['account_type'],
        'account_group': a['account_group'],
        'label': "${a['code'] != null ? '${a['code']} — ' : ''}${a['name']}",
      }).toList();
      if (mounted) setState(() { _accounts = items; _loadingMaster = false; });
    } catch (e) { if (mounted) { _snack('Account load error: $e'); setState(() => _loadingMaster = false); } }
  }

  List<Map<String, dynamic>> _filterAccounts(String q) {
    if (q.isEmpty) return _accounts.take(50).toList();
    final ql = q.toLowerCase();
    return _accounts.where((a) =>
      (a['label'] as String? ?? '').toLowerCase().contains(ql) ||
      (a['account_group'] as String? ?? '').toLowerCase().contains(ql)
    ).take(200).toList();
  }

  void _pickAccount(Map<String, dynamic> a) {
    setState(() { _account = a; _accCtrl.text = a['label'] as String? ?? ''; _showAccDrop = false; _loaded = false; _entries = []; });
    _accFocus.unfocus();
  }

  Future<void> _loadReport() async {
    final orgId = _orgId;
    if (orgId == null) { _snack('Not authenticated'); return; }
    if (_account == null) { _snack('Select an account first'); return; }
    setState(() { _loading = true; _loaded = false; });
    try {
      final client = Supabase.instance.client;
      final accId = _account!['id'] as String;
      final from = DateFormat('yyyy-MM-dd').format(_dateFrom);
      final to = DateFormat('yyyy-MM-dd').format(_dateTo);
      final bid = _effectiveBranchId;

      final openRes = await client.rpc('rpc_account_opening', params: {
        'p_org_id': orgId, 'p_account_id': accId, 'p_date_from': from, 'p_branch_id': bid,
      });
      final opening = (openRes as num?)?.toDouble() ?? 0;

      final rows = await client.rpc('rpc_account_ledger', params: {
        'p_org_id': orgId, 'p_account_id': accId, 'p_date_from': from, 'p_date_to': to, 'p_branch_id': bid,
      });
      final entries = List<Map<String, dynamic>>.from((rows as List?) ?? []);

      double bal = opening;
      for (final e in entries) {
        final dr = (e['debit'] as num?)?.toDouble() ?? 0;
        final cr = (e['credit'] as num?)?.toDouble() ?? 0;
        bal += dr - cr;
        e['balance'] = bal;
      }
      if (mounted) setState(() { _opening = opening; _entries = entries; _loaded = true; _loading = false; });
    } catch (e) {
      if (mounted) { _snack('Report error: $e'); setState(() => _loading = false); }
    }
  }

  void _reset() {
    final now = DateTime.now();
    setState(() {
      _account = null; _accCtrl.clear(); _entries = []; _loaded = false; _opening = 0;
      _accumulated = true; _detailed = true;
      _dateFrom = now.month >= 7 ? DateTime(now.year, 7, 1) : DateTime(now.year - 1, 7, 1);
      _dateTo = now;
    });
  }

  double get _periodDr => _entries.fold(0, (s, e) => s + ((e['debit'] as num?)?.toDouble() ?? 0));
  double get _periodCr => _entries.fold(0, (s, e) => s + ((e['credit'] as num?)?.toDouble() ?? 0));
  double get _closing => _opening + _periodDr - _periodCr;

  String _bal(double v) {
    final fmt = NumberFormat('#,##0.00');
    final dc = v >= 0 ? 'Dr' : 'Cr';
    return 'Rs. ${fmt.format(v.abs())} $dc';
  }

  Color _typeColor(String? t) {
    switch (t) {
      case 'asset': return Colors.blue;
      case 'liability': return Colors.red;
      case 'equity': return Colors.purple;
      case 'revenue': return Colors.green;
      case 'expense': return Colors.orange;
      default: return AppTheme.textSecondary;
    }
  }

  void _print() {
    if (!_loaded || _account == null) return;
    final fmt = NumberFormat('#,##0.00');
    final branch = _effectiveBranchId == null ? 'Accumulated (All Branches)' : ((_sidebarBranch?['name'] as String?) ?? '-');
    final rows = StringBuffer();
    rows.write('<tr><td colspan="5"><b>Opening Balance</b></td><td class="num bold">' + _bal(_opening) + '</td></tr>');
    for (final e in _entries) {
      final ds = (e['entry_date'] as String?) ?? '';
      final dt = DateTime.tryParse(ds);
      final date = dt != null ? DateFormat('d MMM yy').format(dt) : ds;
      final dr = (e['debit'] as num?)?.toDouble() ?? 0;
      final cr = (e['credit'] as num?)?.toDouble() ?? 0;
      final bal = (e['balance'] as num?)?.toDouble() ?? 0;
      rows.write('<tr><td>' + date + '</td><td>' + ((e['entry_number'] as String?) ?? '') + '</td><td>' + ((e['description'] as String?) ?? '') + '</td><td class="num">' + (dr > 0 ? fmt.format(dr) : '') + '</td><td class="num">' + (cr > 0 ? fmt.format(cr) : '') + '</td><td class="num bold">' + _bal(bal) + '</td></tr>');
    }
    final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Account Activity</title><style>'
      'body{font-family:Arial,sans-serif;padding:16px;font-size:11px;color:#000;-webkit-user-select:text;user-select:text}h1{font-size:18px;margin:0 0 4px}'
      '.info{font-size:11px;margin:2px 0}table{width:100%;border-collapse:collapse;margin-top:10px}'
      'th,td{border:1px solid #999;padding:5px 7px;text-align:left;font-size:10px}'
      'th{background:#f0f4ff;font-weight:700;border-bottom:1.5px solid #000}.num{text-align:right;white-space:nowrap}.bold{font-weight:800}'
      'tfoot td{font-weight:800;background:#f5f5f5;border-top:2px solid #000}@page{margin:0.5cm}</style></head><body>'
      '<div class="no-print" style="margin-bottom:10px"><button onclick="window.print()">Print</button></div>'
      '<h1>Account Activity Report</h1>'
      '<div class="info"><b>Account:</b> ' + (_account!['label'] as String? ?? '') + '</div>'
      '<div class="info"><b>Period:</b> ' + DateFormat('d MMM yyyy').format(_dateFrom) + ' to ' + DateFormat('d MMM yyyy').format(_dateTo) + '</div>'
      '<div class="info"><b>Branch:</b> ' + branch + '</div>'
      '<table><thead><tr><th>Date</th><th>Voucher</th><th>Description</th><th class="num">Debit</th><th class="num">Credit</th><th class="num">Balance</th></tr></thead>'
      '<tbody>' + rows.toString() + '</tbody>'
      '<tfoot><tr><td colspan="3">Closing</td><td class="num">' + fmt.format(_periodDr) + '</td><td class="num">' + fmt.format(_periodCr) + '</td><td class="num">' + _bal(_closing) + '</td></tr></tfoot>'
      '</table></body></html>';
    final blob = html.Blob([doc], 'text/html;charset=utf-8');
    html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.00');
    final accFiltered = _filterAccounts(_accQuery);
    final branchName = (_sidebarBranch?['name'] as String?) ?? 'Current Branch';

    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Account Activity Report', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (_loaded && _entries.isNotEmpty) Row(children: [
            OutlinedButton.icon(icon: const Icon(Icons.table_view_outlined, size: 16), label: const Text('Excel', style: TextStyle(fontSize: 12)),
              onPressed: _exportExcel, style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10))),
            const SizedBox(width: 8),
            OutlinedButton.icon(icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print / PDF', style: TextStyle(fontSize: 12)),
              onPressed: _print, style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10))),
          ]),
        ]),
        const SizedBox(height: 16),

        // ── Filters ───────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Account picker
              SizedBox(width: 360, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Account *', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                TextField(controller: _accCtrl, focusNode: _accFocus,
                  decoration: InputDecoration(hintText: _loadingMaster ? 'Loading accounts...' : 'Search account...', isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 16),
                    suffixIcon: _account != null ? const Icon(Icons.check_circle, size: 16, color: Colors.green) : null,
                    border: const OutlineInputBorder(), enabledBorder: const OutlineInputBorder()),
                  onChanged: (v) => setState(() { _accQuery = v; _showAccDrop = true; if (v != (_account?['label'] ?? '')) _account = null; }),
                  onTap: () => setState(() { _accQuery = _accCtrl.text == (_account?['label'] ?? '') ? '' : _accCtrl.text; _showAccDrop = true; })),
                if (_showAccDrop && accFiltered.isNotEmpty) Container(
                  constraints: const BoxConstraints(maxHeight: 240), margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(color: Colors.white, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)]),
                  child: ListView(shrinkWrap: true, children: accFiltered.map((a) {
                    final c = _typeColor(a['account_type'] as String?);
                    return InkWell(onTap: () => _pickAccount(a), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Row(children: [
                        Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(3)),
                          child: Text((a['account_group'] as String? ?? a['account_type'] as String? ?? ''), style: TextStyle(fontSize: 9, color: c, fontWeight: FontWeight.w700))),
                        const SizedBox(width: 6),
                        Expanded(child: Text(a['label'] as String? ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                      ])));
                  }).toList())),
              ])),
              const SizedBox(width: 16),
              // Date range
              SizedBox(width: 230, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('As On', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                InkWell(onTap: () async {
                  final picked = await showDateRangePicker(context: context, firstDate: DateTime(2018), lastDate: DateTime(2100),
                    initialDateRange: DateTimeRange(start: _dateFrom, end: _dateTo),
                    builder: (context, child) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420, maxHeight: 600), child: child)));
                  if (picked != null) setState(() { _dateFrom = picked.start; _dateTo = picked.end; });
                }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  decoration: BoxDecoration(border: Border.all(color: const Color(0xFFBDBDBD)), borderRadius: BorderRadius.circular(6)),
                  child: Row(children: [const Icon(Icons.date_range, size: 14, color: AppTheme.textSecondary), const SizedBox(width: 8),
                    Text(DateFormat('dd/MM/yyyy').format(_dateFrom) + ' - ' + DateFormat('dd/MM/yyyy').format(_dateTo), style: const TextStyle(fontSize: 12))]))),
              ])),
              if (_isAdminTier) const SizedBox(width: 16),
              // Branch
              if (_isAdminTier) SizedBox(width: 220, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Branch', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: BoxDecoration(border: Border.all(color: const Color(0xFFBDBDBD)), borderRadius: BorderRadius.circular(6)),
                  child: DropdownButtonHideUnderline(child: DropdownButton<bool>(
                    isExpanded: true, value: _accumulated,
                    items: [
                      const DropdownMenuItem(value: true, child: Text('Accumulated (All Branches)', style: TextStyle(fontSize: 12))),
                      DropdownMenuItem(value: false, child: Text(branchName, style: const TextStyle(fontSize: 12))),
                    ],
                    onChanged: (v) => setState(() => _accumulated = v ?? true),
                  ))),
              ])),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              ElevatedButton(onPressed: _loading ? null : _loadReport,
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
                child: _loading ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Load Report')),
              const SizedBox(width: 10),
              OutlinedButton(onPressed: _reset, child: const Text('Reset')),
              const Spacer(),
              Row(children: [
                _radio('Summary', !_detailed, () => setState(() => _detailed = false)),
                const SizedBox(width: 14),
                _radio('Detailed', _detailed, () => setState(() => _detailed = true)),
              ]),
            ]),
          ]),
        ),
        const SizedBox(height: 16),

        // ── Report ────────────────────────────────────────────────
        if (_loaded) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
            child: Wrap(spacing: 22, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _chip('Opening', _bal(_opening), AppTheme.textPrimary),
              _chip('Debit', 'Rs. ${fmt.format(_periodDr)}', AppTheme.primary),
              _chip('Credit', 'Rs. ${fmt.format(_periodCr)}', Colors.green.shade700),
              _chip('Closing', _bal(_closing), _closing >= 0 ? AppTheme.danger : Colors.green.shade700),
            ]),
          ),
          const SizedBox(height: 10),
          if (_detailed) Expanded(child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
            child: Column(children: [
              Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(10))),
                child: const Row(children: [
                  SizedBox(width: 90, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                  SizedBox(width: 130, child: Text('Voucher', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                  Expanded(child: Text('Description', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                  SizedBox(width: 110, child: Text('Debit', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                  SizedBox(width: 110, child: Text('Credit', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                  SizedBox(width: 130, child: Text('Balance', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                ])),
              const Divider(height: 1),
              // Opening row
              Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9), color: AppTheme.primary.withOpacity(0.04),
                child: Row(children: [
                  const SizedBox(width: 90, child: Text('—', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                  const SizedBox(width: 130),
                  const Expanded(child: Text('Opening Balance', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  const SizedBox(width: 110), const SizedBox(width: 110),
                  SizedBox(width: 130, child: Text(_bal(_opening), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800))),
                ])),
              const Divider(height: 1),
              Expanded(child: _entries.isEmpty
                ? const Center(child: Text('No transactions in this period.', style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.separated(itemCount: _entries.length, separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.border),
                    itemBuilder: (_, i) {
                      final e = _entries[i];
                      final ds = (e['entry_date'] as String?) ?? '';
                      final dt = DateTime.tryParse(ds); final date = dt != null ? DateFormat('d MMM yy').format(dt) : ds;
                      final dr = (e['debit'] as num?)?.toDouble() ?? 0;
                      final cr = (e['credit'] as num?)?.toDouble() ?? 0;
                      final bal = (e['balance'] as num?)?.toDouble() ?? 0;
                      return InkWell(onTap: () => _openVoucher(e), child: Container(color: i.isEven ? null : Colors.grey.shade50, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                        child: Row(children: [
                          SizedBox(width: 90, child: Text(date, style: const TextStyle(fontSize: 12))),
                          SizedBox(width: 130, child: Text((e['entry_number'] as String?) ?? '', style: const TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w600, decoration: TextDecoration.underline), overflow: TextOverflow.ellipsis)),
                          Expanded(child: Text((e['description'] as String?) ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                          SizedBox(width: 110, child: Text(dr > 0 ? fmt.format(dr) : '-', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: dr > 0 ? AppTheme.primary : Colors.black26))),
                          SizedBox(width: 110, child: Text(cr > 0 ? fmt.format(cr) : '-', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cr > 0 ? Colors.green.shade700 : Colors.black26))),
                          SizedBox(width: 130, child: Text(_bal(bal), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                        ])));
                    })),
              Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(bottom: Radius.circular(10)), border: Border(top: BorderSide(color: AppTheme.border))),
                child: Row(children: [
                  const SizedBox(width: 90), const SizedBox(width: 130),
                  Expanded(child: Text('${_entries.length} transactions', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                  SizedBox(width: 110, child: Text(fmt.format(_periodDr), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppTheme.primary))),
                  SizedBox(width: 110, child: Text(fmt.format(_periodCr), textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.green.shade700))),
                  SizedBox(width: 130, child: Text(_bal(_closing), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800))),
                ])),
            ]),
          )),
        ] else Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.account_balance_outlined, size: 52, color: AppTheme.textSecondary.withOpacity(0.3)),
          const SizedBox(height: 12),
          const Text('Select an account and date range, then Load Report', style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
        ]))),
      ]),
    );
  }

  void _exportExcel() {
    if (!_loaded || _account == null) return;
    final fmt = NumberFormat('#,##0.00');
    final book = xlsx.Excel.createExcel();
    const sheetName = 'Account Activity';
    final sheet = book[sheetName];
    book.setDefaultSheet(sheetName);
    if (book.sheets.containsKey('Sheet1')) book.delete('Sheet1');

    final branch = _effectiveBranchId == null ? 'Accumulated (All Branches)' : ((_sidebarBranch?['name'] as String?) ?? '-');
    sheet.appendRow([xlsx.TextCellValue('Account Activity Report')]);
    sheet.appendRow([xlsx.TextCellValue('Account:'), xlsx.TextCellValue(_account!['label'] as String? ?? '')]);
    sheet.appendRow([xlsx.TextCellValue('Period:'), xlsx.TextCellValue(DateFormat('d MMM yyyy').format(_dateFrom) + ' to ' + DateFormat('d MMM yyyy').format(_dateTo))]);
    sheet.appendRow([xlsx.TextCellValue('Branch:'), xlsx.TextCellValue(branch)]);
    sheet.appendRow([]);
    sheet.appendRow([
      xlsx.TextCellValue('Date'), xlsx.TextCellValue('Voucher'), xlsx.TextCellValue('Description'),
      xlsx.TextCellValue('Debit'), xlsx.TextCellValue('Credit'), xlsx.TextCellValue('Balance'),
    ]);
    sheet.appendRow([
      xlsx.TextCellValue(''), xlsx.TextCellValue(''), xlsx.TextCellValue('Opening Balance'),
      xlsx.TextCellValue(''), xlsx.TextCellValue(''), xlsx.TextCellValue(_bal(_opening)),
    ]);
    for (final e in _entries) {
      final ds = (e['entry_date'] as String?) ?? '';
      final dt = DateTime.tryParse(ds);
      final date = dt != null ? DateFormat('d MMM yy').format(dt) : ds;
      final dr = (e['debit'] as num?)?.toDouble() ?? 0;
      final cr = (e['credit'] as num?)?.toDouble() ?? 0;
      final bal = (e['balance'] as num?)?.toDouble() ?? 0;
      sheet.appendRow([
        xlsx.TextCellValue(date),
        xlsx.TextCellValue((e['entry_number'] as String?) ?? ''),
        xlsx.TextCellValue((e['description'] as String?) ?? ''),
        dr > 0 ? xlsx.DoubleCellValue(dr) : xlsx.TextCellValue(''),
        cr > 0 ? xlsx.DoubleCellValue(cr) : xlsx.TextCellValue(''),
        xlsx.TextCellValue(_bal(bal)),
      ]);
    }
    sheet.appendRow([
      xlsx.TextCellValue(''), xlsx.TextCellValue(''), xlsx.TextCellValue('Closing (${_entries.length} transactions)'),
      xlsx.DoubleCellValue(_periodDr), xlsx.DoubleCellValue(_periodCr), xlsx.TextCellValue(_bal(_closing)),
    ]);

    final bytes = book.encode();
    if (bytes == null) return;
    final blob = html.Blob([Uint8List.fromList(bytes)], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final safe = (_account!['label'] as String? ?? 'account').replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    html.AnchorElement(href: url)..setAttribute('download', 'account_activity_$safe.xlsx')..click();
    html.Url.revokeObjectUrl(url);
  }

  Widget _chip(String label, String value, Color color) => Row(mainAxisSize: MainAxisSize.min, children: [
    Text('$label: ', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
    Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: color)),
  ]);

  String _acctName(String? id) {
    final a = _accounts.firstWhere((x) => x['id'] == id, orElse: () => const <String, dynamic>{});
    return (a['label'] as String?) ?? (id ?? '-');
  }

  Future<void> _openVoucher(Map<String, dynamic> e) async {
    final orgId = _orgId;
    final entryNo = (e['entry_number'] as String?) ?? '';
    if (orgId == null || entryNo.isEmpty) return;
    try {
      final client = Supabase.instance.client;
      final hdr = await client.from('journal_entries')
          .select('id, entry_date, entry_number, reference_type, reference_number, description, status')
          .eq('org_id', orgId).eq('entry_number', entryNo).limit(1);
      if ((hdr as List).isEmpty) { _snack('Voucher not found'); return; }
      final h = Map<String, dynamic>.from(hdr.first as Map);
      final linesRes = await client.from('journal_lines')
          .select('account_id, debit, credit, description')
          .eq('entry_id', h['id'] as String);
      final lines = List<Map<String, dynamic>>.from(linesRes as List);
      if (!mounted) return;
      showDialog(context: context, builder: (_) => _voucherDialog(h, lines));
    } catch (err) { _snack('Open failed: $err'); }
  }

  Widget _voucherDialog(Map<String, dynamic> h, List<Map<String, dynamic>> lines) {
    final fmt = NumberFormat('#,##0.00');
    final ds = (h['entry_date'] as String?) ?? '';
    final dt = DateTime.tryParse(ds);
    final date = dt != null ? DateFormat('d MMM yyyy').format(dt) : ds;
    final refType = (h['reference_type'] as String?) ?? '';
    final refNum = (h['reference_number'] as String?) ?? '';
    final sub = [date, if (refType.isNotEmpty) refType, if (refNum.isNotEmpty) refNum].join('  ·  ');
    double tdr = 0, tcr = 0;
    for (final l in lines) { tdr += (l['debit'] as num?)?.toDouble() ?? 0; tcr += (l['credit'] as num?)?.toDouble() ?? 0; }
    return Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(padding: const EdgeInsets.all(16), decoration: const BoxDecoration(color: AppTheme.background),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((h['entry_number'] as String?) ?? 'Voucher', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(sub, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ])),
            IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.pop(context)),
          ])),
        if (((h['description'] as String?) ?? '').isNotEmpty)
          Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 0), child: Text(h['description'] as String, style: const TextStyle(fontSize: 12))),
        const SizedBox(height: 10),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
          Expanded(child: Text('Account', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          SizedBox(width: 110, child: Text('Debit', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          SizedBox(width: 110, child: Text('Credit', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
        ])),
        const Divider(height: 12),
        Flexible(child: ListView.separated(shrinkWrap: true, itemCount: lines.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final l = lines[i];
            final dr = (l['debit'] as num?)?.toDouble() ?? 0;
            final cr = (l['credit'] as num?)?.toDouble() ?? 0;
            return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7), child: Row(children: [
              Expanded(child: Text(_acctName(l['account_id'] as String?), style: const TextStyle(fontSize: 12))),
              SizedBox(width: 110, child: Text(dr > 0 ? fmt.format(dr) : '', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: AppTheme.primary))),
              SizedBox(width: 110, child: Text(cr > 0 ? fmt.format(cr) : '', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: Colors.green.shade700))),
            ]));
          })),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          const Expanded(child: Text('Total', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800))),
          SizedBox(width: 110, child: Text(fmt.format(tdr), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppTheme.primary))),
          SizedBox(width: 110, child: Text(fmt.format(tcr), textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.green.shade700))),
        ])),
      ])));
  }

  Widget _radio(String label, bool selected, VoidCallback onTap) => InkWell(onTap: onTap, child: Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, size: 18, color: selected ? AppTheme.primary : AppTheme.textSecondary),
    const SizedBox(width: 5),
    Text(label, style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: selected ? AppTheme.primary : AppTheme.textPrimary)),
  ]));

  Widget _stat(String label, String value, Color color, {bool bold = false}) => Expanded(child: Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      Text(value, style: TextStyle(fontSize: bold ? 18 : 15, fontWeight: FontWeight.w700, color: color)),
    ]),
  ));
}
