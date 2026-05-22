import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpOpeningStockScreen extends ConsumerStatefulWidget {
  const ErpOpeningStockScreen({super.key});
  @override
  ConsumerState<ErpOpeningStockScreen> createState() => _ErpOpeningStockScreenState();
}

class _ErpOpeningStockScreenState extends ConsumerState<ErpOpeningStockScreen> {
  List<Map<String, dynamic>> _entries = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _uoms = [];
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
      final entries = await client
          .from('opening_stock')
          .select('*, products(name, sku), uoms(name, abbreviation)')
          .eq('org_id', orgId)
          .eq('branch_id', branchId)
          .order('created_at', ascending: false);
      final products = await client
          .from('products')
          .select('id, name, sku, base_uom_id')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      final uoms = await client.from('uoms').select().eq('org_id', orgId).order('name');
      setState(() {
        _entries = List<Map<String, dynamic>>.from(entries);
        _products = List<Map<String, dynamic>>.from(products);
        _uoms = List<Map<String, dynamic>>.from(uoms);
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? entry) {
    String? productId = entry?['product_id'] as String?;
    String? uomId = entry?['uom_id'] as String?;
    final qtyCtrl = TextEditingController(text: entry?['quantity']?.toString() ?? '0');
    final costCtrl = TextEditingController(text: entry?['unit_cost']?.toString() ?? '0');
    DateTime entryDate = entry?['entry_date'] != null
        ? DateTime.parse(entry!['entry_date'] as String) : DateTime.now();

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(entry == null ? 'Add Opening Stock' : 'Edit Opening Stock'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: productId,
                decoration: const InputDecoration(labelText: 'Product *'),
                hint: const Text('Select product'),
                items: _products.map((p) => DropdownMenuItem(
                    value: p['id'] as String,
                    child: Text('${p['name']}${p['sku'] != null ? ' (${p['sku']})' : ''}'))).toList(),
                onChanged: entry == null ? (v) {
                  setS(() {
                    productId = v;
                    final prod = _products.firstWhere((p) => p['id'] == v, orElse: () => {});
                    uomId = prod['base_uom_id'] as String?;
                  });
                } : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: uomId,
                decoration: const InputDecoration(labelText: 'UOM *'),
                hint: const Text('Select UOM'),
                items: _uoms.map((u) => DropdownMenuItem(
                    value: u['id'] as String,
                    child: Text('${u['name']} (${u['abbreviation']})'))).toList(),
                onChanged: (v) => setS(() => uomId = v),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: TextField(controller: qtyCtrl,
                    decoration: const InputDecoration(labelText: 'Quantity *'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: costCtrl,
                    decoration: const InputDecoration(labelText: 'Unit Cost'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true))),
              ]),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: entryDate,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setS(() => entryDate = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Entry Date'),
                  child: Text(DateFormat('d MMM yyyy').format(entryDate)),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (productId == null || uomId == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Product and UOM required')));
                  return;
                }
                final qty = double.tryParse(qtyCtrl.text.trim()) ?? 0;
                final cost = double.tryParse(costCtrl.text.trim()) ?? 0;
                final orgId = ref.read(currentUserProvider)?.orgId;
                final userId = ref.read(currentUserProvider)?.id;
                final branchId = _branchId;
                try {
                  if (entry == null) {
                    await Supabase.instance.client.from('opening_stock').insert({
                      'id': 'os_${DateTime.now().millisecondsSinceEpoch}',
                      'org_id': orgId,
                      'branch_id': branchId,
                      'product_id': productId,
                      'uom_id': uomId,
                      'quantity': qty,
                      'unit_cost': cost,
                      'entry_date': DateFormat('yyyy-MM-dd').format(entryDate),
                      'created_by': userId,
                    });
                    // Also update inventory_stock
                    final existing = await Supabase.instance.client
                        .from('inventory_stock').select()
                        .eq('org_id', orgId!).eq('product_id', productId!).eq('branch_id', branchId!).maybeSingle();
                    if (existing != null) {
                      await Supabase.instance.client.from('inventory_stock').update({
                        'quantity': qty, 'updated_at': DateTime.now().toUtc().toIso8601String(),
                      }).eq('id', existing['id']);
                    } else {
                      await Supabase.instance.client.from('inventory_stock').insert({
                        'id': 'is_${DateTime.now().millisecondsSinceEpoch}',
                        'org_id': orgId, 'product_id': productId,
                        'branch_id': branchId, 'uom_id': uomId, 'quantity': qty,
                      });
                    }
                    // Post movement
                    await Supabase.instance.client.from('inventory_movements').insert({
                      'id': 'im_${DateTime.now().millisecondsSinceEpoch}',
                      'org_id': orgId, 'product_id': productId,
                      'branch_id': branchId, 'uom_id': uomId,
                      'quantity': qty, 'movement_type': 'adjustment',
                      'notes': 'Opening stock entry',
                      'moved_at': DateTime.now().toUtc().toIso8601String(),
                      'created_by': userId,
                    });
                  } else {
                    await Supabase.instance.client.from('opening_stock').update({
                      'quantity': qty, 'unit_cost': cost,
                      'entry_date': DateFormat('yyyy-MM-dd').format(entryDate),
                    }).eq('id', entry['id']);
                  }
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack(entry == null ? 'Opening stock added' : 'Opening stock updated');
                  _load();
                } catch (e) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: $e')));
                }
              },
              child: Text(entry == null ? 'Add' : 'Save'),
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
          const Text('Opening Stock', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: branch == null ? null : () => _showDialog(context, null),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Entry'),
          ),
        ]),
        const SizedBox(height: 4),
        Text(branch == null ? 'Select a branch to view opening stock' : 'Branch: ${branch['name']}',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 24),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (branch == null)
          const Center(child: Text('No branch selected.', style: TextStyle(color: AppTheme.textSecondary)))
        else
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                  child: const Row(children: [
                    Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('SKU', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Quantity', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Unit Cost', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    SizedBox(width: 48),
                  ]),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _entries.isEmpty
                      ? const Center(child: Text('No opening stock entries yet.', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: _entries.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final e = _entries[i];
                            final qty = (e['quantity'] as num?)?.toDouble() ?? 0;
                            final cost = (e['unit_cost'] as num?)?.toDouble() ?? 0;
                            final date = e['entry_date'] != null
                                ? DateFormat('d MMM yyyy').format(DateTime.parse(e['entry_date'] as String)) : '-';
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                              child: Row(children: [
                                Expanded(flex: 4, child: Text(e['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600))),
                                Expanded(flex: 2, child: Text(e['products']?['sku'] as String? ?? '-', style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600))),
                                Expanded(flex: 2, child: Text(qty % 1 == 0 ? qty.toInt().toString() : qty.toString(), style: const TextStyle(fontWeight: FontWeight.w600))),
                                Expanded(flex: 1, child: Text(e['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary))),
                                Expanded(flex: 2, child: Text(cost.toStringAsFixed(2))),
                                Expanded(flex: 2, child: Text(date, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                                SizedBox(width: 48, child: IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  onPressed: () => _showDialog(context, e),
                                )),
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
