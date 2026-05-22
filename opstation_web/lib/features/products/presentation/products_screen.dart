import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key});
  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _filtered = [];
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
      final rows = await Supabase.instance.client
          .from('products')
          .select()
          .eq('org_id', orgId)
          .order('position')
          .order('name');
      setState(() {
        _products = List<Map<String, dynamic>>.from(rows);
        _filtered = _products;
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
        final name = (p['name'] as String? ?? '').toLowerCase();
        final sku = (p['sku_code'] as String? ?? '').toLowerCase();
        return name.contains(q) || sku.contains(q);
      }).toList();
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  bool _canEdit(WebUserRole? role) =>
      role == WebUserRole.masterAdmin || role == WebUserRole.admin;

  Future<void> _toggleActive(Map<String, dynamic> p) async {
    final newVal = !(p['is_active'] as bool? ?? true);
    try {
      await Supabase.instance.client.from('products').update({
        'is_active': newVal,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', p['id']);
      _showSnack(newVal ? 'Product activated' : 'Product deactivated');
      _load();
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
    }
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? product) {
    final nameCtrl = TextEditingController(text: product?['name'] ?? '');
    final skuCtrl = TextEditingController(text: product?['sku_code'] ?? '');
    final posCtrl = TextEditingController(text: (product?['position'] ?? 0).toString());

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(product == null ? 'Add Product' : 'Edit Product'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Product Name *'),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: skuCtrl,
              decoration: const InputDecoration(
                labelText: 'SKU Code',
                hintText: 'Optional internal code',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: posCtrl,
              decoration: const InputDecoration(
                labelText: 'Display Position',
                hintText: 'Lower numbers appear first',
              ),
              keyboardType: TextInputType.number,
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Name is required')));
                return;
              }
              final orgId = ref.read(currentUserProvider)?.orgId;
              final position = int.tryParse(posCtrl.text.trim()) ?? 0;
              final sku = skuCtrl.text.trim();
              final data = {
                'name': nameCtrl.text.trim(),
                'sku_code': sku.isEmpty ? null : sku,
                'position': position,
                'org_id': orgId,
                'is_active': true,
                'updated_at': DateTime.now().toIso8601String(),
              };
              final isNew = product == null;
              try {
                if (isNew) {
                  final id = 'prod_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client.from('products').insert({...data, 'id': id});
                } else {
                  await Supabase.instance.client.from('products').update(data).eq('id', product['id']);
                }
                if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
                _showSnack(isNew ? 'Product added' : 'Product updated');
                _load();
              } catch (e) {
                _showSnack('Failed: ${e.toString().split('\n').first}');
              }
            },
            child: Text(product == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = _canEdit(ref.watch(currentUserProvider)?.role);
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Products', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            if (canEdit)
              ElevatedButton.icon(
                onPressed: () => _showDialog(context, null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Product'),
              ),
          ]),
          const SizedBox(height: 8),
          Text('${_filtered.length} products', style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          const Text(
            'Your own SKU catalog. Surveyors will tick which of these are physically displayed at each shop during Placement Audit.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search by name or SKU code...',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: const BoxDecoration(
                      color: AppTheme.background,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                    ),
                    child: const Row(children: [
                      Expanded(flex: 4, child: Text('Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('SKU Code', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 80, child: Text('Position', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 80, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
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
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          child: Row(children: [
                            Expanded(flex: 4, child: Text(p['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600))),
                            Expanded(flex: 2, child: Text(p['sku_code'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                            SizedBox(width: 80, child: Text((p['position'] ?? 0).toString(), style: const TextStyle(fontSize: 13))),
                            SizedBox(width: 80, child: Text(
                              isActive ? 'Active' : 'Inactive',
                              style: TextStyle(fontSize: 13, color: isActive ? AppTheme.success : AppTheme.textSecondary, fontWeight: FontWeight.w600),
                            )),
                            SizedBox(width: 120, child: canEdit ? Row(children: [
                              IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _showDialog(context, p)),
                              IconButton(
                                icon: Icon(isActive ? Icons.block : Icons.check_circle_outline, size: 18,
                                  color: isActive ? AppTheme.danger : AppTheme.success),
                                tooltip: isActive ? 'Deactivate' : 'Activate',
                                onPressed: () => _toggleActive(p),
                              ),
                            ]) : null),
                          ]),
                        );
                      },
                    ),
                  ),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}
