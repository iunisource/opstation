import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpInventoryLedgerScreen extends ConsumerStatefulWidget {
  const ErpInventoryLedgerScreen({super.key});
  @override
  ConsumerState<ErpInventoryLedgerScreen> createState() => _ErpInventoryLedgerScreenState();
}

class _ErpInventoryLedgerScreenState extends ConsumerState<ErpInventoryLedgerScreen> {
  List<Map<String, dynamic>> _products = [];
  Map<String, dynamic>? _selectedProduct;
  List<Map<String, dynamic>> _movements = [];
  bool _loading = false;
  bool _loadingProducts = true;
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _filteredProducts = [];

  @override
  void initState() {
    super.initState();
    _loadProducts();
    _searchCtrl.addListener(_filterProducts);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _filterProducts() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filteredProducts = _products.where((p) =>
          q.isEmpty ||
          (p['name'] as String? ?? '').toLowerCase().contains(q) ||
          (p['sku'] as String? ?? '').toLowerCase().contains(q)).toList();
    });
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _loadProducts() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) { setState(() => _loadingProducts = false); return; }
    try {
      final products = await Supabase.instance.client
          .from('products').select('id, name, sku, uoms(abbreviation)')
          .eq('org_id', orgId).eq('is_active', true).order('name');
      setState(() {
        _products = List<Map<String, dynamic>>.from(products);
        _filteredProducts = _products;
        _loadingProducts = false;
      });
    } catch (_) { setState(() => _loadingProducts = false); }
  }

  Future<void> _loadMovements(String productId) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = _branchId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final baseQuery = Supabase.instance.client
          .from('inventory_movements')
          .select('*, uoms(abbreviation)')
          .eq('org_id', orgId)
          .eq('product_id', productId);
      final movements = branchId != null
          ? await baseQuery.eq('branch_id', branchId).order('moved_at')
          : await baseQuery.order('moved_at');

      double runningQty = 0;
      final entries = (movements as List).map((m) {
        final qty = (m['quantity'] as num?)?.toDouble() ?? 0;
        runningQty += qty;
        return {
          ...Map<String, dynamic>.from(m),
          'running_qty': runningQty,
        };
      }).toList();

      setState(() { _movements = entries; _loading = false; });
    } catch (_) { setState(() => _loading = false); }
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'purchase': return AppTheme.success;
      case 'sale': return AppTheme.danger;
      case 'pos': return Colors.orange;
      case 'transfer': return Colors.blue;
      default: return AppTheme.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(selectedBranchProvider);
    final currentStock = _movements.isNotEmpty
        ? (_movements.last['running_qty'] as double) : 0.0;

    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Inventory Ledger', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(branch == null ? 'Select a branch' : 'Branch: ${branch['name']}',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 20),
        if (_loadingProducts)
          const Center(child: CircularProgressIndicator())
        else
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Search Product',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                ),
              ),
              if (_selectedProduct != null && _movements.isNotEmpty) ...[
                const SizedBox(width: 24),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Current Stock', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    Text(
                      '${currentStock % 1 == 0 ? currentStock.toInt() : currentStock} ${_selectedProduct!['uoms']?['abbreviation'] ?? ''}',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15,
                          color: currentStock > 0 ? AppTheme.success : AppTheme.danger),
                    ),
                  ]),
                ),
                const SizedBox(width: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Total Movements', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    Text('${_movements.length}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  ]),
                ),
              ],
            ]),
            if (_filteredProducts.isNotEmpty && _searchCtrl.text.isNotEmpty && _selectedProduct == null)
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
                  itemCount: _filteredProducts.take(6).length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final p = _filteredProducts[i];
                    return ListTile(
                      dense: true,
                      title: Text(p['name'] as String, style: const TextStyle(fontSize: 13)),
                      subtitle: p['sku'] != null ? Text(p['sku'] as String, style: const TextStyle(fontSize: 11)) : null,
                      onTap: () {
                        setState(() {
                          _selectedProduct = p;
                          _movements = [];
                          _searchCtrl.text = p['name'] as String;
                        });
                        _loadMovements(p['id'] as String);
                      },
                    );
                  },
                ),
              ),
          ]),
        const SizedBox(height: 20),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_selectedProduct == null)
          const Center(child: Text('Search and select a product to view ledger.', style: TextStyle(color: AppTheme.textSecondary)))
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
                    Expanded(flex: 2, child: Text('Type', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 3, child: Text('Notes / Reference', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('In', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Out', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Balance', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  ]),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _movements.isEmpty
                      ? const Center(child: Text('No movements found.', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: _movements.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final m = _movements[i];
                            final qty = (m['quantity'] as num?)?.toDouble() ?? 0;
                            final runQty = m['running_qty'] as double;
                            final uomAbbr = m['uoms']?['abbreviation'] as String? ?? '';
                            final date = m['moved_at'] != null
                                ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(m['moved_at'] as String).toLocal()) : '-';
                            final type = m['movement_type'] as String? ?? '';
                            final notes = m['notes'] as String? ?? m['reference_type'] as String? ?? '-';
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              child: Row(children: [
                                Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 12))),
                                Expanded(flex: 2, child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: _typeColor(type).withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(type, style: TextStyle(fontSize: 11, color: _typeColor(type), fontWeight: FontWeight.w600)),
                                )),
                                Expanded(flex: 3, child: Text(notes, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                                Expanded(flex: 2, child: Text(qty > 0 ? '+${qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2)} $uomAbbr' : '-',
                                    style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.success))),
                                Expanded(flex: 2, child: Text(qty < 0 ? '${qty.abs().toStringAsFixed(qty.abs() % 1 == 0 ? 0 : 2)} $uomAbbr' : '-',
                                    style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.danger))),
                                Expanded(flex: 2, child: Text('${runQty.toStringAsFixed(runQty % 1 == 0 ? 0 : 2)} $uomAbbr',
                                    style: TextStyle(fontWeight: FontWeight.w700,
                                        color: runQty > 0 ? AppTheme.success : AppTheme.danger))),
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
