import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpCustomerLedgerScreen extends ConsumerStatefulWidget {
  const ErpCustomerLedgerScreen({super.key});
  @override
  ConsumerState<ErpCustomerLedgerScreen> createState() => _ErpCustomerLedgerScreenState();
}

class _ErpCustomerLedgerScreenState extends ConsumerState<ErpCustomerLedgerScreen> {
  List<Map<String, dynamic>> _customers = [];
  Map<String, dynamic>? _selectedCustomer;
  List<Map<String, dynamic>> _filteredCustomers = [];
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

  static const _types = ['All', 'Sales Order', 'Sales Invoice', 'POS Sale', 'Receipt (CRV)', 'Payment (CPV)'];

  @override
  void initState() {
    super.initState();
    _loadCustomers();
    _searchCtrl.addListener(_onSearchChanged);
    _entrySearchCtrl.addListener(() => setState(() {}));
    _searchFocus.addListener(() { if (_searchFocus.hasFocus) setState(() { _showDropdown = true; if (_searchCtrl.text.isEmpty) _filteredCustomers = _customers; }); });
  }

  @override
  void dispose() { _searchCtrl.dispose(); _searchFocus.dispose(); _entrySearchCtrl.dispose(); super.dispose(); }

  void _onSearchChanged() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _highlightIndex = -1;
      _showDropdown = true;
      _filteredCustomers = q.isEmpty ? _customers : _customers.where((c) =>
          (c['shop_name'] as String? ?? '').toLowerCase().contains(q) ||
          (c['code'] as String? ?? '').toLowerCase().contains(q)).toList();
    });
  }

  void _selectCustomer(Map<String, dynamic> c) {
    setState(() {
      _selectedCustomer = c; _entries = []; _showDropdown = false; _highlightIndex = -1;
      _searchCtrl.text = '${c['shop_name']}${c['code'] != null ? ' (${c['code']})' : ''}';
    });
    _loadLedger(c['id'] as String);
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _loadCustomers() async {
    final orgId = _orgId; if (orgId == null) { setState(() => _loadingCustomers = false); return; }
    try {
      final rows = await Supabase.instance.client.from('customers').select('id, shop_name, code')
          .eq('org_id', orgId).order('shop_name').limit(50000);
      setState(() { _customers = List<Map<String, dynamic>>.from(rows); _filteredCustomers = _customers; _loadingCustomers = false; });
    } catch (_) { setState(() => _loadingCustomers = false); }
  }

  Future<void> _loadLedger(String customerId) async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null) return;
    setState(() { _loading = true; _entries = []; _errors = []; });
    final client = Supabase.instance.client;
    final List<Map<String, dynamic>> entries = [];
    final List<String> errors = [];

    // 1. Sales Orders -> Debit
    try {
      var soQ = client.from('sales_orders')
          .select('id, updated_at, created_at, status')
          .eq('org_id', orgId).eq('customer_id', customerId)
          .inFilter('status', ['delivered', 'invoiced', 'completed']);
      if (branchId != null) soQ = soQ.eq('branch_id', branchId);
      final sos = await soQ;
      for (final so in sos as List) {
        final items = await client.from('sales_order_items')
            .select('quantity, unit_price, discount, discount_type').eq('sales_order_id', so['id']);
        double total = 0;
        for (final it in items as List) {
          final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
          final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
          final disc = (it['discount'] as num?)?.toDouble() ?? 0;
          final dt = it['discount_type'] as String? ?? 'fixed';
          final da = dt == 'percent' ? qty * price * disc / 100 : disc;
          total += qty * price - da;
        }
        if (total > 0) {
          final soId = so['id'] as String;
          final vno = soId.length >= 12 ? soId.substring(soId.length - 8) : soId;
          entries.add({
            'date': so['updated_at'] ?? so['created_at'] ?? '',
            'description': 'Sales Order #$vno',
            'voucher': vno, 'debit': total, 'credit': 0.0, 'type': 'Sales Order',
          });
        }
      }
    } catch (e) { errors.add('SO: $e'); }

    // 2. Sales Invoices -> Debit (using select(*) to be schema-agnostic)
    try {
      var siQ = client.from('sales_invoices').select('*')
          .eq('org_id', orgId).eq('customer_id', customerId);
      if (branchId != null) siQ = siQ.eq('branch_id', branchId);
      final sis = await siQ;
      for (final si in sis as List) {
        final total = ((si['total'] ?? si['total_amount'] ?? si['grand_total'] ?? si['net_amount']) as num?)?.toDouble() ?? 0;
        final vno = ((si['invoice_number'] ?? si['voucher_number'] ?? si['si_number'] ?? '') as String);
        final date = ((si['voucher_date'] ?? si['invoice_date'] ?? si['si_date'] ?? si['created_at'] ?? '') as String);
        if (total > 0) {
          entries.add({
            'date': date, 'voucher': vno,
            'description': vno.isNotEmpty ? 'Sales Invoice $vno' : 'Sales Invoice',
            'debit': total, 'credit': 0.0, 'type': 'Sales Invoice',
          });
        }
      }
    } catch (e) { errors.add('SI: $e'); }

    // 3. POS Transactions -> Debit (sales) / Credit (returns)
    try {
      List posTxns = [];
      if (branchId != null) {
        final sessions = await client.from('pos_sessions').select('id').eq('branch_id', branchId);
        final sids = (sessions as List).map((s) => s['id'] as String).toList();
        if (sids.isNotEmpty) {
          posTxns = await client.from('pos_transactions').select('*')
              .eq('customer_id', customerId).inFilter('session_id', sids);
        }
      } else {
        posTxns = await client.from('pos_transactions').select('*')
            .eq('org_id', orgId).eq('customer_id', customerId);
      }
      for (final t in posTxns as List) {
        final ttotal = (t['total'] as num?)?.toDouble() ?? 0;
        final ttype = (t['transaction_type'] as String?) ?? 'sale';
        if (ttype == 'expense' || ttotal == 0) continue;
        final vno = ((t['transaction_number'] ?? '') as String);
        entries.add({
          'date': ((t['transacted_at'] ?? t['created_at'] ?? '') as String),
          'voucher': vno,
          'description': vno.isNotEmpty ? 'POS $vno' : 'POS Sale',
          'debit': ttype == 'return' ? 0.0 : ttotal,
          'credit': ttype == 'return' ? ttotal : 0.0,
          'type': 'POS Sale',
        });
      }
    } catch (e) { errors.add('POS: $e'); }

    // 4. CRV -> Credit (customer paid us)
    try {
      final crvVouchers = await client.from('crv_vouchers')
          .select('id, voucher_number, voucher_date').eq('org_id', orgId).eq('status', 'posted');
      final crvIds = (crvVouchers as List).map((v) => v['id'] as String).toList();
      if (crvIds.isNotEmpty) {
        final crvLines = await client.from('crv_voucher_lines')
            .select('amount, description, voucher_id')
            .eq('account_id', customerId).eq('account_type', 'customer').inFilter('voucher_id', crvIds);
        final crvMap = {for (final v in crvVouchers) v['id'] as String: v};
        for (final line in crvLines as List) {
          final v = crvMap[line['voucher_id'] as String]; if (v == null) continue;
          entries.add({
            'date': v['voucher_date'] ?? '', 'voucher': v['voucher_number'] ?? '',
            'description': 'Receipt — ${line['description'] ?? v['voucher_number']}',
            'debit': 0.0, 'credit': (line['amount'] as num?)?.toDouble() ?? 0,
            'type': 'Receipt (CRV)',
          });
        }
      }
    } catch (e) { errors.add('CRV: $e'); }

    // 5. CPV -> Debit (we paid customer)
    try {
      final cpvVouchers = await client.from('cpv_vouchers')
          .select('id, voucher_number, voucher_date').eq('org_id', orgId).eq('status', 'posted');
      final cpvIds = (cpvVouchers as List).map((v) => v['id'] as String).toList();
      if (cpvIds.isNotEmpty) {
        final cpvLines = await client.from('cpv_voucher_lines')
            .select('amount, description, voucher_id')
            .eq('account_id', customerId).eq('account_type', 'customer').inFilter('voucher_id', cpvIds);
        final cpvMap = {for (final v in cpvVouchers) v['id'] as String: v};
        for (final line in cpvLines as List) {
          final v = cpvMap[line['voucher_id'] as String]; if (v == null) continue;
          entries.add({
            'date': v['voucher_date'] ?? '', 'voucher': v['voucher_number'] ?? '',
            'description': 'Payment — ${line['description'] ?? v['voucher_number']}',
            'debit': (line['amount'] as num?)?.toDouble() ?? 0,
            'credit': 0.0, 'type': 'Payment (CPV)',
          });
        }
      }
    } catch (e) { errors.add('CPV: $e'); }

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
    final maxDrop = _filteredCustomers.length.clamp(0, 10);

    return GestureDetector(
      onTap: () { if (_showDropdown) setState(() => _showDropdown = false); },
      child: Container(
        color: AppTheme.background, padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Customer Ledger', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              Text(branch == null ? 'All Branches' : 'Branch: ${branch['name']}', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
            ]),
          ]),
          const SizedBox(height: 16),
          if (_errors.isNotEmpty) Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange.shade300)),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text('Some sources failed: ${_errors.join(' | ')}', style: TextStyle(fontSize: 11, color: Colors.orange.shade900))),
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
                  if (event.logicalKey == LogicalKeyboardKey.enter && _highlightIndex >= 0 && _highlightIndex < maxDrop) { _selectCustomer(_filteredCustomers[_highlightIndex]); return KeyEventResult.handled; }
                  if (event.logicalKey == LogicalKeyboardKey.escape) { setState(() => _showDropdown = false); return KeyEventResult.handled; }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: _searchCtrl, focusNode: _searchFocus,
                  decoration: InputDecoration(
                    labelText: 'Search Customer', hintText: 'Name or code...',
                    prefixIcon: const Icon(Icons.search, size: 18), isDense: true,
                    suffixIcon: _selectedCustomer != null ? IconButton(icon: const Icon(Icons.close, size: 16),
                        onPressed: () => setState(() { _selectedCustomer = null; _entries = []; _searchCtrl.clear(); _showDropdown = false; })) : null,
                  ),
                  onTap: () => setState(() { _showDropdown = true; if (_searchCtrl.text.isEmpty) _filteredCustomers = _customers; }),
                ),
              ),
              if (_showDropdown && _filteredCustomers.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 260), width: 340,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 4))]),
                  child: ListView.separated(
                    shrinkWrap: true, itemCount: maxDrop, separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final c = _filteredCustomers[i]; final hi = i == _highlightIndex;
                      return InkWell(
                        onTap: () => _selectCustomer(c),
                        child: Container(
                          color: hi ? AppTheme.primary.withOpacity(0.08) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(children: [
                            Expanded(child: Text(c['shop_name'] as String? ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
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
            if (_selectedCustomer != null) ...[
              const SizedBox(width: 12),
              OutlinedButton.icon(icon: const Icon(Icons.calendar_today_outlined, size: 14),
                label: Text(_dateFrom != null ? DateFormat('d MMM yy').format(_dateFrom!) : 'From', style: const TextStyle(fontSize: 12)),
                onPressed: () async {
                  final d = await showDatePicker(context: context, initialDate: _dateFrom ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (d != null) setState(() => _dateFrom = d);
                }, style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8))),
              const SizedBox(width: 8),
              OutlinedButton.icon(icon: const Icon(Icons.calendar_today_outlined, size: 14),
                label: Text(_dateTo != null ? DateFormat('d MMM yy').format(_dateTo!) : 'To', style: const TextStyle(fontSize: 12)),
                onPressed: () async {
                  final d = await showDatePicker(context: context, initialDate: _dateTo ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (d != null) setState(() => _dateTo = d);
                }, style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8))),
              if (_dateFrom != null || _dateTo != null) ...[
                const SizedBox(width: 6),
                TextButton(onPressed: () => setState(() { _dateFrom = null; _dateTo = null; }), child: const Text('Clear', style: TextStyle(fontSize: 12))),
              ],
            ],
          ]),
          const SizedBox(height: 12),
          if (_selectedCustomer != null && _entries.isNotEmpty) ...[
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
                  onChanged: (v) => setState(() => _typeFilter = v ?? 'All'),
                )),
              ),
            ]),
            const SizedBox(height: 12),
          ],
          if (_loading) const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_selectedCustomer == null) Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.person_search_outlined, size: 52, color: AppTheme.textSecondary.withOpacity(0.3)),
            const SizedBox(height: 12),
            const Text('Search and select a customer to view their ledger', style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
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
                        final date = ds.length >= 10 ? DateFormat('d MMM yy').format(DateTime.parse(ds)) : '-';
                        final debit = e['debit'] as double; final credit = e['credit'] as double;
                        final bal = e['display_balance'] as double; final type = e['type'] as String;
                        return Container(
                          color: i.isEven ? null : Colors.grey.shade50,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                          child: Row(children: [
                            SizedBox(width: 90, child: Text(date, style: const TextStyle(fontSize: 12))),
                            SizedBox(width: 100, child: Text(e['voucher'] as String? ?? '', style: TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
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
      case 'Sales Order': return AppTheme.primary;
      case 'Sales Invoice': return Colors.indigo;
      case 'POS Sale': return Colors.purple;
      case 'Receipt (CRV)': return Colors.green;
      case 'Payment (CPV)': return Colors.orange;
      default: return AppTheme.textSecondary;
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
