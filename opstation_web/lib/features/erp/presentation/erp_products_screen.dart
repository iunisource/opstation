import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class ErpProductsScreen extends ConsumerStatefulWidget {
  const ErpProductsScreen({super.key});
  @override
  ConsumerState<ErpProductsScreen> createState() => _ErpProductsScreenState();
}

class _ErpProductsScreenState extends ConsumerState<ErpProductsScreen> {
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _filtered = [];
  Map<String, List<Map<String, dynamic>>> _taxonomies = {};
  List<Map<String, dynamic>> _uoms = [];
  bool _loading = true;
  final _searchCtrl = TextEditingController();

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
      final products = await client
          .from('products')
          .select('*, uoms(name, abbreviation)')
          .eq('org_id', orgId)
          .order('name');
      final taxonomies = await client
          .from('product_taxonomies')
          .select()
          .eq('org_id', orgId)
          .order('name');
      final uoms = await client
          .from('uoms')
          .select()
          .eq('org_id', orgId)
          .order('name');
      final Map<String, List<Map<String, dynamic>>> grouped = {};
      for (final t in taxonomies as List) {
        final type = t['taxonomy_type'] as String;
        grouped.putIfAbsent(type, () => []).add(Map<String, dynamic>.from(t));
      }
      setState(() {
        _products = List<Map<String, dynamic>>.from(products);
        _filtered = _products;
        _taxonomies = grouped;
        _uoms = List<Map<String, dynamic>>.from(uoms);
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _filter() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filtered = _products.where((p) {
        if (q.isEmpty) return true;
        return (p['name'] as String? ?? '').toLowerCase().contains(q) ||
            (p['sku'] as String? ?? '').toLowerCase().contains(q) ||
            (p['barcode'] as String? ?? '').toLowerCase().contains(q);
      }).toList();
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _toggleActive(Map<String, dynamic> p) async {
    final newVal = !(p['is_active'] as bool? ?? true);
    try {
      await Supabase.instance.client
          .from('products')
          .update({'is_active': newVal, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', p['id']);
      _showSnack(newVal ? 'Product activated' : 'Product deactivated');
      _load();
    } catch (e) {
      _showSnack('Failed: $e');
    }
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? product) {
    final nameCtrl = TextEditingController(text: product?['name'] ?? '');
    final skuCtrl = TextEditingController(text: product?['sku'] ?? '');
    final barcodeCtrl = TextEditingController(text: product?['barcode'] ?? '');
    final sellPriceCtrl = TextEditingController(
        text: product?['selling_price']?.toString() ?? '0');
    final costPriceCtrl = TextEditingController(
        text: product?['cost_price']?.toString() ?? '0');
    String? uomId = product?['base_uom_id'] as String?;
    String? productType = product?['product_type'] as String?;
    String? mainGroup = product?['product_main_group'] as String?;
    String? group = product?['product_group'] as String?;
    String? subGroup = product?['product_sub_group'] as String?;
    String? productClass = product?['product_class'] as String?;
    String? movementCategory = product?['product_movement_category'] as String?;

    Widget _taxonomyDropdown(String type, String label, String? value, void Function(String?) onChanged) {
      final items = _taxonomies[type] ?? [];
      return DropdownButtonFormField<String>(
        value: value,
        decoration: InputDecoration(labelText: label),
        hint: const Text('Select...'),
        items: items.map((t) => DropdownMenuItem(
            value: t['name'] as String,
            child: Text(t['name'] as String))).toList(),
        onChanged: onChanged,
      );
    }

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(product == null ? 'Add Product' : 'Edit Product'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Basic Info',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppTheme.textSecondary)),
                ),
                const SizedBox(height: 8),
                TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Product Name *')),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: skuCtrl,
                          decoration: const InputDecoration(labelText: 'SKU'))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: TextField(
                          controller: barcodeCtrl,
                          decoration: const InputDecoration(labelText: 'Barcode'))),
                ]),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: uomId,
                  decoration: const InputDecoration(labelText: 'Base UOM *'),
                  hint: const Text('Select UOM'),
                  items: _uoms.map((u) => DropdownMenuItem(
                      value: u['id'] as String,
                      child: Text('${u['name']} (${u['abbreviation']})'))).toList(),
                  onChanged: (v) => setS(() => uomId = v),
                ),
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Classification',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppTheme.textSecondary)),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _taxonomyDropdown('product_type', 'Product Type', productType, (v) => setS(() => productType = v))),
                  const SizedBox(width: 12),
                  Expanded(child: _taxonomyDropdown('main_group', 'Main Group', mainGroup, (v) => setS(() => mainGroup = v))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _taxonomyDropdown('group', 'Group', group, (v) => setS(() => group = v))),
                  const SizedBox(width: 12),
                  Expanded(child: _taxonomyDropdown('sub_group', 'Sub Group', subGroup, (v) => setS(() => subGroup = v))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _taxonomyDropdown('class', 'Class', productClass, (v) => setS(() => productClass = v))),
                  const SizedBox(width: 12),
                  Expanded(child: _taxonomyDropdown('movement_category', 'Movement Category', movementCategory, (v) => setS(() => movementCategory = v))),
                ]),
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Pricing',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppTheme.textSecondary)),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: sellPriceCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Selling Price *'),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: TextField(
                          controller: costPriceCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Cost Price *'),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true))),
                ]),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () =>
                    Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                      content: Text('Product name is required')));
                  return;
                }
                if (uomId == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Base UOM is required')));
                  return;
                }
                final orgId = ref.read(currentUserProvider)?.orgId;
                final data = {
                  'org_id': orgId,
                  'name': nameCtrl.text.trim(),
                  'sku': skuCtrl.text.trim().isEmpty ? null : skuCtrl.text.trim(),
                  'barcode': barcodeCtrl.text.trim().isEmpty ? null : barcodeCtrl.text.trim(),
                  'base_uom_id': uomId,
                  'product_type': productType,
                  'product_main_group': mainGroup,
                  'product_group': group,
                  'product_sub_group': subGroup,
                  'product_class': productClass,
                  'product_movement_category': movementCategory,
                  'selling_price': double.tryParse(sellPriceCtrl.text.trim()) ?? 0,
                  'cost_price': double.tryParse(costPriceCtrl.text.trim()) ?? 0,
                  'updated_at': DateTime.now().toUtc().toIso8601String(),
                };
                try {
                  if (product == null) {
                    final id = 'prod_${DateTime.now().millisecondsSinceEpoch}';
                    await Supabase.instance.client
                        .from('products')
                        .insert({...data, 'id': id});
                  } else {
                    await Supabase.instance.client
                        .from('products')
                        .update(data)
                        .eq('id', product['id']);
                  }
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack(product == null ? 'Product added' : 'Product updated');
                  _load();
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('Failed: $e')));
                  }
                }
              },
              child: Text(product == null ? 'Add' : 'Save'),
            ),
          ],
        ),
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
          Row(children: [
            const Text('Products',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () => _showDialog(context, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Product'),
            ),
          ]),
          const SizedBox(height: 8),
          Text('${_filtered.length} products',
              style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search by name, SKU or barcode...',
              prefixIcon: Icon(Icons.search),
            ),
          ),
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      decoration: const BoxDecoration(
                        color: AppTheme.background,
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(12)),
                      ),
                      child: const Row(children: [
                        Expanded(flex: 3, child: Text('Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('SKU', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Type', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Group', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Sell Price', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        SizedBox(width: 80),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final p = _filtered[i];
                          final isActive = p['is_active'] as bool? ?? true;
                          final catName = p['product_categories'] != null
                              ? p['product_categories']['name'] as String? ?? '-'
                              : '-';
                          final uomAbbr = p['uoms'] != null
                              ? p['uoms']['abbreviation'] as String? ?? '-'
                              : '-';
                          return Opacity(
                            opacity: isActive ? 1.0 : 0.5,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              child: Row(children: [
                                Expanded(
                                    flex: 3,
                                    child: Text(p['name'] as String? ?? '',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600))),
                                Expanded(
                                    flex: 2,
                                    child: Text(p['sku'] as String? ?? '-',
                                        style: const TextStyle(
                                            color: AppTheme.primary,
                                            fontWeight: FontWeight.w600))),
                                Expanded(
                                    flex: 2,
                                    child: Text(p['product_type'] as String? ?? '-',
                                        style: const TextStyle(
                                            color: AppTheme.textSecondary,
                                            fontSize: 13))),
                                Expanded(
                                    flex: 2,
                                    child: Text(p['product_group'] as String? ?? '-',
                                        style: const TextStyle(
                                            color: AppTheme.textSecondary,
                                            fontSize: 13))),
                                Expanded(
                                    flex: 1,
                                    child: Text(uomAbbr,
                                        style: const TextStyle(fontSize: 13))),
                                Expanded(
                                    flex: 2,
                                    child: Text(
                                        p['selling_price']?.toString() ?? '0',
                                        style: const TextStyle(fontSize: 13))),
                                SizedBox(
                                  width: 80,
                                  child: Row(children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit_outlined,
                                          size: 18),
                                      onPressed: () =>
                                          _showDialog(context, p),
                                    ),
                                    IconButton(
                                      icon: Icon(
                                        isActive
                                            ? Icons.block
                                            : Icons.check_circle_outline,
                                        size: 18,
                                        color: isActive
                                            ? AppTheme.danger
                                            : AppTheme.success,
                                      ),
                                      onPressed: () => _toggleActive(p),
                                      tooltip: isActive
                                          ? 'Deactivate'
                                          : 'Activate',
                                    ),
                                  ]),
                                ),
                              ]),
                            ),
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
