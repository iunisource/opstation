import 'package:flutter/material.dart';
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
  List<Map<String, dynamic>> _entries = [];
  bool _loading = false;
  bool _loadingSuppliers = true;

  @override
  void initState() {
    super.initState();
    _loadSuppliers();
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _loadSuppliers() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) { setState(() => _loadingSuppliers = false); return; }
    try {
      final suppliers = await Supabase.instance.client
          .from('suppliers').select().eq('org_id', orgId).eq('is_active', true).order('name');
      setState(() {
        _suppliers = List<Map<String, dynamic>>.from(suppliers);
        _loadingSuppliers = false;
      });
    } catch (_) { setState(() => _loadingSuppliers = false); }
  }

  Future<void> _loadLedger(String supplierId) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = _branchId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final List<Map<String, dynamic>> entries = [];

      // Purchase orders (debits — we owe supplier)
      final poQuery = client.from('purchase_orders')
          .select('id, created_at, status, received_at')
          .eq('org_id', orgId).eq('supplier_id', supplierId)
          .inFilter('status', ['ordered', 'received']);
      final pos = branchId != null
          ? await poQuery.eq('branch_id', branchId)
          : await poQuery;

      for (final po in pos as List) {
        final items = await client.from('purchase_order_items')
            .select('quantity_received, unit_cost').eq('purchase_order_id', po['id']);
        double total = 0;
        for (final item in items as List) {
          total += ((item['quantity_received'] as num?)?.toDouble() ?? 0) *
              ((item['unit_cost'] as num?)?.toDouble() ?? 0);
        }
        if (total > 0) {
          entries.add({
            'date': po['received_at'] ?? po['created_at'],
            'description': 'Purchase Order #${(po['id'] as String).substring(3, 16)}',
            'debit': total, 'credit': 0.0, 'type': 'purchase',
          });
        }
      }

      // Payment vouchers (credits — we paid supplier)
      final pvQuery = client.from('payment_vouchers')
          .select().eq('org_id', orgId).eq('supplier_id', supplierId);
      final pvs = branchId != null
          ? await pvQuery.eq('branch_id', branchId)
          : await pvQuery;

      for (final pv in pvs as List) {
        entries.add({
          'date': pv['voucher_date'] ?? pv['created_at'],
          'description': 'Payment — ${pv['payment_method']}${pv['reference'] != null ? ' (${pv['reference']})' : ''}',
          'debit': 0.0, 'credit': (pv['amount'] as num?)?.toDouble() ?? 0, 'type': 'payment',
        });
      }

      // Sort by date
      entries.sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));

      // Calculate running balance
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
        const Text('Supplier Ledger', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(branch == null ? 'Select a branch' : 'Branch: ${branch['name']}',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 20),
        if (_loadingSuppliers)
          const Center(child: CircularProgressIndicator())
        else
          Row(children: [
            SizedBox(
              width: 320,
              child: DropdownButtonFormField<String>(
                value: _selectedSupplier?['id'] as String?,
                decoration: const InputDecoration(labelText: 'Select Supplier', isDense: true),
                hint: const Text('Choose a supplier'),
                items: _suppliers.map((s) => DropdownMenuItem(
                    value: s['id'] as String, child: Text(s['name'] as String))).toList(),
                onChanged: (v) {
                  final supplier = _suppliers.firstWhere((s) => s['id'] == v);
                  setState(() { _selectedSupplier = supplier; _entries = []; });
                  _loadLedger(v!);
                },
              ),
            ),
            if (_entries.isNotEmpty) ...[
              const SizedBox(width: 24),
              _LedgerStat(label: 'Total Purchases', value: totalDebit.toStringAsFixed(2), color: AppTheme.danger),
              const SizedBox(width: 16),
              _LedgerStat(label: 'Total Payments', value: totalCredit.toStringAsFixed(2), color: AppTheme.success),
              const SizedBox(width: 16),
              _LedgerStat(label: 'Balance Payable', value: balance.toStringAsFixed(2),
                  color: balance > 0 ? AppTheme.danger : AppTheme.success),
            ],
          ]),
        const SizedBox(height: 20),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_selectedSupplier == null)
          const Center(child: Text('Select a supplier to view ledger.', style: TextStyle(color: AppTheme.textSecondary)))
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
                            final date = (e['date'] as String).length >= 10
                                ? DateFormat('d MMM yyyy').format(DateTime.parse(e['date'] as String)) : '-';
                            final debit = e['debit'] as double;
                            final credit = e['credit'] as double;
                            final bal = e['balance'] as double;
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              child: Row(children: [
                                Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 13))),
                                Expanded(flex: 4, child: Text(e['description'] as String, style: const TextStyle(fontSize: 13))),
                                Expanded(flex: 2, child: Text(debit > 0 ? debit.toStringAsFixed(2) : '-',
                                    style: TextStyle(fontWeight: FontWeight.w600, color: debit > 0 ? AppTheme.danger : Colors.black54))),
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
