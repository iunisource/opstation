import 'package:flutter/material.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

/// POS Customer History — search POS quick customers and view their
/// full transaction history (acts as a lightweight ledger).
class ErpPosCustomerHistoryScreen extends ConsumerStatefulWidget {
  const ErpPosCustomerHistoryScreen({super.key});
  @override ConsumerState<ErpPosCustomerHistoryScreen> createState() => _ErpPosCustomerHistoryScreenState();
}

class _ErpPosCustomerHistoryScreenState extends ConsumerState<ErpPosCustomerHistoryScreen> {
  List<Map<String, dynamic>> _customers = [];
  Map<String, dynamic>? _selectedCustomer;
  List<Map<String, dynamic>> _transactions = [];
  List<Map<String, dynamic>> _txnItems = [];
  Map<String, List<Map<String, dynamic>>> _itemsByTxn = {};
  bool _loadingCustomers = true;
  bool _loadingTxns = false;
  String _search = '';
  DateTime? _dateFrom;
  DateTime? _dateTo;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  @override void initState() { super.initState(); _loadCustomers(); }

  void _showSnack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadCustomers() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loadingCustomers = true);
    try {
      final rows = await Supabase.instance.client.from('customers')
          .select('id, shop_name, phone, cnic, code, source')
          .eq('org_id', orgId).eq('is_active', true).order('shop_name');
      setState(() { _customers = List<Map<String, dynamic>>.from(rows); _loadingCustomers = false; });
    } catch (e) { _showSnack('Error: $e'); setState(() => _loadingCustomers = false); }
  }

  Future<void> _loadTransactions(Map<String, dynamic> customer) async {
    setState(() { _selectedCustomer = customer; _loadingTxns = true; _transactions = []; _itemsByTxn = {}; });
    try {
      final orgId = _orgId;
      var q = Supabase.instance.client.from('pos_transactions')
          .select('*, balance_change, amount_paid, pos_sessions(session_number, branches(name))')
          .eq('org_id', orgId!).eq('customer_id', customer['id'] as String)
          .order('transacted_at', ascending: false);
      final rows = await q;
      // Refresh customer record
      try { final fresh = await Supabase.instance.client.from('customers').select('id, shop_name, phone, cnic, code, source').eq('id', customer['id'] as String).single(); setState(() => _selectedCustomer = Map<String, dynamic>.from(fresh)); } catch (_) {}
      final txns = List<Map<String, dynamic>>.from(rows);
      // Load items for all transactions
      final txnIds = txns.map((t) => t['id'] as String).toList();
      if (txnIds.isNotEmpty) {
        final items = await Supabase.instance.client.from('pos_transaction_items')
            .select('*, products(name)').inFilter('transaction_id', txnIds);
        final Map<String, List<Map<String, dynamic>>> byTxn = {};
        for (final item in items as List) {
          final tid = item['transaction_id'] as String;
          byTxn.putIfAbsent(tid, () => []).add(Map<String, dynamic>.from(item));
        }
        setState(() { _transactions = txns; _itemsByTxn = byTxn; _loadingTxns = false; });
      } else {
        setState(() { _transactions = txns; _loadingTxns = false; });
      }
    } catch (e) { _showSnack('Error: $e'); setState(() => _loadingTxns = false); }
  }

  List<Map<String, dynamic>> get _filteredCustomers {
    final q = _search.toLowerCase();
    return _customers.where((c) =>
        q.isEmpty ||
        (c['shop_name'] as String? ?? '').toLowerCase().contains(q) ||
        (c['phone'] as String? ?? '').contains(q) ||
        (c['cnic'] as String? ?? '').contains(q)).toList();
  }

  List<Map<String, dynamic>> get _filteredTxns => _transactions.where((t) {
    final ts = t['transacted_at'] != null ? DateTime.parse(t['transacted_at'] as String).toLocal() : null;
    final matchFrom = _dateFrom == null || (ts != null && !ts.isBefore(_dateFrom!));
    final matchTo = _dateTo == null || (ts != null && !ts.isAfter(_dateTo!.add(const Duration(days: 1))));
    return matchFrom && matchTo;
  }).toList();

  double get _totalSpent => _filteredTxns.where((t) => (t['transaction_type'] ?? 'sale') == 'sale').fold(0.0, (s, t) => s + ((t['total'] as num?)?.toDouble() ?? 0));
  double get _totalRefunded => _filteredTxns.where((t) => t['transaction_type'] == 'return').fold(0.0, (s, t) => s + ((t['total'] as num?)?.toDouble() ?? 0).abs());

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) { _loadCustomers(); setState(() { _selectedCustomer = null; _transactions = []; }); });
    final filtered = _filteredCustomers;
    final txns = _filteredTxns;
    return Container(
      color: AppTheme.background,
      child: Row(children: [
        // ── Left: Customer list ─────────────────────────────────────────
        Container(width: 320, decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
          child: Column(children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 24, 20, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('POS Customers', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('${_customers.length} customers', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ])),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: TextField(
              decoration: const InputDecoration(hintText: 'Search by name, phone, CNIC…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
              onChanged: (v) => setState(() => _search = v))),
            const SizedBox(height: 12),
            if (_loadingCustomers) const Expanded(child: Center(child: CircularProgressIndicator()))
            else filtered.isEmpty
              ? const Expanded(child: Center(child: Text('No customers yet.', style: TextStyle(color: AppTheme.textSecondary))))
              : Expanded(child: ListView.separated(
                  itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final cust = filtered[i]; final sel = _selectedCustomer?['id'] == cust['id'];
                    return ListTile(dense: true, selected: sel, selectedTileColor: AppTheme.primary.withOpacity(0.06),
                      leading: CircleAvatar(backgroundColor: AppTheme.primary.withOpacity(0.1), radius: 18,
                        child: Text((cust['shop_name'] as String? ?? '?').substring(0, 1).toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary, fontSize: 13))),
                      title: Text(cust['shop_name'] as String? ?? '-', style: TextStyle(fontWeight: FontWeight.w600, color: sel ? AppTheme.primary : null)),
                      subtitle: Text([cust['phone'] as String? ?? '', if ((cust['cnic'] as String?)?.isNotEmpty == true) cust['cnic'] as String].where((s) => s.isNotEmpty).join(' · '), style: const TextStyle(fontSize: 11)),
                      trailing: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: (cust['source'] == 'pos' ? Colors.purple : AppTheme.primary).withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Text(cust['source'] == 'pos' ? 'POS' : 'ERP', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: cust['source'] == 'pos' ? Colors.purple : AppTheme.primary))),
                      onTap: () => _loadTransactions(cust));
                  })),
          ])),
        // ── Right: Transaction history ──────────────────────────────────
        Expanded(child: _selectedCustomer == null
            ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.person_search, size: 48, color: AppTheme.border),
                SizedBox(height: 12),
                Text('Select a customer to view transaction history', style: TextStyle(color: AppTheme.textSecondary, fontSize: 15)),
              ]))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Customer header
                Container(padding: const EdgeInsets.fromLTRB(24, 20, 24, 16), color: Colors.white, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_selectedCustomer!['shop_name'] as String? ?? '-', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Wrap(spacing: 16, children: [
                        if ((_selectedCustomer!['phone'] as String?)?.isNotEmpty == true)
                          _InfoChip(Icons.phone_outlined, _selectedCustomer!['phone'] as String),
                        if ((_selectedCustomer!['cnic'] as String?)?.isNotEmpty == true)
                          _InfoChip(Icons.badge_outlined, _selectedCustomer!['cnic'] as String),
                        if ((_selectedCustomer!['code'] as String?)?.isNotEmpty == true)
                          _InfoChip(Icons.tag, _selectedCustomer!['code'] as String),
                      ]),
                    ])),
                    // Stats
                    _StatBox(label: 'Transactions', value: '${txns.where((t) => (t['transaction_type'] ?? 'sale') == 'sale').length}', color: AppTheme.primary),
                    const SizedBox(width: 12),
                    _StatBox(label: 'Total Spent', value: 'Rs. ${money(_totalSpent)}', color: AppTheme.success),
                    const SizedBox(width: 12),
                    _StatBox(label: 'Refunded', value: 'Rs. ${money(_totalRefunded)}', color: Colors.orange),
                    const SizedBox(width: 12),
                    _StatBox(label: 'Net Paid', value: 'Rs. ${money(_totalSpent - _totalRefunded)}', color: AppTheme.primary),
                    const SizedBox(width: 12),
                    Builder(builder: (_) { final bal = (_selectedCustomer!['balance'] as num?)?.toDouble() ?? 0; return _StatBox(label: 'Account Balance', value: 'Rs. ${money(bal)}', color: bal >= 0 ? Colors.green.shade700 : Colors.red.shade700); }),
                  ]),
                  const SizedBox(height: 12),
                  // Date filter
                  Row(children: [
                    const Text('Filter: ', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    OutlinedButton.icon(icon: const Icon(Icons.date_range, size: 14), label: Text(_dateFrom != null ? DateFormat('d MMM yyyy').format(_dateFrom!) : 'From', style: const TextStyle(fontSize: 12)), onPressed: () async { final d = await showDatePicker(context: context, initialDate: _dateFrom ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setState(() => _dateFrom = d); }),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(icon: const Icon(Icons.date_range, size: 14), label: Text(_dateTo != null ? DateFormat('d MMM yyyy').format(_dateTo!) : 'To', style: const TextStyle(fontSize: 12)), onPressed: () async { final d = await showDatePicker(context: context, initialDate: _dateTo ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setState(() => _dateTo = d); }),
                    if (_dateFrom != null || _dateTo != null) ...[const SizedBox(width: 4), IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setState(() { _dateFrom = null; _dateTo = null; }))],
                    const Spacer(),
                    Text('${txns.length} transactions shown', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ]),
                ])),
                const Divider(height: 1),
                // Transactions
                if (_loadingTxns) const Expanded(child: Center(child: CircularProgressIndicator()))
                else txns.isEmpty
                  ? const Expanded(child: Center(child: Text('No transactions found.', style: TextStyle(color: AppTheme.textSecondary))))
                  : Expanded(child: ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: txns.length, separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final t = txns[i];
                        final isReturn = t['transaction_type'] == 'return';
                        final total = (t['total'] as num?)?.toDouble() ?? 0;
                        final disc = (t['discount'] as num?)?.toDouble() ?? 0;
                        final ts = t['transacted_at'] != null ? DateFormat('d MMM yyyy  HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : '-';
                        final items = _itemsByTxn[t['id'] as String] ?? [];
                        final branch = t['pos_sessions']?['branches']?['name'] as String? ?? '-';
                        final payment = t['payment_method'] as String? ?? '-';
                        return InkWell(borderRadius: BorderRadius.circular(10), onTap: isReturn ? null : () => _printReceipt(t, items),
                          child: Container(
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: isReturn ? Colors.orange.withOpacity(0.3) : AppTheme.border)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            // Header row
                            Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 8), child: Row(children: [
                              Icon(isReturn ? Icons.reply : Icons.receipt_outlined, size: 16, color: isReturn ? Colors.orange : AppTheme.primary),
                              const SizedBox(width: 8),
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(ts, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                Text('$branch · $payment', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                              ])),
                              if (disc > 0) Padding(padding: const EdgeInsets.only(right: 12), child: Text('Disc: -${money(disc)}', style: const TextStyle(fontSize: 12, color: Colors.orange))),
                      Builder(builder: (_) { final bc = (t['balance_change'] as num?)?.toDouble() ?? 0; if (bc == 0) return const SizedBox.shrink(); return Container(margin: const EdgeInsets.only(right: 8), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: bc > 0 ? Colors.green.shade50 : Colors.red.shade50, borderRadius: BorderRadius.circular(4)), child: Text(bc > 0 ? '+Rs.${bc.toStringAsFixed(0)}' : '-Rs.${(-bc).toStringAsFixed(0)}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: bc > 0 ? Colors.green.shade700 : Colors.red.shade700))); }),
                              Text('${isReturn ? 'REFUND  -' : ''}Rs. ${money(total.abs())}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: isReturn ? Colors.orange : AppTheme.primary)),
                            ])),
                            if (items.isNotEmpty) ...[
                              const Divider(height: 1),
                              Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: Wrap(spacing: 8, runSpacing: 4,
                                children: items.map((item) {
                                  final qty = (item['quantity'] as num?)?.toDouble() ?? 0;
                                  final price = (item['unit_price'] as num?)?.toDouble() ?? 0;
                                  final name = item['products']?['name'] as String? ?? '-';
                                  return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
                                    child: Text('$name × ${qty.abs().toStringAsFixed(0)} @ ${money(price)}', style: const TextStyle(fontSize: 11)));
                                }).toList())),
                            ],
                          ]),
                        ));
                      })),
              ])),
      ]),
    );
  }
  void _printReceipt(Map<String, dynamic> t, List<Map<String, dynamic>> items) {
    final customer = _selectedCustomer?['shop_name'] as String? ?? 'Walk-in';
    final total = (t['total'] as num?)?.toDouble() ?? 0;
    final disc = (t['discount'] as num?)?.toDouble() ?? 0;
    final subtotal = items.fold(0.0, (s, i) => s + ((i['quantity'] as num?)?.toDouble() ?? 0) * ((i['unit_price'] as num?)?.toDouble() ?? 0));
    final payment = (t['payment_method'] as String? ?? 'cash').toUpperCase();
    final ts = t['transacted_at'] != null ? DateFormat('d MMM yyyy  HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : '-';
    final orgName = ref.read(currentUserProvider)?.orgName ?? 'Opstation';
    final rows = items.map((i) {
      final q = (i['quantity'] as num?)?.toDouble() ?? 0;
      final p = (i['unit_price'] as num?)?.toDouble() ?? 0;
      final d = (i['discount'] as num?)?.toDouble() ?? 0;
      final lt = q * p - d;
      final n = i['products']?['name'] as String? ?? '-';
      return '<tr><td>$n</td><td style="text-align:center">${q.toStringAsFixed(0)}</td><td style="text-align:right">${money(p)}</td><td style="text-align:right;color:${d > 0 ? "#e67e22" : "#999"}">${d > 0 ? "-${money(d)}" : "-"}</td><td style="text-align:right;font-weight:bold">${money(lt)}</td></tr>';
    }).join();
    final discRow = disc > 0 ? '<tr><td colspan="4" style="color:#e67e22">Discount</td><td style="text-align:right;color:#e67e22">-${money(disc)}</td></tr>' : '';
    final content = '''<!DOCTYPE html><html><head><title>Receipt</title><style>@page{margin:0}body{font-family:Arial,sans-serif;padding:20px;max-width:320px;margin:0 auto;font-size:12px}h2{text-align:center;margin:4px 0}table{width:100%;border-collapse:collapse;margin:8px 0}th{background:#f5f5f5;padding:5px 6px;font-size:11px;text-align:left}td{padding:5px 6px;border-bottom:1px solid #eee}.tr td{font-weight:bold;font-size:13px;border-top:2px solid #333}hr{border:none;border-top:1px dashed #ccc;margin:8px 0}</style></head><body><h2>$orgName</h2><p style="text-align:center">$ts<br>Customer: $customer</p><hr><table><thead><tr><th>Item</th><th>Qty</th><th style="text-align:right">Price</th><th style="text-align:right">Disc</th><th style="text-align:right">Total</th></tr></thead><tbody>$rows<tr><td colspan="4" style="color:#666">Subtotal</td><td style="text-align:right">${money(subtotal)}</td></tr>$discRow<tr class="tr"><td colspan="4">TOTAL</td><td style="text-align:right">Rs. ${money(total)}</td></tr></tbody></table><p style="text-align:center">Payment: $payment</p><script>window.print()</script></body></html>''';
    final blob = html.Blob([content], 'text/html');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }

}

class _InfoChip extends StatelessWidget {
  final IconData icon; final String label;
  const _InfoChip(this.icon, this.label);
  @override Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 13, color: AppTheme.textSecondary), const SizedBox(width: 4),
    Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))]);
}

class _StatBox extends StatelessWidget {
  final String label, value; final Color color;
  const _StatBox({required this.label, required this.value, required this.color});
  @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(color: color.withOpacity(0.06), borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withOpacity(0.2))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
      const SizedBox(height: 2),
      Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: color)),
    ]));
}
