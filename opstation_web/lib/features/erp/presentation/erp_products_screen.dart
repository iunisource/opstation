// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;
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
  List<Map<String, dynamic>> _branches = [];
  final _searchCtrl = TextEditingController();
  final Set<String> _selected = {};

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
      final branches = await client.from('branches').select('id, name').eq('org_id', orgId!).eq('is_active', true).order('name');
      final Map<String, List<Map<String, dynamic>>> grouped = {};
      for (final t in taxonomies as List) {
        final type = t['taxonomy_type'] as String;
        grouped.putIfAbsent(type, () => []).add(Map<String, dynamic>.from(t));
      }
      setState(() {
        _branches = List<Map<String, dynamic>>.from(branches);
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

  Future<void> _pushToPOS(BuildContext context, Map<String, dynamic> product) async {
    if (_branches.isEmpty) { _showSnack('No branches found'); return; }
    final picked = await showDialog<Map<String, dynamic>?>(context: context, builder: (_) => _BranchPickerDialog(branches: _branches, productName: product['name'] as String? ?? '-'));
    if (picked == null) return;
    final orgId = ref.read(currentUserProvider)?.orgId; if (orgId == null) return;
    try {
      final catalogId = 'posc_${DateTime.now().millisecondsSinceEpoch}';
      await Supabase.instance.client.from('pos_catalog').upsert({
        'id': catalogId,
        'org_id': orgId,
        'branch_id': picked['id'],
        'product_id': product['id'],
        'name': product['name'],
        'sku': product['sku'],
        'price': (product['selling_price'] as num?)?.toDouble() ?? 0,
        'uom_id': product['base_uom_id'],
        'is_active': true,
      }, onConflict: 'org_id,branch_id,product_id');
      _showSnack('"${product['name']}" pushed to POS catalog for ${picked['name']}');
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _bulkPushToPOS(BuildContext context) async {
    if (_branches.isEmpty) { _showSnack('No branches found'); return; }
    final picked = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (_) => _BranchPickerDialog(branches: _branches, productName: '${_selected.length} products'),
    );
    if (picked == null) return;
    final orgId = ref.read(currentUserProvider)?.orgId; if (orgId == null) return;
    final selected = _filtered.where((p) => _selected.contains(p['id'])).toList();
    int success = 0; int failed = 0;
    for (var i = 0; i < selected.length; i++) {
      final product = selected[i];
      try {
        await Supabase.instance.client.from('pos_catalog').upsert({
          'id': 'posc_${DateTime.now().millisecondsSinceEpoch}_$i',
          'org_id': orgId,
          'branch_id': picked['id'],
          'product_id': product['id'],
          'name': product['name'],
          'sku': product['sku'],
          'price': (product['selling_price'] as num?)?.toDouble() ?? 0,
          'uom_id': product['base_uom_id'],
          'is_active': true,
        }, onConflict: 'org_id,branch_id,product_id');
        success++;
      } catch (_) { failed++; }
    }
    if (mounted) setState(() => _selected.clear());
    _showSnack('Pushed $success product${success == 1 ? "" : "s"} to ${picked['name']} POS${failed > 0 ? " — $failed failed" : ""}');
  }

  void _showCsvImport(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _CsvImportDialog(
        uoms: _uoms,
        branches: _branches,
        existingSkus: _products.map((p) => (p['sku'] as String?) ?? '').where((s) => s.isNotEmpty).toSet(),
        onImport: _doCsvImport,
      ),
    );
  }

  Future<void> _doCsvImport(List<Map<String, dynamic>> rows, List<String> branchIds) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    int success = 0; int failed = 0; int allocFailed = 0;
    for (var i = 0; i < rows.length; i++) {
      try {
        final id = 'prod_${DateTime.now().millisecondsSinceEpoch}_$i';
        await Supabase.instance.client.from('products').insert({
          ...rows[i],
          'id': id,
          'org_id': orgId,
          'is_active': true,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
        success++;
        // Allocate imported product to the chosen branches at zero stock.
        for (var b = 0; b < branchIds.length; b++) {
          try {
            await Supabase.instance.client.from('inventory_stock').insert({
              'id': 'invs_${DateTime.now().millisecondsSinceEpoch}_${i}_$b',
              'org_id': orgId, 'product_id': id, 'branch_id': branchIds[b], 'quantity': 0,
            });
          } catch (_) { allocFailed++; }
        }
      } catch (_) { failed++; }
    }
    _showSnack('Imported $success product${success == 1 ? "" : "s"}'
        '${branchIds.isNotEmpty ? " into ${branchIds.length} branch${branchIds.length == 1 ? "" : "es"}" : ""}'
        '${failed > 0 ? " — $failed failed" : ""}'
        '${allocFailed > 0 ? " — $allocFailed stock rows failed" : ""}');
    _load();
  }

  Future<void> _showDialog(BuildContext context, Map<String, dynamic>? product) async {
    final orgIdPre = ref.read(currentUserProvider)?.orgId;
    // Load existing branch allocation (inventory_stock) for this product (edit only).
    final Map<String, double> existingStock = {}; // branch_id -> qty
    if (product != null && orgIdPre != null) {
      try {
        final rows = await Supabase.instance.client.from('inventory_stock')
            .select('branch_id, quantity').eq('org_id', orgIdPre).eq('product_id', product['id'] as String);
        for (final r in rows as List) {
          existingStock[r['branch_id'] as String] = (r['quantity'] as num?)?.toDouble() ?? 0.0;
        }
      } catch (_) {}
    }
    final Set<String> selectedBranches = {...existingStock.keys};
    if (!context.mounted) return;
    final nameCtrl = TextEditingController(text: product?['name'] ?? '');
    final skuCtrl = TextEditingController(text: product?['sku'] ?? '');
    final barcodeCtrl = TextEditingController(text: product?['barcode'] ?? '');
    final sellPriceCtrl = TextEditingController(
        text: product?['selling_price']?.toString() ?? '0');
    final costPriceCtrl = TextEditingController(
        text: product?['cost_price']?.toString() ?? '0');
    final lowStockCtrl = TextEditingController(
        text: product?['low_stock_limit']?.toString() ?? '0');
    String? uomId = product?['base_uom_id'] as String?;
    String? productType = product?['product_type'] as String?;
    String? mainGroup = product?['product_main_group'] as String?;
    String? group = product?['product_group'] as String?;
    String? subGroup = product?['product_sub_group'] as String?;
    String? productClass = product?['product_class'] as String?;
    String? movementCategory = product?['product_movement_category'] as String?;

    Widget _taxonomyDropdown(String type, String label, String? value, void Function(String?) onChanged) {
      final items = _taxonomies[type] ?? [];
      final names = items.map((t) => t['name'] as String).toList();
      final cur = (value != null && value.isNotEmpty) ? value : null;
      if (cur != null && !names.contains(cur)) names.insert(0, cur);
      return DropdownButtonFormField<String>(
        value: cur,
        decoration: InputDecoration(labelText: label),
        hint: const Text('Select...'),
        items: names.map((n) => DropdownMenuItem(value: n, child: Text(n))).toList(),
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
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: lowStockCtrl, decoration: const InputDecoration(labelText: 'Low Stock Limit', helperText: 'Flag in Low Stock Report when on-hand is at or below this'), keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                  const SizedBox(width: 12),
                  const Expanded(child: SizedBox()),
                ]),
                const SizedBox(height: 16),
                const Align(alignment: Alignment.centerLeft, child: Text('Branch Allocation', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
                const SizedBox(height: 4),
                const Align(alignment: Alignment.centerLeft, child: Text('Tick the branches this product is stocked in. Newly ticked branches start at zero stock; existing stock is never changed here. Branches that already hold stock are locked.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
                const SizedBox(height: 8),
                if (_branches.isEmpty)
                  const Align(alignment: Alignment.centerLeft, child: Text('No branches found.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
                else
                  Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 8, runSpacing: 4, children: _branches.map((b) {
                    final bid = b['id'] as String;
                    final allocated = existingStock.containsKey(bid);
                    final qty = existingStock[bid] ?? 0.0;
                    final locked = allocated && qty > 0; // protect real stock from being un-allocated
                    final checked = selectedBranches.contains(bid);
                    return FilterChip(
                      label: Text('${b['name'] ?? '-'}' + (allocated ? '  •  ${qty.toStringAsFixed(0)}' : '')),
                      selected: checked,
                      onSelected: locked ? null : (v) => setS(() { if (v) selectedBranches.add(bid); else selectedBranches.remove(bid); }),
                    );
                  }).toList())),
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
                  'low_stock_limit': double.tryParse(lowStockCtrl.text.trim()) ?? 0,
                  'updated_at': DateTime.now().toUtc().toIso8601String(),
                };
                try {
                  String pid;
                  if (product == null) {
                    pid = 'prod_${DateTime.now().millisecondsSinceEpoch}';
                    await Supabase.instance.client
                        .from('products')
                        .insert({...data, 'id': pid});
                  } else {
                    pid = product['id'] as String;
                    await Supabase.instance.client
                        .from('products')
                        .update(data)
                        .eq('id', pid);
                  }
                  // Reconcile branch allocation (inventory_stock). Add zero-stock rows for
                  // newly ticked branches; remove rows only where stock is zero. Never touch
                  // a branch's existing quantity.
                  try {
                    int allocCounter = 0;
                    for (final bid in selectedBranches) {
                      if (existingStock.containsKey(bid)) continue;
                      await Supabase.instance.client.from('inventory_stock').insert({
                        'id': 'invs_${DateTime.now().millisecondsSinceEpoch}_${allocCounter++}',
                        'org_id': orgId, 'product_id': pid, 'branch_id': bid, 'quantity': 0,
                      });
                    }
                    for (final bid in existingStock.keys) {
                      if (!selectedBranches.contains(bid) && (existingStock[bid] ?? 0) == 0) {
                        await Supabase.instance.client.from('inventory_stock')
                            .delete().eq('org_id', orgId ?? '').eq('product_id', pid).eq('branch_id', bid);
                      }
                    }
                  } catch (e) {
                    _showSnack('Product saved, but branch allocation failed: $e');
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
            OutlinedButton.icon(
              onPressed: () => _showCsvImport(context),
              icon: const Icon(Icons.upload_file, size: 18),
              label: const Text('Import CSV'),
            ),
            const SizedBox(width: 8),
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
          if (_selected.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
              ),
              child: Row(children: [
                Icon(Icons.check_circle, size: 16, color: AppTheme.primary),
                const SizedBox(width: 8),
                Text('${_selected.length} selected', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() => _selected.clear()),
                  icon: const Icon(Icons.close, size: 14),
                  label: const Text('Clear'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _bulkPushToPOS(context),
                  icon: const Icon(Icons.point_of_sale, size: 16),
                  label: const Text('Push selected to POS'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.purple, foregroundColor: Colors.white),
                ),
              ]),
            ),
          ],
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
                      child: Row(children: [
                        SizedBox(width: 40, child: Checkbox(
                          tristate: true,
                          value: _selected.isEmpty ? false : (_selected.length == _filtered.length ? true : null),
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _selected.addAll(_filtered.map((p) => p['id'] as String));
                              } else {
                                _selected.clear();
                              }
                            });
                          },
                        )),
                        const Expanded(flex: 3, child: Text('Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('SKU', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Type', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Group', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Sell Price', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        SizedBox(width: 120),
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
                                SizedBox(width: 40, child: Checkbox(
                                  value: _selected.contains(p['id']),
                                  onChanged: (v) {
                                    setState(() {
                                      if (v == true) {
                                        _selected.add(p['id'] as String);
                                      } else {
                                        _selected.remove(p['id']);
                                      }
                                    });
                                  },
                                )),
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
                                  width: 120,
                                  child: Row(children: [
                                    IconButton(
                                      icon: const Icon(Icons.point_of_sale,
                                          size: 18, color: Colors.purple),
                                      tooltip: 'Push to POS Catalog',
                                      onPressed: () => _pushToPOS(context, p),
                                    ),
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

class _BranchPickerDialog extends StatelessWidget {
  final List<Map<String, dynamic>> branches;
  final String productName;
  const _BranchPickerDialog({required this.branches, required this.productName});
  @override Widget build(BuildContext context) => AlertDialog(
    title: Text('Push "$productName" to POS'),
    content: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Select which branch POS catalog to add this product to:', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      const SizedBox(height: 12),
      ...branches.map((b) => ListTile(dense: true, leading: const Icon(Icons.storefront_outlined, size: 18, color: Colors.purple), title: Text(b['name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)), onTap: () => Navigator.pop(context, b))),
    ])),
    actions: [TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel'))],
  );
}


class _CsvImportDialog extends StatefulWidget {
  final List<Map<String, dynamic>> uoms;
  final List<Map<String, dynamic>> branches;
  final Set<String> existingSkus;
  final Future<void> Function(List<Map<String, dynamic>>, List<String>) onImport;
  const _CsvImportDialog({required this.uoms, required this.branches, required this.existingSkus, required this.onImport});
  @override
  State<_CsvImportDialog> createState() => _CsvImportDialogState();
}

class _CsvImportDialogState extends State<_CsvImportDialog> {
  List<Map<String, dynamic>> _validRows = [];
  List<String> _rowErrors = [];
  final Set<String> _importBranches = {};
  int _totalParsed = 0;
  bool _importing = false;
  String? _fileName;
  String? _fatalError;

  void _downloadTemplate() {
    const csv = 'name,sku,barcode,uom,product_type,main_group,group,sub_group,class,movement_category,selling_price,cost_price,low_stock_limit\n'
        'Example Product A,SKU001,8901234567890,pcs,Stock Item,Lighting,Downlights,LED,A,Fast,210,150,10\n'
        'Example Product B,SKU002,,box,Stock Item,Electricals,,,,Slow,1000,800,0\n';
    final blob = html.Blob([csv], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)..setAttribute('download', 'products_template.csv')..click();
    Future.delayed(const Duration(seconds: 2), () => html.Url.revokeObjectUrl(url));
  }

  Future<void> _pickFile() async {
    final input = html.FileUploadInputElement()..accept = '.csv,text/csv';
    input.click();
    await input.onChange.first;
    if (input.files == null || input.files!.isEmpty) return;
    final file = input.files!.first;
    final reader = html.FileReader();
    reader.readAsText(file);
    await reader.onLoad.first;
    final text = reader.result as String;
    setState(() {
      _fileName = file.name; _fatalError = null; _validRows = []; _rowErrors = [];
    });
    _parseAndValidate(text);
  }

  List<List<String>> _parseCsv(String text) {
    final lines = <List<String>>[];
    final fields = <String>[];
    final current = StringBuffer();
    bool inQuotes = false;
    int i = 0;
    while (i < text.length) {
      final ch = text[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') { current.write('"'); i += 2; continue; }
          inQuotes = false; i++; continue;
        }
        current.write(ch); i++;
      } else {
        if (ch == '"') { inQuotes = true; i++; continue; }
        if (ch == ',') { fields.add(current.toString()); current.clear(); i++; continue; }
        if (ch == '\n' || ch == '\r') {
          fields.add(current.toString()); current.clear();
          if (fields.any((f) => f.isNotEmpty)) lines.add(List.from(fields));
          fields.clear();
          if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
          i++; continue;
        }
        current.write(ch); i++;
      }
    }
    if (current.isNotEmpty || fields.isNotEmpty) {
      fields.add(current.toString());
      if (fields.any((f) => f.isNotEmpty)) lines.add(List.from(fields));
    }
    return lines;
  }

  void _parseAndValidate(String text) {
    final rows = _parseCsv(text);
    if (rows.isEmpty) { setState(() => _fatalError = 'CSV is empty'); return; }
    final header = rows.first.map((s) => s.trim().toLowerCase()).toList();
    if (!header.contains('name')) { setState(() => _fatalError = 'Required column "name" missing'); return; }
    if (!header.contains('uom')) { setState(() => _fatalError = 'Required column "uom" missing'); return; }
    int idx(String col) => header.indexOf(col);
    final iName = idx('name'); final iSku = idx('sku'); final iBarcode = idx('barcode');
    final iUom = idx('uom'); final iType = idx('product_type'); final iMain = idx('main_group');
    final iGroup = idx('group'); final iSub = idx('sub_group'); final iClass = idx('class');
    final iMov = idx('movement_category'); final iSell = idx('selling_price'); final iCost = idx('cost_price');
    final iLow = idx('low_stock_limit');

    final uomByAbbr = {for (final u in widget.uoms) (u['abbreviation'] as String? ?? '').toLowerCase(): u['id'] as String};
    final uomByName = {for (final u in widget.uoms) (u['name'] as String? ?? '').toLowerCase(): u['id'] as String};
    final seenSkus = <String>{};
    final valid = <Map<String, dynamic>>[];
    final errors = <String>[];

    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      String get(int i) => (i >= 0 && i < row.length) ? row[i].trim() : '';
      final name = get(iName);
      if (name.isEmpty) { errors.add('Row ${r + 1}: name is required'); continue; }
      final uomRaw = get(iUom).toLowerCase();
      if (uomRaw.isEmpty) { errors.add('Row ${r + 1}: uom is required'); continue; }
      final uomId = uomByAbbr[uomRaw] ?? uomByName[uomRaw];
      if (uomId == null) { errors.add('Row ${r + 1}: unknown uom "$uomRaw"'); continue; }
      final sku = iSku >= 0 ? get(iSku) : '';
      if (sku.isNotEmpty && widget.existingSkus.contains(sku)) { errors.add('Row ${r + 1}: SKU "$sku" already exists, skipped'); continue; }
      if (sku.isNotEmpty && seenSkus.contains(sku)) { errors.add('Row ${r + 1}: duplicate SKU "$sku" within file'); continue; }
      if (sku.isNotEmpty) seenSkus.add(sku);
      final sell = iSell >= 0 ? double.tryParse(get(iSell)) ?? 0 : 0;
      final cost = iCost >= 0 ? double.tryParse(get(iCost)) ?? 0 : 0;
      valid.add({
        'name': name,
        'sku': sku.isEmpty ? null : sku,
        'barcode': iBarcode >= 0 && get(iBarcode).isNotEmpty ? get(iBarcode) : null,
        'base_uom_id': uomId,
        'product_type': iType >= 0 && get(iType).isNotEmpty ? get(iType) : null,
        'product_main_group': iMain >= 0 && get(iMain).isNotEmpty ? get(iMain) : null,
        'product_group': iGroup >= 0 && get(iGroup).isNotEmpty ? get(iGroup) : null,
        'product_sub_group': iSub >= 0 && get(iSub).isNotEmpty ? get(iSub) : null,
        'product_class': iClass >= 0 && get(iClass).isNotEmpty ? get(iClass) : null,
        'product_movement_category': iMov >= 0 && get(iMov).isNotEmpty ? get(iMov) : null,
        'selling_price': sell,
        'cost_price': cost,
        'low_stock_limit': iLow >= 0 ? (double.tryParse(get(iLow)) ?? 0) : 0,
      });
    }
    setState(() { _totalParsed = rows.length - 1; _validRows = valid; _rowErrors = errors; });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import Products from CSV'),
      content: SizedBox(
        width: 640,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.storefront_outlined, size: 16, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            const Text('Import into branches (optional):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          if (widget.branches.isEmpty)
            const Text('No branches found.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))
          else
            Wrap(spacing: 8, runSpacing: 4, children: widget.branches.map((b) {
              final bid = b['id'] as String;
              final checked = _importBranches.contains(bid);
              return FilterChip(
                label: Text(b['name'] as String? ?? '-'),
                selected: checked,
                onSelected: (v) => setState(() { if (v) _importBranches.add(bid); else _importBranches.remove(bid); }),
              );
            }).toList()),
          const SizedBox(height: 4),
          const Text('Imported products start at zero stock in the selected branches. Leave blank to import without allocating to any branch.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          const Divider(height: 22),
          if (_fileName == null) ...[
            const Text('Upload a CSV with your products. The "name" and "uom" columns are required; everything else is optional.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 16),
            Row(children: [
              OutlinedButton.icon(onPressed: _downloadTemplate, icon: const Icon(Icons.download, size: 16), label: const Text('Download Template')),
              const SizedBox(width: 12),
              ElevatedButton.icon(onPressed: _pickFile, icon: const Icon(Icons.attach_file, size: 16), label: const Text('Choose CSV File')),
            ]),
            const SizedBox(height: 14),
            const Text('UOM matches by abbreviation (e.g. "pcs", "box") or full name.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            const Text('Duplicate SKUs (already in DB or repeated in file) are skipped.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ] else ...[
            Row(children: [
              const Icon(Icons.description_outlined, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Expanded(child: Text(_fileName!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
              TextButton(onPressed: _pickFile, child: const Text('Replace')),
            ]),
            const Divider(),
            if (_fatalError != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.08), borderRadius: BorderRadius.circular(6)),
                child: Text(_fatalError!, style: const TextStyle(color: AppTheme.danger, fontSize: 13, fontWeight: FontWeight.w600)),
              )
            else ...[
              Row(children: [
                _stat('Parsed', _totalParsed.toString(), AppTheme.textSecondary),
                const SizedBox(width: 12),
                _stat('Valid', _validRows.length.toString(), AppTheme.success),
                const SizedBox(width: 12),
                _stat('Skipped', _rowErrors.length.toString(), AppTheme.warning),
              ]),
              const SizedBox(height: 12),
              if (_rowErrors.isNotEmpty) Container(
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: AppTheme.warning.withOpacity(0.06), borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.warning.withOpacity(0.3))),
                child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _rowErrors.map((e) => Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(e, style: const TextStyle(fontSize: 11)))).toList())),
              ),
            ],
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: _importing ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        if (_validRows.isNotEmpty) ElevatedButton(
          onPressed: _importing ? null : () async {
            setState(() => _importing = true);
            await widget.onImport(_validRows, _importBranches.toList());
            if (mounted) Navigator.pop(context);
          },
          child: Text(_importing ? 'Importing...' : 'Import ${_validRows.length} rows'),
        ),
      ],
    );
  }

  Widget _stat(String label, String val, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withOpacity(0.25))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
      Text(val, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color)),
    ]),
  );
}
