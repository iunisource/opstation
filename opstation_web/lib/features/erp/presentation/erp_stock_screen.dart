import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/utils/friendly_error.dart';

class ErpStockScreen extends ConsumerStatefulWidget {
  const ErpStockScreen({super.key});
  @override
  ConsumerState<ErpStockScreen> createState() => _ErpStockScreenState();
}

class _ErpStockScreenState extends ConsumerState<ErpStockScreen> {
  List<Map<String, dynamic>> _stock = [];
  List<Map<String, dynamic>> _filtered = [];
  List<Map<String, dynamic>> _branches = [];
  bool _loading = true;
  final _searchCtrl = TextEditingController();
  String? _branchFilter;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_filter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final stock = await client
          .from('inventory_stock')
          .select('*, products(name, sku), branches(name), uoms(abbreviation)')
          .eq('org_id', orgId)
          .order('quantity', ascending: false);
      final branches = await client
          .from('branches')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      setState(() {
        _stock = List<Map<String, dynamic>>.from(stock);
        _filtered = _stock;
        _branches = List<Map<String, dynamic>>.from(branches);
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _filter() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filtered = _stock.where((s) {
        final productName = (s['products']?['name'] as String? ?? '').toLowerCase();
        final sku = (s['products']?['sku'] as String? ?? '').toLowerCase();
        final matchesSearch = q.isEmpty || productName.contains(q) || sku.contains(q);
        final matchesBranch = _branchFilter == null ||
            s['branch_id'] == _branchFilter;
        return matchesSearch && matchesBranch;
      }).toList();
    });
  }

  void _showAdjustDialog(Map<String, dynamic> stock) {
    final qtyCtrl = TextEditingController(
        text: stock['quantity']?.toString() ?? '0');
    final notesCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Adjust Stock — ${stock['products']?['name'] ?? ''}'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              'Branch: ${stock['branches']?['name'] ?? ''}',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: qtyCtrl,
              decoration: InputDecoration(
                labelText: 'New Quantity *',
                suffixText: stock['uoms']?['abbreviation'] as String? ?? '',
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notesCtrl,
              decoration: const InputDecoration(
                  labelText: 'Reason / Notes *',
                  hintText: 'e.g. Physical count correction'),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final newQty = double.tryParse(qtyCtrl.text.trim());
              if (newQty == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Enter a valid quantity')));
                return;
              }
              if (notesCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Reason is required for adjustments')));
                return;
              }
              final orgId = ref.read(currentUserProvider)?.orgId;
              final userId = ref.read(currentUserProvider)?.id;
              try {
                final client = Supabase.instance.client;
                // Atomic + naturally idempotent: the DB function locks the stock
                // row, computes the diff itself, posts the movement and sets the
                // new quantity in ONE transaction. A double-click's second call
                // computes a zero diff and posts nothing.
                await client.rpc('adjust_stock', params: {
                  'p_org_id': orgId,
                  'p_branch_id': stock['branch_id'],
                  'p_product_id': stock['product_id'],
                  'p_uom_id': stock['uom_id'],
                  'p_new_qty': newQty,
                  'p_notes': notesCtrl.text.trim(),
                  'p_user_id': userId,
                });
                if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Stock adjusted'), behavior: SnackBarBehavior.floating));
                }
                _load();
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(friendlyError('That did not save', e))));
                }
              }
            },
            child: const Text('Adjust'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Stock Levels',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text('${_filtered.length} entries',
              style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                decoration: const InputDecoration(
                  hintText: 'Search by product name or SKU...',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                value: _branchFilter,
                decoration: const InputDecoration(labelText: 'Branch', isDense: true),
                hint: const Text('All branches'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All branches')),
                  ..._branches.map((w) => DropdownMenuItem(
                      value: w['id'] as String,
                      child: Text(w['name'] as String))),
                ],
                onChanged: (v) {
                  setState(() => _branchFilter = v);
                  _filter();
                },
              ),
            ),
          ]),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: const BoxDecoration(
                        color: AppTheme.background,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                      ),
                      child: const Row(children: [
                        Expanded(flex: 3, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('SKU', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Branch', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Quantity', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        SizedBox(width: 60),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _filtered.isEmpty
                          ? const Center(
                              child: Text('No stock entries yet.\nReceive a purchase order to populate stock.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: AppTheme.textSecondary)))
                          : ListView.separated(
                              itemCount: _filtered.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final s = _filtered[i];
                                final qty = (s['quantity'] as num?)?.toDouble() ?? 0;
                                final isLow = qty <= 0;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20, vertical: 12),
                                  child: Row(children: [
                                    Expanded(
                                        flex: 3,
                                        child: Text(
                                            s['products']?['name'] as String? ?? '',
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600))),
                                    Expanded(
                                        flex: 2,
                                        child: Text(
                                            s['products']?['sku'] as String? ?? '-',
                                            style: const TextStyle(
                                                color: AppTheme.primary,
                                                fontWeight: FontWeight.w600))),
                                    Expanded(
                                        flex: 2,
                                        child: Text(
                                            s['branches']?['name'] as String? ?? '-',
                                            style: const TextStyle(
                                                color: AppTheme.textSecondary,
                                                fontSize: 13))),
                                    Expanded(
                                      flex: 2,
                                      child: Row(children: [
                                        Text(
                                          '${qty % 1 == 0 ? qty.toInt() : qty} ${s['uoms']?['abbreviation'] ?? ''}',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: isLow ? AppTheme.danger : Colors.black87,
                                          ),
                                        ),
                                        if (isLow) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: AppTheme.danger.withOpacity(0.1),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: const Text('Out',
                                                style: TextStyle(
                                                    color: AppTheme.danger,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600)),
                                          ),
                                        ],
                                      ]),
                                    ),
                                    SizedBox(
                                      width: 60,
                                      child: IconButton(
                                        icon: const Icon(Icons.tune, size: 18),
                                        tooltip: 'Adjust stock',
                                        onPressed: () => _showAdjustDialog(s),
                                      ),
                                    ),
                                  ]),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
