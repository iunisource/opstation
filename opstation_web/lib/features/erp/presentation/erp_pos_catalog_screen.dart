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
  bool _allowNoStock = false;
  bool _allowPriceEdit = false;
  bool _savingSetting = false;
  Map<String, double> _stockMap = {};
  final Set<String> _selected = {};   // pos_catalog row ids selected for bulk delete
  final _searchCtrl = TextEditingController();

  bool get _isAdmin { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.admin || r == WebUserRole.masterAdmin; }

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_filter);
    _load();
    _loadSetting();
  }

  Future<void> _loadSetting() async {
    final orgId = ref.read(currentUserProvider)?.orgId; if (orgId == null) return;
    try {
      final s = await Supabase.instance.client.from('pos_settings')
          .select('allow_sell_without_stock, allow_price_edit').eq('org_id', orgId).maybeSingle();
      if (mounted) setState(() {
        _allowNoStock = s != null && s['allow_sell_without_stock'] == true;
        _allowPriceEdit = s != null && s['allow_price_edit'] == true;
      });
    } catch (_) {}
  }

  Future<void> _setAllowNoStock(bool v) async {
    final orgId = ref.read(currentUserProvider)?.orgId; if (orgId == null) return;
    setState(() { _allowNoStock = v; _savingSetting = true; });
    try {
      await Supabase.instance.client.from('pos_settings').upsert({
        'org_id': orgId, 'allow_sell_without_stock': v,
        'updated_at': DateTime.now().toIso8601String(), 'updated_by': ref.read(currentUserProvider)?.id,
      }, onConflict: 'org_id');
      _showSnack(v ? 'Selling without stock is now ALLOWED' : 'Selling without stock is now LOCKED');
    } catch (e) { _showSnack('Failed to save setting: $e'); if (mounted) setState(() => _allowNoStock = !v); }
    if (mounted) setState(() => _savingSetting = false);
  }

  Future<void> _setAllowPriceEdit(bool v) async {
    final orgId = ref.read(currentUserProvider)?.orgId; if (orgId == null) return;
    setState(() { _allowPriceEdit = v; _savingSetting = true; });
    try {
      await Supabase.instance.client.from('pos_settings').upsert({
        'org_id': orgId, 'allow_price_edit': v,
        'updated_at': DateTime.now().toIso8601String(), 'updated_by': ref.read(currentUserProvider)?.id,
      }, onConflict: 'org_id');
      _showSnack(v ? 'Price editing is now ALLOWED at POS' : 'Price editing is now LOCKED (system price)');
    } catch (e) { _showSnack('Failed to save setting: $e'); if (mounted) setState(() => _allowPriceEdit = !v); }
    if (mounted) setState(() => _savingSetting = false);
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
      final branches = await client.from('branches')
          .select().eq('org_id', orgId).eq('is_active', true).order('name');
      final branchList = List<Map<String, dynamic>>.from(branches);
      // If the selected branch doesn't belong to this org (e.g. left over from a
      // previous org after switching), don't query pos_catalog with a foreign
      // branch_id — show an empty catalog until a valid branch is selected.
      final branchInOrg = branchList.any((b) => b['id'] == branchId);
      if (!branchInOrg) {
        setState(() {
          _items = []; _filtered = []; _allBranches = branchList;
          _stockMap = {}; _loading = false;
        });
        return;
      }
      final items = await client.from('pos_catalog')
          .select().eq('org_id', orgId).eq('branch_id', branchId).order('name');
      final stockRows = await client.from('inventory_stock').select('product_id, quantity').eq('org_id', orgId).eq('branch_id', branchId);
      setState(() {
        _items = List<Map<String, dynamic>>.from(items);
        _filtered = _items;
        _allBranches = branchList;
        _stockMap = {for (final s in stockRows as List) s['product_id'] as String: (s['quantity'] as num?)?.toDouble() ?? 0.0};
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  Future<void> _bulkDelete() async {
    if (!_isAdmin) return;
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final branch = ref.read(selectedBranchProvider);
    final branchName = branch?['name'] as String? ?? 'this branch';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove from POS catalog?'),
        content: Text('Remove ${ids.length} product${ids.length == 1 ? "" : "s"} from $branchName\'s POS catalog?\n\n'
            'The products themselves are NOT deleted — they just stop being sellable at this branch\'s POS. '
            'Items with linked POS sales will be skipped.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text('Remove ${ids.length}'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    int removed = 0; int skipped = 0;
    for (final id in ids) {
      try {
        await Supabase.instance.client.from('pos_catalog').delete().eq('id', id);
        removed++;
      } catch (_) { skipped++; }
    }
    if (!mounted) return;
    setState(() => _selected.clear());
    _showSnack('Removed $removed from POS catalog${skipped > 0 ? " — $skipped skipped (have linked records)" : ""}');
    await _load();
  }

  void _showSnack(String msg) {    if (!mounted) return;
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
    // Reload whenever the selected branch changes (org switch, or the provider
    // populating after first paint). This fixes: (a) items not appearing until
    // several refreshes — the branch wasn't ready on first load; and (b) a stale
    // branch from a previous org showing after an org switch.
    ref.listen(selectedBranchProvider, (prev, next) {
      final prevId = (prev as Map<String, dynamic>?)?['id'];
      final nextId = (next as Map<String, dynamic>?)?['id'];
      if (prevId != nextId) {
        _selected.clear();
        _load();
      }
    });
    final branch = ref.watch(selectedBranchProvider);
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('POS Catalog', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (branch != null) ...[
            if (_isAdmin && _selected.isNotEmpty) ...[
              OutlinedButton.icon(
                onPressed: _bulkDelete,
                icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.danger),
                label: Text('Delete selected (${_selected.length})', style: const TextStyle(color: AppTheme.danger)),
                style: OutlinedButton.styleFrom(side: const BorderSide(color: AppTheme.danger)),
              ),
              const SizedBox(width: 12),
            ],
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
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
          child: Row(children: [
            Icon(_allowNoStock ? Icons.lock_open_outlined : Icons.lock_outline, size: 18, color: _allowNoStock ? Colors.orange.shade800 : AppTheme.textSecondary),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Allow selling without stock', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              Text(_allowNoStock
                  ? 'On — items can be sold even with no stock on hand (inventory may go negative).'
                  : 'Off — an item sells only when it has stock (opening stock or a purchase). Untracked or zero-stock items are locked.',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              if (!_isAdmin) const Text('Only an admin can change this.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontStyle: FontStyle.italic)),
            ])),
            const SizedBox(width: 12),
            if (_savingSetting) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            else Switch(value: _allowNoStock, onChanged: _isAdmin ? _setAllowNoStock : null),
          ]),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
          child: Row(children: [
            Icon(_allowPriceEdit ? Icons.edit_outlined : Icons.lock_outline, size: 18, color: _allowPriceEdit ? Colors.orange.shade800 : AppTheme.textSecondary),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Allow price edit', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              Text(_allowPriceEdit
                  ? 'On — cashiers can change an item\'s price during a sale.'
                  : 'Off — the system price is used and cannot be changed at POS.',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              if (!_isAdmin) const Text('Only an admin can change this.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontStyle: FontStyle.italic)),
            ])),
            const SizedBox(width: 12),
            if (_savingSetting) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            else Switch(value: _allowPriceEdit, onChanged: _isAdmin ? _setAllowPriceEdit : null),
          ]),
        ),
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
              child: Row(children: [
                if (_isAdmin) SizedBox(width: 40, child: Checkbox(
                  value: _filtered.isNotEmpty && _filtered.every((i) => _selected.contains(i['id'])),
                  tristate: true,
                  onChanged: (v) => setState(() {
                    final filteredIds = _filtered.map((i) => i['id'] as String).toSet();
                    if (_filtered.every((i) => _selected.contains(i['id']))) {
                      _selected.removeAll(filteredIds);   // all selected -> clear
                    } else {
                      _selected.addAll(filteredIds);      // select all filtered
                    }
                  }),
                )),
                const Expanded(flex: 3, child: Text('Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                const Expanded(flex: 2, child: Text('SKU', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                const Expanded(flex: 2, child: Text('Category', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                const Expanded(flex: 2, child: Text('Price', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                const Expanded(flex: 1, child: Text('Stock', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                const Expanded(flex: 1, child: Text('Active', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                const SizedBox(width: 80),
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
                              if (_isAdmin) SizedBox(width: 40, child: Checkbox(
                                value: _selected.contains(item['id']),
                                onChanged: (v) => setState(() {
                                  if (v == true) { _selected.add(item['id'] as String); }
                                  else { _selected.remove(item['id']); }
                                }),
                              )),
                              Expanded(flex: 3, child: Text(item['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600))),
                              Expanded(flex: 2, child: Text(item['sku'] as String? ?? '-',
                                  style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600))),
                              Expanded(flex: 2, child: Text(item['category'] as String? ?? '-',
                                  style: const TextStyle(color: AppTheme.textSecondary))),
                              Expanded(flex: 2, child: Text((item['price'] as num?)?.toStringAsFixed(2) ?? '0',
                                  style: const TextStyle(fontWeight: FontWeight.w700))),
                              Expanded(flex: 1, child: Builder(builder: (_) {
                                final pid = item['product_id'] as String?;
                                final stock = pid != null ? (_stockMap[pid] ?? 0.0) : 0.0;
                                Color col = stock > 10 ? AppTheme.success : (stock > 0 ? Colors.orange : AppTheme.danger);
                                return Text(stock.toStringAsFixed(0), style: TextStyle(fontWeight: FontWeight.w700, color: col));
                              })),
                              Expanded(flex: 1, child: Icon(isActive ? Icons.check_circle : Icons.cancel_outlined,
                                  color: isActive ? AppTheme.success : AppTheme.textSecondary, size: 18)),
                              SizedBox(width: 80, child: Row(children: [
                                IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _showDialog(context, item)),
                                if (_isAdmin) IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                                  onPressed: () async {
                                    await Supabase.instance.client.from('pos_catalog').delete().eq('id', item['id']);
                                    _showSnack('Removed from POS catalog');
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
