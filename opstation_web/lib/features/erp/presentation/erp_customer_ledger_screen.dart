import 'package:flutter/material.dart';
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
  List<Map<String, dynamic>> _entries = [];
  bool _loading = false;
  bool _loadingCustomers = true;
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _filteredCustomers = [];

  @override
  void initState() {
    super.initState();
    _loadCustomers();
    _searchCtrl.addListener(_filterCustomers);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _filterCustomers() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filteredCustomers = _customers.where((c) =>
          q.isEmpty ||
          (c['shop_name'] as String? ?? '').toLowerCase().contains(q) ||
          (c['code'] as String? ?? '').toLowerCase().contains(q)).toList();
    });
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _loadCustomers() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) { setState(() => _loadingCustomers = false); return; }
    try {
      final customers = await Supabase.instance.client
          .from('customers').select('id, shop_name, code')
          .eq('org_id', orgId).eq('is_active', true).order('shop_name');
      setState(() {
        _customers = List<Map<String, dynamic>>.from(customers);
        _filteredCustomers = _customers;
        _loadingCustomers = false;
      });
    } catch (_) { setState(() => _loadingCustomers = false); }
  }

  Future<void> _loadLedger(String customerId) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = _branchId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final List<Map<String, dynamic>> entries = [];

      // Sales orders (debits — customer owes us)
      final soQuery = client.from('sales_orders')
          .select('id, created_at, status, updated_at')
          .eq('org_id', orgId).eq('customer_id', customerId)
          .inFilter('status', ['delivered']);
      final sos = branchId != null
          ? await soQuery.eq('branch_id', branchId)
          : await soQuery;

      for (final so in sos as List) {
        final items = await client.from('sales_order_items')
            .select('quantity, unit_price, discount').eq('sales_order_id', so['id']);
        double total = 0;
        for (final item in items as List) {
          final qty = (item['quantity'] as num?)?.toDouble() ?? 0;
          final price = (item['unit_price'] as num?)?.toDouble() ?? 0;
          final disc = (item['discount'] as num?)?.toDouble() ?? 0;
          total += (qty * price) - disc;
        }
        if (total > 0) {
          entries.add({
            'date': so['updated_at'] ?? so['created_at'],
            'description': 'Sales Order #${(so['id'] as String).substring(3, 16)}',
            'debit': total, 'credit': 0.0, 'type': 'sale',
          });
        }
      }

      // POS transactions
      List posTxns = [];
      if (branchId != null) {
        final sessions = await client.from('pos_sessions').select('id').eq('branch_id', branchId);
        final sessionIds = (sessions as List).map((s) => s['id'] as String).toList();
        if (sessionIds.isNotEmpty) {
          posTxns = await client.from('pos_transactions')
              .select('id, transacted_at, total, payment_method')
              .eq('customer_id', customerId)
              .inFilter('session_id', sessionIds);
        }
      } else {
        posTxns = await client.from('pos_transactions')
            .select('id, transacted_at, total, payment_method')
            .eq('org_id', orgId).eq('customer_id', customerId);
      }

      for (final txn in posTxns as List) {
        entries.add({
          'date': txn['transacted_at'],
          'description': 'POS Sale — ${txn['payment_method']}',
          'debit': 0.0, 'credit': (txn['total'] as num?)?.toDouble() ?? 0, 'type': 'pos',
        });
      }

      // Receipt vouchers (credits — customer paid)
      final rvQuery = client.from('receipt_vouchers')
          .select().eq('org_id', orgId).eq('customer_id', customerId);
      final rvs = branchId != null
          ? await rvQuery.eq('branch_id', branchId)
          : await rvQuery;

      for (final rv in rvs as List) {
        entries.add({
          'date': rv['voucher_date'] ?? rv['created_at'],
          'description': 'Receipt — ${rv['payment_method']}${rv['reference'] != null ? ' (${rv['reference']})' : ''}',
          'debit': 0.0, 'credit': (rv['amount'] as num?)?.toDouble() ?? 0, 'type': 'receipt',
        });
      }

      entries.sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
      double balance = 0;
      for (final e in entries) {
        balance += (e['debit'] as double) - (e['credit'] as double);
        e['balance'] = balance;
      }

      setState(() { _entries = entries; _loading = false; });
    } catch (_) { setState(() => _loading = false); }
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(selectedBranchProvider);
    double totalDebit = 0, totalCredit = 0;
    for (final e in _entries) {
      totalDebit += e['debit'] as double;
      totalCredit += e['credit'] as double;
    }
    final balance = totalDebit - totalCredit;

    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Customer Ledger', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(branch == null ? 'Select a branch' : 'Branch: ${branch['name']}',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 20),
        if (_loadingCustomers)
          const Center(child: CircularProgressIndicator())
        else
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Search Customer',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                ),
              ),
              if (_entries.isNotEmpty) ...[
                const SizedBox(width: 24),
                _LedgerStat(label: 'Total Sales', value: totalDebit.toStringAsFixed(2), color: AppTheme.primary),
                const SizedBox(width: 16),
                _LedgerStat(label: 'Total Received', value: totalCredit.toStringAsFixed(2), color: AppTheme.success),
                const SizedBox(width: 16),
                _LedgerStat(label: 'Balance Receivable', value: balance.toStringAsFixed(2),
                    color: balance > 0 ? AppTheme.danger : AppTheme.success),
              ],
            ]),
            if (_filteredCustomers.isNotEmpty && _searchCtrl.text.isNotEmpty && _selectedCustomer == null)
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                width: 320,
                decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.border),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)],
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _filteredCustomers.take(6).length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final c = _filteredCustomers[i];
                    return ListTile(
                      dense: true,
                      title: Text('${c['shop_name']} (${c['code']})', style: const TextStyle(fontSize: 13)),
                      onTap: () {
                        setState(() {
                          _selectedCustomer = c;
                          _entries = [];
                          _searchCtrl.text = '${c['shop_name']} (${c['code']})';
                        });
                        _loadLedger(c['id'] as String);
                      },
                    );
                  },
                ),
              ),
          ]),
        const SizedBox(height: 20),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_selectedCustomer == null)
          const Center(child: Text('Search and select a customer to view ledger.', style: TextStyle(color: AppTheme.textSecondary)))
        else
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                  child: const Row(children: [
                    Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 4, child: Text('Description', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Debit', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Credit', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Balance', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  ]),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _entries.isEmpty
                      ? const Center(child: Text('No transactions found.', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: _entries.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final e = _entries[i];
                            final dateStr = e['date'] as String? ?? '';
                            final date = dateStr.length >= 10
                                ? DateFormat('d MMM yyyy').format(DateTime.parse(dateStr)) : '-';
                            final debit = e['debit'] as double;
                            final credit = e['credit'] as double;
                            final bal = e['balance'] as double;
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              child: Row(children: [
                                Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 13))),
                                Expanded(flex: 4, child: Text(e['description'] as String, style: const TextStyle(fontSize: 13))),
                                Expanded(flex: 2, child: Text(debit > 0 ? debit.toStringAsFixed(2) : '-',
                                    style: TextStyle(fontWeight: FontWeight.w600, color: debit > 0 ? AppTheme.primary : Colors.black54))),
                                Expanded(flex: 2, child: Text(credit > 0 ? credit.toStringAsFixed(2) : '-',
                                    style: TextStyle(fontWeight: FontWeight.w600, color: credit > 0 ? AppTheme.success : Colors.black54))),
                                Expanded(flex: 2, child: Text(bal.toStringAsFixed(2),
                                    style: TextStyle(fontWeight: FontWeight.w700, color: bal > 0 ? AppTheme.danger : AppTheme.success))),
                              ]),
                            );
                          }),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _LedgerStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _LedgerStat({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        Text(value, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: color)),
      ]),
    );
  }
}
