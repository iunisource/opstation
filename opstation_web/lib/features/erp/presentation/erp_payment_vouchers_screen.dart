import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';
import '../../../core/utils/friendly_error.dart';

class ErpPaymentVouchersScreen extends ConsumerStatefulWidget {
  const ErpPaymentVouchersScreen({super.key});
  @override
  ConsumerState<ErpPaymentVouchersScreen> createState() => _ErpPaymentVouchersScreenState();
}

class _ErpPaymentVouchersScreenState extends ConsumerState<ErpPaymentVouchersScreen> {
  List<Map<String, dynamic>> _vouchers = [];
  List<Map<String, dynamic>> _suppliers = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = _branchId;
    if (orgId == null || branchId == null) { setState(() => _loading = false); return; }
    try {
      final client = Supabase.instance.client;
      final vouchers = await client
          .from('payment_vouchers')
          .select('*, suppliers(name)')
          .eq('org_id', orgId).eq('branch_id', branchId)
          .order('voucher_date', ascending: false);
      final suppliers = await client.from('suppliers').select().eq('org_id', orgId).eq('is_active', true).order('name').limit(10000);
      setState(() {
        _vouchers = List<Map<String, dynamic>>.from(vouchers);
        _suppliers = List<Map<String, dynamic>>.from(suppliers);
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? voucher) {
    String? supplierId = voucher?['supplier_id'] as String?;
    String paymentMethod = voucher?['payment_method'] as String? ?? 'cash';
    final amountCtrl = TextEditingController(text: voucher?['amount']?.toString() ?? '0');
    final refCtrl = TextEditingController(text: voucher?['reference'] ?? '');
    final notesCtrl = TextEditingController(text: voucher?['notes'] ?? '');
    DateTime voucherDate = voucher?['voucher_date'] != null
        ? DateTime.parse(voucher!['voucher_date'] as String) : DateTime.now();

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(voucher == null ? 'New Payment Voucher' : 'Edit Payment Voucher'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: supplierId,
                decoration: const InputDecoration(labelText: 'Supplier *'),
                hint: const Text('Select supplier'),
                items: _suppliers.map((s) => DropdownMenuItem(value: s['id'] as String, child: Text(s['name'] as String))).toList(),
                onChanged: (v) => setS(() => supplierId = v),
              ),
              const SizedBox(height: 12),
              TextField(controller: amountCtrl,
                  decoration: const InputDecoration(labelText: 'Amount *'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true)),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: paymentMethod,
                decoration: const InputDecoration(labelText: 'Payment Method'),
                items: const [
                  DropdownMenuItem(value: 'cash', child: Text('Cash')),
                  DropdownMenuItem(value: 'bank_transfer', child: Text('Bank Transfer')),
                  DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
                ],
                onChanged: (v) => setS(() => paymentMethod = v ?? 'cash'),
              ),
              const SizedBox(height: 12),
              TextField(controller: refCtrl, decoration: const InputDecoration(labelText: 'Reference (cheque no., bank ref.)')),
              const SizedBox(height: 12),
              TextField(controller: notesCtrl, decoration: const InputDecoration(labelText: 'Notes'), maxLines: 2),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx, initialDate: voucherDate,
                    firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) setS(() => voucherDate = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Voucher Date'),
                  child: Text(DateFormat('d MMM yyyy').format(voucherDate)),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (supplierId == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Supplier required')));
                  return;
                }
                final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
                if (amount <= 0) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Amount must be greater than 0')));
                  return;
                }
                final orgId = ref.read(currentUserProvider)?.orgId;
                final userId = ref.read(currentUserProvider)?.id;
                final branchId = _branchId;
                final data = {
                  'org_id': orgId, 'branch_id': branchId,
                  'supplier_id': supplierId, 'amount': amount,
                  'payment_method': paymentMethod,
                  'reference': refCtrl.text.trim().isEmpty ? null : refCtrl.text.trim(),
                  'notes': notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
                  'voucher_date': DateFormat('yyyy-MM-dd').format(voucherDate),
                };
                try {
                  if (voucher == null) {
                    await Supabase.instance.client.from('payment_vouchers').insert({
                      ...data, 'id': 'pv_${DateTime.now().millisecondsSinceEpoch}', 'created_by': userId,
                    });
                  } else {
                    await Supabase.instance.client.from('payment_vouchers').update(data).eq('id', voucher['id']);
                  }
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack(voucher == null ? 'Payment voucher created' : 'Updated');
                  _load();
                } catch (e) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(friendlyError('That did not save', e))));
                }
              },
              child: Text(voucher == null ? 'Create' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(selectedBranchProvider);
    double totalPaid = 0;
    for (final v in _vouchers) totalPaid += (v['amount'] as num?)?.toDouble() ?? 0;

    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Payment Vouchers', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: branch == null ? null : () => _showDialog(context, null),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Payment'),
          ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Text(branch == null ? 'Select a branch' : 'Branch: ${branch['name']}',
              style: const TextStyle(color: AppTheme.textSecondary)),
          if (_vouchers.isNotEmpty) ...[
            const SizedBox(width: 16),
            Text('Total Paid: ${money(totalPaid)}',
                style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.danger)),
          ],
        ]),
        const SizedBox(height: 24),
        if (_loading) const Center(child: CircularProgressIndicator())
        else if (branch == null) const Center(child: Text('No branch selected.', style: TextStyle(color: AppTheme.textSecondary)))
        else Expanded(
          child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                child: const Row(children: [
                  Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(flex: 3, child: Text('Supplier', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text('Method', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text('Reference', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text('Amount', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  SizedBox(width: 48),
                ]),
              ),
              const Divider(height: 1),
              Expanded(
                child: _vouchers.isEmpty
                    ? const Center(child: Text('No payment vouchers yet.', style: TextStyle(color: AppTheme.textSecondary)))
                    : ListView.separated(
                        itemCount: _vouchers.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final v = _vouchers[i];
                          final amount = (v['amount'] as num?)?.toDouble() ?? 0;
                          final date = v['voucher_date'] != null
                              ? DateFormat('d MMM yyyy').format(DateTime.parse(v['voucher_date'] as String)) : '-';
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(children: [
                              Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 13))),
                              Expanded(flex: 3, child: Text(v['suppliers']?['name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600))),
                              Expanded(flex: 2, child: Text(v['payment_method'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                              Expanded(flex: 2, child: Text(v['reference'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                              Expanded(flex: 2, child: Text(money(amount), style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.danger))),
                              SizedBox(width: 48, child: IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  onPressed: () => _showDialog(context, v))),
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
