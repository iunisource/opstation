import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpPosCatalogScreen extends ConsumerStatefulWidget {
  const ErpPosCatalogScreen({super.key});
  @override
  ConsumerState<ErpPosCatalogScreen> createState() => _ErpPosCatalogScreenState();
}

class _ErpPosCatalogScreenState extends ConsumerState<ErpPosCatalogScreen> {
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _filtered = [];
  List<Map<String, dynamic>> _allBranches = [];
  bool _loading = true;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_filter);
    _load();
  }

  @override
  void dispose() { _searchCtrl.dispose(); super.dispose(); }

  void _filter() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filtered = q.isEmpty ? _items : _items.where((i) =>
          (i['name'] as String? ?? '').toLowerCase().contains(q) ||
          (i['sku'] as String? ?? '').toLowerCase().contains(q)).toList();
    });
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = _branchId;
    if (orgId == null || branchId == null) { setState(() => _loading = false); return; }
    try {
      final client = Supabase.instance.client;
      final items = await client.from('pos_catalog')
          .select().eq('org_id', orgId).eq('branch_id', branchId).order('name');
      final branches = await client.from('branches')
          .select().eq('org_id', orgId).eq('is_active', true).order('name');
      setState(() {
        _items = List<Map<String, dynamic>>.from(items);
        _filtered = _items;
        _allBranches = List<Map<String, dynamic>>.from(branches);
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? item) {
    final nameCtrl = TextEditingController(text: item?['name'] ?? '');
    final skuCtrl = TextEditingController(text: item?['sku'] ?? '');
    final barcodeCtrl = TextEditingController(text: item?['barcode'] ?? '');
    final priceCtrl = TextEditingController(text: item?['price']?.toString() ?? '0');
    final categoryCtrl = TextEditingController(text: item?['category'] ?? '');
    bool isActive = item?['is_active'] as bool? ?? true;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(item == null ? 'Add POS Item' : 'Edit POS Item'),
          content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Item Name *')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TextField(controller: skuCtrl, decoration: const InputDecoration(labelText: 'SKU'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: barcodeCtrl, decoration: const InputDecoration(labelText: 'Barcode'))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TextField(controller: priceCtrl,
                  decoration: const InputDecoration(labelText: 'Price *'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: categoryCtrl, decoration: const InputDecoration(labelText: 'Category'))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              const Text('Active', style: TextStyle(fontSize: 13)),
              const Spacer(),
              Switch(value: isActive, onChanged: (v) => setS(() => isActive = v)),
            ]),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Name required')));
                  return;
                }
                final orgId = ref.read(currentUserProvider)?.orgId;
                final branchId = _branchId;
                final data = {
                  'org_id': orgId, 'branch_id': branchId,
                  'name': nameCtrl.text.trim(),
                  'sku': skuCtrl.text.trim().isEmpty ? null : skuCtrl.text.trim(),
                  'barcode': barcodeCtrl.text.trim().isEmpty ? null : barcodeCtrl.text.trim(),
                  'price': double.tryParse(priceCtrl.text.trim()) ?? 0,
                  'category': categoryCtrl.text.trim().isEmpty ? null : categoryCtrl.text.trim(),
                  'is_active': isActive,
                  'updated_at': DateTime.now().toUtc().toIso8601String(),
                };
                try {
                  if (item == null) {
                    await Supabase.instance.client.from('pos_catalog').insert({
                      ...data, 'id': 'posc_${DateTime.now().millisecondsSinceEpoch}',
                    });
                  } else {
                    await Supabase.instance.client.from('pos_catalog').update(data).eq('id', item['id']);
                  }
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack(item == null ? 'Item added' : 'Item updated');
                  _load();
                } catch (e) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: $e')));
                }
              },
              child: Text(item == null ? 'Add' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showSyncDialog() {
    final branchId = _branchId;
    if (branchId == null) return;
    final otherBranches = _allBranches.where((b) => b['id'] != branchId).toList();
    if (otherBranches.isEmpty) { _showSnack('No other branches available'); return; }
    final selected = <String>{};
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Copy Catalog to Branches'),
          content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Select destination branches. Existing items will not be overwritten.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            ...otherBranches.map((b) => CheckboxListTile(
              dense: true,
              title: Text(b['name'] as String),
              value: selected.contains(b['id'] as String),
              onChanged: (v) => setS(() {
                if (v == true) selected.add(b['id'] as String);
                else selected.remove(b['id'] as String);
              }),
            )),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (selected.isEmpty) return;
                final orgId = ref.read(currentUserProvider)?.orgId;
                try {
                  int copied = 0;
                  for (final targetBranchId in selected) {
                    for (final item in _items) {
                      final existing = await Supabase.instance.client.from('pos_catalog')
                          .select('id').eq('org_id', orgId!).eq('branch_id', targetBranchId)
                          .eq('name', item['name'] as String).maybeSingle();
                      if (existing != null) continue;
                      await Supabase.instance.client.from('pos_catalog').insert({
                        'id': 'posc_${DateTime.now().millisecondsSinceEpoch}_$copied',
                        'org_id': orgId, 'branch_id': targetBranchId,
                        'name': item['name'], 'sku': item['sku'],
                        'barcode': item['barcode'], 'price': item['price'],
                        'category': item['category'], 'is_active': item['is_active'],
                      });
                      copied++;
                    }
                  }
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack('Copied $copied items to ${selected.length} branch(es)');
                } catch (e) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: $e')));
                }
              },
              child: const Text('Copy'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(selectedBranchProvider);
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('POS Catalog', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (branch != null) ...[
            OutlinedButton.icon(
              onPressed: _showSyncDialog,
              icon: const Icon(Icons.copy_outlined, size: 16),
              label: const Text('Copy to Branch'),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: () => _showDialog(context, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Item'),
            ),
          ],
        ]),
        const SizedBox(height: 8),
        Text(branch == null ? 'Select a branch' : 'Branch: ${branch['name']} — ${_filtered.length} items',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        if (branch != null)
          SizedBox(width: 320, child: TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search by name or SKU...',
              prefixIcon: Icon(Icons.search, size: 18),
              isDense: true,
            ),
          )),
        const SizedBox(height: 16),
        if (_loading) const Center(child: CircularProgressIndicator())
        else if (branch == null)
          const Center(child: Text('No branch selected.', style: TextStyle(color: AppTheme.textSecondary)))
        else Expanded(child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
              child: const Row(children: [
                Expanded(flex: 3, child: Text('Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('SKU', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Category', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Price', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 1, child: Text('Active', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                SizedBox(width: 80),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _filtered.isEmpty
                  ? const Center(child: Text('No items yet.', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      itemCount: _filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final item = _filtered[i];
                        final isActive = item['is_active'] as bool? ?? true;
                        return Opacity(
                          opacity: isActive ? 1.0 : 0.5,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(children: [
                              Expanded(flex: 3, child: Text(item['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600))),
                              Expanded(flex: 2, child: Text(item['sku'] as String? ?? '-',
                                  style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600))),
                              Expanded(flex: 2, child: Text(item['category'] as String? ?? '-',
                                  style: const TextStyle(color: AppTheme.textSecondary))),
                              Expanded(flex: 2, child: Text((item['price'] as num?)?.toStringAsFixed(2) ?? '0',
                                  style: const TextStyle(fontWeight: FontWeight.w700))),
                              Expanded(flex: 1, child: Icon(isActive ? Icons.check_circle : Icons.cancel_outlined,
                                  color: isActive ? AppTheme.success : AppTheme.textSecondary, size: 18)),
                              SizedBox(width: 80, child: Row(children: [
                                IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _showDialog(context, item)),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                                  onPressed: () async {
                                    await Supabase.instance.client.from('pos_catalog').delete().eq('id', item['id']);
                                    _showSnack('Item deleted');
                                    _load();
                                  },
                                ),
                              ])),
                            ]),
                          ),
                        );
                      }),
            ),
          ]),
        )),
      ]),
    );
  }
}
