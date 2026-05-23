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
  List<Map<String, dynamic>> _filteredMovements = [];
  bool _loading = false;
  bool _loadingProducts = true;

  // Product picker filters
  String? _mainGroupFilter;
  String? _groupFilter;
  final _productSearchCtrl = TextEditingController();
  // Movements search
  final _movementsSearchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProducts();
    _productSearchCtrl.addListener(() => setState(() {}));
    _movementsSearchCtrl.addListener(_filterMovements);
  }

  @override
  void dispose() {
    _productSearchCtrl.dispose();
    _movementsSearchCtrl.dispose();
    super.dispose();
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _loadProducts() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) { setState(() => _loadingProducts = false); return; }
    try {
      final products = await Supabase.instance.client
          .from('products').select('id, name, sku, product_main_group, product_group, uoms(abbreviation)')
          .eq('org_id', orgId).eq('is_active', true).order('name').limit(10000);
      setState(() {
        _products = List<Map<String, dynamic>>.from(products);
        _loadingProducts = false;
      });
    } catch (_) { setState(() => _loadingProducts = false); }
  }

  List<Map<String, dynamic>> get _visibleProducts {
    final q = _productSearchCtrl.text.toLowerCase().trim();
    return _products.where((p) {
      if (_mainGroupFilter != null && (p['product_main_group'] as String? ?? '') != _mainGroupFilter) return false;
      if (_groupFilter != null && (p['product_group'] as String? ?? '') != _groupFilter) return false;
      if (q.isEmpty) return true;
      return (p['name'] as String? ?? '').toLowerCase().contains(q) ||
             (p['sku'] as String? ?? '').toLowerCase().contains(q);
    }).toList();
  }

  List<String> get _mainGroupOptions {
    return _products
        .map((p) => p['product_main_group'] as String? ?? '')
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  List<String> get _groupOptions {
    return _products
        .where((p) => _mainGroupFilter == null || (p['product_main_group'] as String? ?? '') == _mainGroupFilter)
        .map((p) => p['product_group'] as String? ?? '')
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
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

      setState(() {
        _movements = entries;
        _filteredMovements = entries;
        _movementsSearchCtrl.clear();
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  void _filterMovements() {
    final q = _movementsSearchCtrl.text.toLowerCase().trim();
    setState(() {
      if (q.isEmpty) {
        _filteredMovements = _movements;
      } else {
        _filteredMovements = _movements.where((m) {
          final type = (m['movement_type'] as String? ?? '').toLowerCase();
          final notes = (m['notes'] as String? ?? m['reference_type'] as String? ?? '').toLowerCase();
          final date = m['moved_at'] != null
              ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(m['moved_at'] as String).toLocal()).toLowerCase() : '';
          return type.contains(q) || notes.contains(q) || date.contains(q);
        }).toList();
      }
    });
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'purchase': return AppTheme.success;
      case 'sale': return AppTheme.danger;
      case 'pos': return Colors.orange;
      case 'transfer': return Colors.blue;
      case 'adjustment': return Colors.purple;
      default: return AppTheme.textSecondary;
    }
  }

  void _clearSelection() {
    setState(() {
      _selectedProduct = null;
      _movements = [];
      _filteredMovements = [];
      _movementsSearchCtrl.clear();
    });
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
        else if (_selectedProduct == null)
          _buildPicker()
        else
          _buildLedger(currentStock),
      ]),
    );
  }

  Widget _buildPicker() {
    final visible = _visibleProducts;
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Filter row
        Row(children: [
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<String?>(
              value: _mainGroupFilter,
              isDense: true,
              decoration: const InputDecoration(labelText: 'Main Group', isDense: true),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('All', style: TextStyle(color: AppTheme.textSecondary))),
                ..._mainGroupOptions.map((g) => DropdownMenuItem<String?>(value: g, child: Text(g))),
              ],
              onChanged: (v) => setState(() {
                _mainGroupFilter = v;
                // Reset group if it's no longer valid
                if (_groupFilter != null && !_groupOptions.contains(_groupFilter)) _groupFilter = null;
              }),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<String?>(
              value: _groupFilter,
              isDense: true,
              decoration: const InputDecoration(labelText: 'Group', isDense: true),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('All', style: TextStyle(color: AppTheme.textSecondary))),
                ..._groupOptions.map((g) => DropdownMenuItem<String?>(value: g, child: Text(g))),
              ],
              onChanged: (v) => setState(() => _groupFilter = v),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 320,
            child: TextField(
              controller: _productSearchCtrl,
              decoration: const InputDecoration(
                labelText: 'Search Product',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Text('${visible.length} of ${_products.length} products',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 8),
        // Always-visible product list (no need to type)
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: visible.isEmpty
                ? const Center(child: Text('No products match the filters.', style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final p = visible[i];
                      final sub = [
                        p['sku'] as String?,
                        p['product_main_group'] as String?,
                        p['product_group'] as String?,
                      ].where((s) => s != null && s.isNotEmpty).join('  ·  ');
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.inventory_2_outlined, size: 18, color: AppTheme.primary),
                        title: Text(p['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        subtitle: sub.isNotEmpty ? Text(sub, style: const TextStyle(fontSize: 11)) : null,
                        trailing: const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
                        onTap: () {
                          setState(() => _selectedProduct = p);
                          _loadMovements(p['id'] as String);
                        },
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _buildLedger(double currentStock) {
    final p = _selectedProduct!;
    final uomAbbr = p['uoms']?['abbreviation'] as String? ?? '';
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Product header with back / clear
        Row(children: [
          IconButton(
            onPressed: _clearSelection,
            icon: const Icon(Icons.arrow_back, size: 20),
            tooltip: 'Back to products',
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p['name'] as String? ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              Text([
                p['sku'] as String?,
                p['product_main_group'] as String?,
                p['product_group'] as String?,
              ].where((s) => s != null && s.isNotEmpty).join('  ·  '),
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ]),
          ),
          if (_movements.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Current Stock', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                Text(
                  '${currentStock % 1 == 0 ? currentStock.toInt() : currentStock} $uomAbbr',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15,
                      color: currentStock > 0 ? AppTheme.success : AppTheme.danger),
                ),
              ]),
            ),
            const SizedBox(width: 12),
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
        const SizedBox(height: 16),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_movements.isEmpty)
          const Expanded(child: Center(child: Text('No movements for this product.', style: TextStyle(color: AppTheme.textSecondary))))
        else ...[
          // Movements search bar
          SizedBox(
            width: 420,
            child: TextField(
              controller: _movementsSearchCtrl,
              decoration: InputDecoration(
                labelText: 'Search entries (type, notes, date)',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                suffixIcon: _movementsSearchCtrl.text.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => _movementsSearchCtrl.clear())
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (_movementsSearchCtrl.text.isNotEmpty)
            Text('${_filteredMovements.length} of ${_movements.length} entries match',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
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
                  child: _filteredMovements.isEmpty
                      ? const Center(child: Text('No entries match.', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: _filteredMovements.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final m = _filteredMovements[i];
                            final qty = (m['quantity'] as num?)?.toDouble() ?? 0;
                            final runQty = m['running_qty'] as double;
                            final entryUom = m['uoms']?['abbreviation'] as String? ?? '';
                            final date = m['moved_at'] != null
                                ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(m['moved_at'] as String).toLocal()) : '-';
                            final type = m['movement_type'] as String? ?? '';
                            final notes = m['notes'] as String? ?? m['reference_type'] as String? ?? '-';
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              child: Row(children: [
                                Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 12))),
                                Expanded(flex: 2, child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: _typeColor(type).withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(type, style: TextStyle(fontSize: 11, color: _typeColor(type), fontWeight: FontWeight.w600)),
                                  ),
                                )),
                                Expanded(flex: 3, child: Text(notes, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                                Expanded(flex: 2, child: Text(qty > 0 ? '+${qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2)} $entryUom' : '-',
                                    style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.success))),
                                Expanded(flex: 2, child: Text(qty < 0 ? '${qty.abs().toStringAsFixed(qty.abs() % 1 == 0 ? 0 : 2)} $entryUom' : '-',
                                    style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.danger))),
                                Expanded(flex: 2, child: Text('${runQty.toStringAsFixed(runQty % 1 == 0 ? 0 : 2)} $entryUom',
                                    style: TextStyle(fontWeight: FontWeight.w700,
                                        color: runQty > 0 ? AppTheme.success : AppTheme.danger))),
                              ]),
                            );
                          }),
                ),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}
