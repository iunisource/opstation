// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpSupplierLedgerScreen extends ConsumerStatefulWidget {
  const ErpSupplierLedgerScreen({super.key});
  @override
  ConsumerState<ErpSupplierLedgerScreen> createState() => _ErpSupplierLedgerScreenState();
}

class _ErpSupplierLedgerScreenState extends ConsumerState<ErpSupplierLedgerScreen> {
  List<Map<String, dynamic>> _suppliers = [];
  Map<String, dynamic>? _selectedSupplier;
  List<Map<String, dynamic>> _filteredSuppliers = [];
  bool _loadingCustomers = true;
  bool _showDropdown = false;
  int _highlightIndex = -1;
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  List<Map<String, dynamic>> _entries = [];
  List<String> _errors = [];
  bool _loading = false;

  DateTime? _dateFrom;
  DateTime? _dateTo;
  String _typeFilter = 'All';
  final _entrySearchCtrl = TextEditingController();

  static const _types = ['All', 'Purchase Invoice', 'Purchase Return', 'Receipt (CRV)', 'Payment (CPV)'];

  @override
  void initState() {
    super.initState();
    _loadSuppliers();
    _searchCtrl.addListener(_onSearchChanged);
    _entrySearchCtrl.addListener(() => setState(() {}));
    _searchFocus.addListener(() { if (_searchFocus.hasFocus) setState(() { _showDropdown = true; if (_searchCtrl.text.isEmpty) _filteredSuppliers = _suppliers; }); });
  }

  @override
  void dispose() { _searchCtrl.dispose(); _searchFocus.dispose(); _entrySearchCtrl.dispose(); super.dispose(); }

  void _onSearchChanged() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _highlightIndex = -1;
      _showDropdown = true;
      _filteredSuppliers = q.isEmpty ? _suppliers : _suppliers.where((c) =>
          (c['name'] as String? ?? '').toLowerCase().contains(q) ||
          (c['code'] as String? ?? '').toLowerCase().contains(q)).toList();
    });
  }

  void _selectSupplier(Map<String, dynamic> c) {
    setState(() {
      _selectedSupplier = c; _entries = []; _showDropdown = false; _highlightIndex = -1;
      _searchCtrl.text = '${c['name']}${c['code'] != null ? ' (${c['code']})' : ''}';
    });
    _persist();
    _loadLedger(c['id'] as String);
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _loadSuppliers() async {
    final orgId = _orgId; if (orgId == null) { setState(() => _loadingCustomers = false); return; }
    try {
      final List<Map<String, dynamic>> all = [];
      int from = 0; const pageSize = 1000;
      while (true) {
        final page = await Supabase.instance.client.from('suppliers')
            .select('id, name').eq('org_id', orgId)
            .order('name').range(from, from + pageSize - 1);
        final list = List<Map<String, dynamic>>.from(page);
        all.addAll(list);
        if (list.length < pageSize) break;
        from += pageSize;
        if (from > 100000) break;
      }
      if (mounted) setState(() { _suppliers = all; _filteredSuppliers = _suppliers; _loadingCustomers = false; });
      _restoreState();
    } catch (e) {
      if (mounted) setState(() => _loadingCustomers = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Suppliers load error: $e'), behavior: SnackBarBehavior.floating));
    }
  }

  void _restoreState() {
    try {
      final s = html.window.localStorage;
      final cid = s['ledger_supplier_id'];
      if (cid == null || cid.isEmpty) return;
      final m = _suppliers.where((c) => c['id'] == cid).toList();
      if (m.isEmpty) return;
      final dfStr = s['ledger_date_from'];
      final dtStr = s['ledger_date_to'];
      if (dfStr != null && dfStr.isNotEmpty) _dateFrom = DateTime.tryParse(dfStr);
      if (dtStr != null && dtStr.isNotEmpty) _dateTo = DateTime.tryParse(dtStr);
      final tf = s['ledger_type_filter'];
      if (tf != null && _types.contains(tf)) _typeFilter = tf;
      _selectSupplier(m.first);
    } catch (_) {}
  }

  void _persist() {
    try {
      final s = html.window.localStorage;
      if (_selectedSupplier != null) s['ledger_supplier_id'] = _selectedSupplier!['id'] as String;
      else s.remove('ledger_supplier_id');
      if (_dateFrom != null) s['ledger_date_from'] = _dateFrom!.toIso8601String();
      else s.remove('ledger_date_from');
      if (_dateTo != null) s['ledger_date_to'] = _dateTo!.toIso8601String();
      else s.remove('ledger_date_to');
      s['ledger_type_filter'] = _typeFilter;
    } catch (_) {}
  }

  Future<void> _loadLedger(String supplierId) async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null) return;
    setState(() { _loading = true; _entries = []; _errors = []; });
    final client = Supabase.instance.client;
    final List<Map<String, dynamic>> entries = [];
    final List<String> errors = [];

    String extractDate(Map v, List<String> fields) {
      for (final f in fields) {
        final val = v[f];
        if (val == null) continue;
        String? s;
        if (val is String && val.isNotEmpty) s = val;
        else if (val is DateTime) s = val.toIso8601String();
        else { final t = val.toString(); if (t.isNotEmpty && t != 'null') s = t; }
        if (s != null && DateTime.tryParse(s) != null) return s;
      }
      return '';
    }

    // 1. Sales Invoices -> Debit
    try {
      var siQ = client.from('purchase_invoices').select('*')
          .eq('org_id', orgId).eq('supplier_id', supplierId);
      if (branchId != null) siQ = siQ.eq('branch_id', branchId);
      final sis = await siQ;
      for (final si in sis as List) {
        final total = ((si['total'] ?? si['total_amount'] ?? si['grand_total'] ?? si['net_amount']) as num?)?.toDouble() ?? 0;
        final vno = ((si['invoice_number'] ?? si['voucher_number'] ?? si['si_number'] ?? '') as String);
        final date = extractDate(si as Map, const ['voucher_date', 'invoice_date', 'si_date', 'date', 'posted_at', 'created_at']);
        if (total > 0) {
          entries.add({
            'date': date, 'voucher': vno,
            'description': vno.isNotEmpty ? 'Purchase Invoice ' + vno : 'Purchase Invoice',
            'debit': total, 'credit': 0.0, 'id': si['id'] as String?, 'type': 'Purchase Invoice',
          });
        }
      }
    } catch (e) { errors.add('SI: ' + e.toString()); }

// 3. Purchase Return Invoices (SRI) -> Credit
    String? priTable;
    int priRows = 0;
    int priAdded = 0;
    Map? firstPriRow;
    for (final tbl in const ['purchase_return_invoices', 'sale_return_invoices', 'sales_returns', 'sale_returns', 'sri_vouchers', 'srn_vouchers', 'sri']) {
      try {
        var q = client.from(tbl).select('*')
            .eq('org_id', orgId).eq('supplier_id', supplierId);
        if (branchId != null) q = q.eq('branch_id', branchId);
        final rows = await q;
        priTable = tbl;
        priRows = (rows as List).length;
        if (priRows > 0) firstPriRow = rows.first as Map;
        for (final sr in rows) {
          final total = ((sr['total'] ?? sr['total_amount'] ?? sr['grand_total'] ?? sr['amount'] ?? sr['net_amount'] ?? sr['return_total'] ?? sr['refund_amount'] ?? sr['value'] ?? sr['subtotal']) as num?)?.toDouble() ?? 0;
          final vno = ((sr['invoice_number'] ?? sr['return_number'] ?? sr['srn_number'] ?? sr['sri_number'] ?? sr['voucher_number'] ?? sr['return_no'] ?? '') as String);
          final date = extractDate(sr as Map, const ['return_date', 'invoice_date', 'voucher_date', 'sri_date', 'srn_date', 'date', 'posted_at', 'created_at']);
          if (total > 0) {
            entries.add({
              'date': date, 'voucher': vno,
              'description': vno.isNotEmpty ? 'Purchase Return ' + vno : 'Purchase Return',
              'debit': 0.0, 'credit': total, 'id': sr['id'] as String?, 'type': 'Purchase Return',
            });
            priAdded++;
          }
        }
        break;
      } catch (_) { continue; }
    }
    if (priTable == null) {
      errors.add('PRI: no matching table. Tried: purchase_return_vouchers');
    } else if (priRows == 0) {
      try {
        final any = await client.from(priTable).select('*').limit(1);
        if ((any as List).isNotEmpty) {
          final keys = (any.first as Map).keys.toList();
          errors.add('PRI: "' + priTable + '" has rows but 0 match org/supplier/branch. Cols: ' + keys.join(', '));
        } else {
          errors.add('PRI: "' + priTable + '" is empty');
        }
      } catch (e) { errors.add('SRI probe: ' + e.toString()); }
    } else if (priAdded == 0) {
      final fsr = firstPriRow;
      if (fsr != null) {
        final keys = fsr.keys.toList();
        errors.add('PRI: "' + priTable + '" had ' + priRows.toString() + ' rows but 0 had positive total. Columns: ' + keys.join(', '));
        final numFields = <String>[];
        fsr.forEach((k, v) {
          if (v is num) numFields.add(k.toString() + '=' + v.toString());
        });
        if (numFields.isNotEmpty) errors.add('SRI numeric fields in row: ' + numFields.join(', '));
      }
    }  // success — no banner needed

    // 4. CRV -> Credit (supplier paid us)
    try {
      final crvVouchers = await client.from('crv_vouchers')
          .select('*').eq('org_id', orgId).eq('status', 'posted');
      final crvIds = (crvVouchers as List).map((v) => v['id'] as String).toList();
      if (crvIds.isNotEmpty) {
        final crvLines = await client.from('crv_voucher_lines')
            .select('amount, description, voucher_id')
            .eq('account_id', supplierId).eq('account_type', 'supplier').inFilter('voucher_id', crvIds);
        final crvMap = {for (final v in crvVouchers) v['id'] as String: v};
        Map? firstNoDate;
        for (final line in crvLines as List) {
          final v = crvMap[line['voucher_id'] as String]; if (v == null) continue;
          final date = extractDate(v as Map, const ['voucher_date', 'value_date', 'transaction_date', 'date', 'posted_at', 'posted_date', 'created_at', 'created_date', 'updated_at']);
          if (date.isEmpty && firstNoDate == null) firstNoDate = v;
          entries.add({
            'date': date,
            'voucher': (v['voucher_number'] as String?) ?? '',
            'description': 'Receipt — ' + ((line['description'] as String?) ?? (v['voucher_number'] as String? ?? '')),
            'debit': (line['amount'] as num?)?.toDouble() ?? 0, 'credit': 0.0,
            'id': v['id'] as String?, 'type': 'Receipt (CRV)',
          });
        }
        if (firstNoDate != null) {
          final fields = firstNoDate.keys.toList().join(', ');
          errors.add('CRV missing date. Available fields: ' + fields);
          for (final f in const ['voucher_date', 'posted_at', 'created_at']) {
            errors.add('CRV.' + f + ' = ' + (firstNoDate[f]?.toString() ?? 'null'));
          }
        }
      }
    } catch (e) { errors.add('CRV: ' + e.toString()); }

    // 5. CPV -> Credit (we paid supplier)
    try {
      final cpvVouchers = await client.from('cpv_vouchers')
          .select('*').eq('org_id', orgId).eq('status', 'posted');
      final cpvIds = (cpvVouchers as List).map((v) => v['id'] as String).toList();
      if (cpvIds.isNotEmpty) {
        final cpvLines = await client.from('cpv_voucher_lines')
            .select('amount, description, voucher_id')
            .eq('account_id', supplierId).eq('account_type', 'supplier').inFilter('voucher_id', cpvIds);
        final cpvMap = {for (final v in cpvVouchers) v['id'] as String: v};
        for (final line in cpvLines as List) {
          final v = cpvMap[line['voucher_id'] as String]; if (v == null) continue;
          final date = extractDate(v as Map, const ['voucher_date', 'value_date', 'transaction_date', 'date', 'posted_at', 'posted_date', 'created_at', 'created_date', 'updated_at']);
          entries.add({
            'date': date,
            'voucher': (v['voucher_number'] as String?) ?? '',
            'description': 'Payment — ' + ((line['description'] as String?) ?? (v['voucher_number'] as String? ?? '')),
            'debit': 0.0,
            'credit': (line['amount'] as num?)?.toDouble() ?? 0, 'id': v['id'] as String?, 'type': 'Payment (CPV)',
          });
        }
      }
    } catch (e) { errors.add('CPV: ' + e.toString()); }

    entries.sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
    double bal = 0;
    for (final e in entries) { bal += (e['debit'] as double) - (e['credit'] as double); e['balance'] = bal; }
    setState(() { _entries = entries; _loading = false; _errors = errors; });
  }

  List<Map<String, dynamic>> get _displayEntries {
    var list = _entries.where((e) {
      if (_typeFilter != 'All' && e['type'] != _typeFilter) return false;
      final ds = e['date'] as String? ?? '';
      if (ds.length >= 10) {
        final d = DateTime.tryParse(ds);
        if (d != null) {
          if (_dateFrom != null && d.isBefore(_dateFrom!)) return false;
          if (_dateTo != null && d.isAfter(_dateTo!.add(const Duration(days: 1)))) return false;
        }
      }
      final q = _entrySearchCtrl.text.toLowerCase();
      if (q.isNotEmpty) {
        if (!(e['description'] as String).toLowerCase().contains(q) && !(e['voucher'] as String).toLowerCase().contains(q)) return false;
      }
      return true;
    }).toList();
    // Recalculate running balance for filtered view
    double rb = 0;
    return list.map((e) { rb += (e['debit'] as double) - (e['credit'] as double); return {...e, 'display_balance': rb}; }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(selectedBranchProvider);
    final display = _displayEntries;
    double totalDebit = 0, totalCredit = 0;
    for (final e in display) { totalDebit += e['debit'] as double; totalCredit += e['credit'] as double; }
    final netBal = totalDebit - totalCredit;
    final maxDrop = _filteredSuppliers.length.clamp(0, 10);

    return GestureDetector(
      onTap: () { if (_showDropdown) setState(() => _showDropdown = false); },
      child: Container(
        color: AppTheme.background, padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Supplier Ledger', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              Text(branch == null ? 'All Branches' : 'Branch: ${branch['name']}', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
            ]),
            const Spacer(),
            if (_selectedSupplier != null && _entries.isNotEmpty) ...[
              OutlinedButton.icon(
                icon: const Icon(Icons.print_outlined, size: 16),
                label: const Text('Print / PDF', style: TextStyle(fontSize: 12)),
                onPressed: _printLedger,
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: Icon(Icons.table_chart_outlined, size: 16, color: Colors.green.shade700),
                label: Text('Export Excel', style: TextStyle(fontSize: 12, color: Colors.green.shade700)),
                onPressed: _exportCsv,
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), side: BorderSide(color: Colors.green.shade300)),
              ),
            ],
          ]),
          const SizedBox(height: 16),
          if (_errors.isNotEmpty) Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange.shade300)),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(_errors.join(' | '), style: TextStyle(fontSize: 11, color: Colors.orange.shade900))),
              IconButton(icon: Icon(Icons.close, size: 14, color: Colors.orange.shade700), onPressed: () => setState(() => _errors = []), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),
          ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 340, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Focus(
                onKeyEvent: (_, event) {
                  if (!_showDropdown || event is! KeyDownEvent) return KeyEventResult.ignored;
                  if (event.logicalKey == LogicalKeyboardKey.arrowDown) { setState(() => _highlightIndex = (_highlightIndex + 1).clamp(0, maxDrop - 1)); return KeyEventResult.handled; }
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) { setState(() => _highlightIndex = (_highlightIndex - 1).clamp(0, maxDrop - 1)); return KeyEventResult.handled; }
                  if (event.logicalKey == LogicalKeyboardKey.enter && _highlightIndex >= 0 && _highlightIndex < maxDrop) { _selectSupplier(_filteredSuppliers[_highlightIndex]); return KeyEventResult.handled; }
                  if (event.logicalKey == LogicalKeyboardKey.escape) { setState(() => _showDropdown = false); return KeyEventResult.handled; }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: _searchCtrl, focusNode: _searchFocus,
                  decoration: InputDecoration(
                    labelText: 'Search Supplier', hintText: 'Name or code...',
                    prefixIcon: const Icon(Icons.search, size: 18), isDense: true,
                    suffixIcon: _selectedSupplier != null ? IconButton(icon: const Icon(Icons.close, size: 16),
                        onPressed: () { setState(() { _selectedSupplier = null; _entries = []; _searchCtrl.clear(); _showDropdown = false; }); try { html.window.localStorage.remove('ledger_supplier_id'); } catch (_) {} }) : null,
                  ),
                  onTap: () => setState(() { _showDropdown = true; if (_searchCtrl.text.isEmpty) _filteredSuppliers = _suppliers; }),
                ),
              ),
              if (_showDropdown && _filteredSuppliers.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 260), width: 340,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 4))]),
                  child: ListView.separated(
                    shrinkWrap: true, itemCount: maxDrop, separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final c = _filteredSuppliers[i]; final hi = i == _highlightIndex;
                      return InkWell(
                        onTap: () => _selectSupplier(c),
                        child: Container(
                          color: hi ? AppTheme.primary.withOpacity(0.08) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(children: [
                            Expanded(child: Text(c['name'] as String? ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
                            if (c['code'] != null) Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.08), borderRadius: BorderRadius.circular(4)),
                              child: Text(c['code'] as String, style: TextStyle(fontSize: 10, color: AppTheme.primary, fontWeight: FontWeight.w700)),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
            ])),
            if (_selectedSupplier != null) ...[
              const SizedBox(width: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.date_range, size: 14),
                label: Text(
                  (_dateFrom != null || _dateTo != null)
                    ? '${_dateFrom != null ? DateFormat('d MMM yy').format(_dateFrom!) : '...'}  →  ${_dateTo != null ? DateFormat('d MMM yy').format(_dateTo!) : '...'}'
                    : 'Date Range', style: const TextStyle(fontSize: 12)),
                onPressed: () async {
                  final picked = await showDateRangePicker(
                    context: context, firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                    initialDateRange: (_dateFrom != null && _dateTo != null) ? DateTimeRange(start: _dateFrom!, end: _dateTo!) : null,
                  );
                  if (picked != null) setState(() { _dateFrom = picked.start; _dateTo = picked.end; });
                },
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
              ),
              if (_dateFrom != null || _dateTo != null) ...[
                const SizedBox(width: 6),
                TextButton(onPressed: () => setState(() { _dateFrom = null; _dateTo = null; }), child: const Text('Clear', style: TextStyle(fontSize: 12))),
              ],
            ],
          ]),
          const SizedBox(height: 12),
          if (_selectedSupplier != null && _entries.isNotEmpty) ...[
            Row(children: [
              _Stat(label: 'Total Debit', value: 'Rs. ${totalDebit.toStringAsFixed(2)}', color: AppTheme.primary),
              const SizedBox(width: 10),
              _Stat(label: 'Total Credit', value: 'Rs. ${totalCredit.toStringAsFixed(2)}', color: Colors.green.shade700),
              const SizedBox(width: 10),
              _Stat(label: 'Net Balance', value: 'Rs. ${netBal.toStringAsFixed(2)}', color: netBal > 0 ? AppTheme.danger : Colors.green.shade700),
              const Spacer(),
              SizedBox(width: 200, child: TextField(controller: _entrySearchCtrl, decoration: const InputDecoration(hintText: 'Search entries...', prefixIcon: Icon(Icons.search, size: 16), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)))),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
                child: DropdownButtonHideUnderline(child: DropdownButton<String>(
                  value: _typeFilter, isDense: true,
                  items: _types.map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(fontSize: 12)))).toList(),
                  onChanged: (v) { setState(() => _typeFilter = v ?? 'All'); _persist(); },
                )),
              ),
            ]),
            const SizedBox(height: 12),
          ],
          if (_loading) const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_selectedSupplier == null) Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.person_search_outlined, size: 52, color: AppTheme.textSecondary.withOpacity(0.3)),
            const SizedBox(height: 12),
            const Text('Search and select a supplier to view their ledger', style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
          ])))
          else Expanded(child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
                child: const Row(children: [
                  SizedBox(width: 90, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                  SizedBox(width: 100, child: Text('Voucher', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                  Expanded(child: Text('Description', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                  SizedBox(width: 80, child: Text('Type', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                  SizedBox(width: 110, child: Text('Debit', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                  SizedBox(width: 110, child: Text('Credit', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                  SizedBox(width: 110, child: Text('Balance', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
                ]),
              ),
              const Divider(height: 1),
              Expanded(child: display.isEmpty
                  ? const Center(child: Text('No transactions found.', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      itemCount: display.length, separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.border),
                      itemBuilder: (_, i) {
                        final e = display[i];
                        final ds = e['date'] as String? ?? '';
                        final dt = DateTime.tryParse(ds); final date = dt != null ? DateFormat('d MMM yy').format(dt) : '-';
                        final debit = e['debit'] as double; final credit = e['credit'] as double;
                        final bal = e['display_balance'] as double; final type = e['type'] as String;
                        return Container(
                          color: i.isEven ? null : Colors.grey.shade50,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                          child: Row(children: [
                            SizedBox(width: 90, child: Text(date, style: const TextStyle(fontSize: 12))),
                            SizedBox(width: 100, child: MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(onTap: () => _openVoucher(e), child: Text(e['voucher'] as String? ?? '', style: TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w600, decoration: TextDecoration.underline), overflow: TextOverflow.ellipsis)))),
                            Expanded(child: Text(e['description'] as String, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                            SizedBox(width: 80, child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(color: _typeColor(type).withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                              child: Text(type, style: TextStyle(fontSize: 9, color: _typeColor(type), fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                            )),
                            SizedBox(width: 110, child: Text(debit > 0 ? 'Rs. ${debit.toStringAsFixed(2)}' : '-', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: debit > 0 ? AppTheme.primary : Colors.black26))),
                            SizedBox(width: 110, child: Text(credit > 0 ? 'Rs. ${credit.toStringAsFixed(2)}' : '-', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: credit > 0 ? Colors.green.shade700 : Colors.black26))),
                            SizedBox(width: 110, child: Text('Rs. ${bal.toStringAsFixed(2)}', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: bal > 0 ? AppTheme.danger : Colors.green.shade700))),
                          ]),
                        );
                      })),
              if (display.isNotEmpty) Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)), border: const Border(top: BorderSide(color: AppTheme.border))),
                child: Row(children: [
                  const SizedBox(width: 90), const SizedBox(width: 100),
                  Expanded(child: Text('${display.length} entries', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                  const SizedBox(width: 80),
                  SizedBox(width: 110, child: Text('Rs. ${totalDebit.toStringAsFixed(2)}', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppTheme.primary))),
                  SizedBox(width: 110, child: Text('Rs. ${totalCredit.toStringAsFixed(2)}', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.green.shade700))),
                  SizedBox(width: 110, child: Text('Rs. ${netBal.toStringAsFixed(2)}', textAlign: TextAlign.right, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: netBal > 0 ? AppTheme.danger : Colors.green.shade700))),
                ]),
              ),
            ]),
          )),
        ]),
      ),
    );
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'Purchase Invoice': return Colors.indigo;
      case 'Purchase Return': return Colors.amber.shade800;
      case 'Receipt (CRV)': return Colors.green;
      case 'Payment (CPV)': return Colors.orange;
      default: return AppTheme.textSecondary;
    }
  }

  void _exportCsv() {
    final display = _displayEntries;
    if (display.isEmpty || _selectedSupplier == null) return;
    final branch = ref.read(selectedBranchProvider);
    final buf = StringBuffer();
    String esc(String s) => '"' + s.replaceAll('"', '""') + '"';
    final cust = _selectedSupplier!;
    final custLabel = '${cust['name']}${cust['code'] != null ? ' (${cust['code']})' : ''}';
    buf.writeln('Supplier Ledger');
    buf.writeln('Supplier,' + esc(custLabel));
    buf.writeln('Branch,' + esc((branch?['name'] as String?) ?? 'All Branches'));
    if (_dateFrom != null) buf.writeln('From,' + DateFormat('yyyy-MM-dd').format(_dateFrom!));
    if (_dateTo != null) buf.writeln('To,' + DateFormat('yyyy-MM-dd').format(_dateTo!));
    buf.writeln('Generated,' + DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()));
    buf.writeln('');
    buf.writeln('Date,Voucher,Description,Type,Debit,Credit,Balance');
    double td = 0, tc = 0;
    for (final e in display) {
      final ds = e['date'] as String? ?? '';
      final dt = DateTime.tryParse(ds); final date = dt != null ? DateFormat('yyyy-MM-dd').format(dt) : '';
      td += e['debit'] as double; tc += e['credit'] as double;
      buf.writeln([date, esc(e['voucher'] as String? ?? ''), esc(e['description'] as String), esc(e['type'] as String), (e['debit'] as double).toStringAsFixed(2), (e['credit'] as double).toStringAsFixed(2), (e['display_balance'] as double).toStringAsFixed(2)].join(','));
    }
    buf.writeln(',,,Total,' + td.toStringAsFixed(2) + ',' + tc.toStringAsFixed(2) + ',' + (td - tc).toStringAsFixed(2));
    final csvContent = String.fromCharCode(0xFEFF) + buf.toString();
    final blob = html.Blob([csvContent], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final safeName = (cust['name'] as String).replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final filename = 'ledger_' + safeName + '_' + DateFormat('yyyyMMdd').format(DateTime.now()) + '.csv';
    final anchor = html.AnchorElement(href: url)..download = filename..style.display = 'none';
    html.document.body!.append(anchor);
    anchor.click();
    Future.delayed(const Duration(seconds: 5), () { anchor.remove(); html.Url.revokeObjectUrl(url); });
  }

  Future<void> _openVoucher(Map<String, dynamic> entry) async {
    final id = entry['id'] as String?;
    final type = entry['type'] as String;
    if (id == null || id.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No voucher ID to open')));
      return;
    }
    Map<String, dynamic>? voucher;
    List<dynamic> lines = [];
    String? err;
    try {
      final client = Supabase.instance.client;
      switch (type) {
        case 'Purchase Invoice':
          voucher = await client.from('purchase_invoices').select('*, suppliers(name)').eq('id', id).maybeSingle();
          if (voucher != null) lines = await client.from('purchase_invoice_items').select('*, products(name, sku)').eq('invoice_id', id);
          break;
        case 'Purchase Return':
          voucher = await client.from('purchase_return_invoices').select('*, suppliers(name)').eq('id', id).maybeSingle();
          if (voucher != null) lines = await client.from('purchase_return_invoice_items').select('*, products(name, sku)').eq('invoice_id', id);
          break;
        case 'Receipt (CRV)':
          voucher = await client.from('crv_vouchers').select('*').eq('id', id).maybeSingle();
          if (voucher != null) lines = await client.from('crv_voucher_lines').select('*').eq('voucher_id', id);
          break;
        case 'Payment (CPV)':
          voucher = await client.from('cpv_vouchers').select('*').eq('id', id).maybeSingle();
          if (voucher != null) lines = await client.from('cpv_voucher_lines').select('*').eq('voucher_id', id);
          break;
      }
    } catch (e) { err = e.toString(); }
    if (!mounted) return;
    final v = voucher;
    if (v == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load: ' + (err ?? 'not found'))));
      return;
    }
    await showDialog(context: context, builder: (ctx) => _buildVoucherDialog(ctx, type, v, lines));
  }

  Widget _buildVoucherDialog(BuildContext ctx, String type, Map<String, dynamic> v, List<dynamic> lines) {
    final isPR = type == 'Receipt (CRV)' || type == 'Payment (CPV)';
    final vNum = ((v['voucher_number'] ?? v['invoice_number'] ?? v['transaction_number'] ?? '') as String);
    final dateStr = ((v['voucher_date'] ?? v['invoice_date'] ?? v['transacted_at'] ?? v['created_at'] ?? '') as String);
    final dt = DateTime.tryParse(dateStr);
    final dateFmt = dt != null ? DateFormat('d MMM yyyy').format(dt) : '-';
    final cust = v['suppliers'];
    final supplierName = (cust is Map ? cust['name'] as String? : null) ?? '';
    final supplierCode = (cust is Map ? cust['code'] as String? : null) ?? '';
    double total = 0;
    if (isPR) {
      for (final ln in lines) { total += ((ln['amount']) as num?)?.toDouble() ?? 0; }
    } else {
      total = ((v['grand_total'] ?? v['total'] ?? v['total_amount'] ?? v['net_amount']) as num?)?.toDouble() ?? 0;
    }
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(type, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
              ]),
              const SizedBox(height: 4),
              Text(vNum, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.primary)),
              const SizedBox(height: 8),
              Wrap(spacing: 18, runSpacing: 6, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.calendar_today, size: 13, color: AppTheme.textSecondary),
                  const SizedBox(width: 5),
                  Text(dateFmt, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
                if (supplierName.isNotEmpty) Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.person, size: 13, color: AppTheme.textSecondary),
                  const SizedBox(width: 5),
                  Text(supplierName + (supplierCode.isNotEmpty ? ' (' + supplierCode + ')' : ''), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
                if (v['status'] != null) Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(10)),
                  child: Text((v['status'] as String).toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                ),
              ]),
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Flexible(child: SingleChildScrollView(child: isPR ? _prLines(lines) : _prodLines(lines))),
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                const Text('Total: ', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                Text('Rs. ' + total.toStringAsFixed(2), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.primary)),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _prLines(List<dynamic> lines) {
    if (lines.isEmpty) return const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No lines', style: TextStyle(color: AppTheme.textSecondary))));
    return Column(children: [
      Container(color: const Color(0xFFF5F5F5), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: Row(children: const [
        Expanded(flex: 3, child: Text('Account / Party', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 3, child: Text('Description', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 2, child: Text('Amount', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
      ])),
      ...lines.map((line) {
        final amount = ((line['amount']) as num?)?.toDouble() ?? 0;
        return Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE)))),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(children: [
            Expanded(flex: 3, child: Text((line['account_name'] as String?) ?? '', style: const TextStyle(fontSize: 12))),
            Expanded(flex: 3, child: Text((line['description'] as String?) ?? '', style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: Text('Rs. ' + amount.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          ]),
        );
      }),
    ]);
  }

  Widget _prodLines(List<dynamic> lines) {
    if (lines.isEmpty) return const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No lines', style: TextStyle(color: AppTheme.textSecondary))));
    return Column(children: [
      Container(color: const Color(0xFFF5F5F5), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: Row(children: const [
        Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 1, child: Text('Qty', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 2, child: Text('Price', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 2, child: Text('Total', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
      ])),
      ...lines.map((line) {
        final qty = ((line['quantity']) as num?)?.toDouble() ?? 0;
        final price = ((line['unit_price'] ?? line['price']) as num?)?.toDouble() ?? 0;
        final lineTotal = ((line['line_total'] ?? line['total'] ?? line['amount']) as num?)?.toDouble() ?? (qty * price);
        final prod = line['products'];
        final prodName = (prod is Map ? prod['name'] as String? : null) ?? (line['product_name'] as String?) ?? (line['description'] as String?) ?? '';
        return Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE)))),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(children: [
            Expanded(flex: 4, child: Text(prodName, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 1, child: Text(qty % 1 == 0 ? qty.toInt().toString() : qty.toString(), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: Text('Rs. ' + price.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: Text('Rs. ' + lineTotal.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          ]),
        );
      }),
    ]);
  }

  void _printLedger() {
    try {
      final display = _displayEntries;
      if (display.isEmpty || _selectedSupplier == null) return;
      final branch = ref.read(selectedBranchProvider);
      double td = 0, tc = 0;
      for (final e in display) { td += e['debit'] as double; tc += e['credit'] as double; }
      final netBal = td - tc;
      final cust = _selectedSupplier!;
      final supplierName = (cust['name'] as String?) ?? '';
      final supplierCode = (cust['code'] as String?) ?? '';
      final branchName = (branch?['name'] as String?) ?? 'All Branches';
      final genTime = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
      final codeStr = supplierCode.isNotEmpty ? ' (' + supplierCode + ')' : '';
      final periodStr = (_dateFrom != null || _dateTo != null)
        ? (_dateFrom != null ? DateFormat('d MMM yy').format(_dateFrom!) : 'Beginning') + ' to ' + (_dateTo != null ? DateFormat('d MMM yy').format(_dateTo!) : 'Today')
        : '';
      final balColor = netBal > 0 ? '#c62828' : '#2e7d32';

      final rowsBuf = StringBuffer();
      for (final e in display) {
        final ds = e['date'] as String? ?? '';
        final dt = DateTime.tryParse(ds);
        final date = dt != null ? DateFormat('d MMM yy').format(dt) : '-';
        final debit = e['debit'] as double;
        final credit = e['credit'] as double;
        final bal = e['display_balance'] as double;
        final dStr = debit > 0 ? 'Rs. ' + debit.toStringAsFixed(2) : '-';
        final cStr = credit > 0 ? 'Rs. ' + credit.toStringAsFixed(2) : '-';
        rowsBuf.write('<tr><td>' + date + '</td><td>' + (e['voucher'] as String? ?? '') + '</td><td>' + (e['description'] as String) + '</td><td><span class="badge">' + (e['type'] as String) + '</span></td><td class="num">' + dStr + '</td><td class="num">' + cStr + '</td><td class="num bold">Rs. ' + bal.toStringAsFixed(2) + '</td></tr>');
      }

      final htmlDoc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Supplier Ledger - ' + supplierName + '</title>'
        '<style>'
        '@page { margin: 0.5cm; } '
        'body { font-family: Arial, sans-serif; padding: 16px; font-size: 10px; color: #000; margin: 0; } '
        '.header { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 2px solid #000; padding-bottom: 8px; margin-bottom: 10px; } '
        'h1 { font-size: 18px; margin: 0 0 4px 0; } '
        '.info { font-size: 10px; margin: 2px 0; } '
        '.stats { display: flex; gap: 10px; margin: 8px 0 12px 0; } '
        '.stat { padding: 6px 10px; border: 1px solid #ddd; border-radius: 4px; } '
        '.stat-label { font-size: 8px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; } '
        '.stat-value { font-weight: 800; font-size: 12px; margin-top: 2px; } '
        '.debit { color: #1976d2; } .credit { color: #2e7d32; } '
        '.bal { color: ' + balColor + '; } '
        'table { width: 100%; border-collapse: collapse; } '
        'th, td { padding: 4px 6px; border-bottom: 1px solid #ddd; text-align: left; font-size: 9.5px; } '
        'th { background: #f5f5f5; font-weight: 700; border-bottom: 1.5px solid #000; } '
        '.num { text-align: right; white-space: nowrap; } .bold { font-weight: 800; } '
        '.badge { display: inline-block; padding: 1px 5px; border-radius: 3px; background: #eee; font-size: 8px; font-weight: 700; } '
        'tfoot td { font-weight: 800; background: #f5f5f5; border-top: 2px solid #000; border-bottom: none; padding: 6px; } '
        '</style></head><body>'
        '<div class="header"><div><h1>Supplier Ledger</h1>'
        '<div class="info"><strong>Supplier:</strong> ' + supplierName + codeStr + '</div>'
        '<div class="info"><strong>Branch:</strong> ' + branchName + '</div>'
        + (periodStr.isNotEmpty ? '<div class="info"><strong>Period:</strong> ' + periodStr + '</div>' : '') +
        '</div><div style="text-align: right;"><div class="info">Generated: ' + genTime + '</div></div></div>'
        '<div class="stats">'
        '<div class="stat"><div class="stat-label">Total Debit</div><div class="stat-value debit">Rs. ' + td.toStringAsFixed(2) + '</div></div>'
        '<div class="stat"><div class="stat-label">Total Credit</div><div class="stat-value credit">Rs. ' + tc.toStringAsFixed(2) + '</div></div>'
        '<div class="stat"><div class="stat-label">Net Balance</div><div class="stat-value bal">Rs. ' + netBal.toStringAsFixed(2) + '</div></div>'
        '</div><table>'
        '<thead><tr><th>Date</th><th>Voucher</th><th>Description</th><th>Type</th><th class="num">Debit</th><th class="num">Credit</th><th class="num">Balance</th></tr></thead>'
        '<tbody>' + rowsBuf.toString() + '</tbody>'
        '<tfoot><tr><td colspan="4">' + display.length.toString() + ' entries</td><td class="num debit">Rs. ' + td.toStringAsFixed(2) + '</td><td class="num credit">Rs. ' + tc.toStringAsFixed(2) + '</td><td class="num bal">Rs. ' + netBal.toStringAsFixed(2) + '</td></tr></tfoot>'
        '</table></body></html>';

      // Original method used across vouchers: blob URL in new tab
      final blob = html.Blob([htmlDoc], 'text/html;charset=utf-8');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.window.open(url, '_blank');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Print error: ' + e.toString())));
    }
  }
}

class _Stat extends StatelessWidget {
  final String label, value; final Color color;
  const _Stat({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
    ]),
  );
}
