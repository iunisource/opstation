import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

const _taxonomyTypes = {
  'product_type': 'Product Type',
  'main_group': 'Main Group',
  'group': 'Group',
  'sub_group': 'Sub Group',
  'class': 'Class',
  'movement_category': 'Movement Category',
};

class ErpProductClassificationsScreen extends ConsumerStatefulWidget {
  const ErpProductClassificationsScreen({super.key});
  @override
  ConsumerState<ErpProductClassificationsScreen> createState() =>
      _ErpProductClassificationsScreenState();
}

class _ErpProductClassificationsScreenState
    extends ConsumerState<ErpProductClassificationsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  final Map<String, List<Map<String, dynamic>>> _data = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _taxonomyTypes.length, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final res = await Supabase.instance.client
          .from('product_taxonomies')
          .select()
          .eq('org_id', orgId)
          .order('name');
      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final type in _taxonomyTypes.keys) {
        grouped[type] = (res as List)
            .where((r) => r['taxonomy_type'] == type)
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
      }
      setState(() {
        _data.addAll(grouped);
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  void _showDialog(String taxonomyType, Map<String, dynamic>? item) {
    final nameCtrl = TextEditingController(text: item?['name'] ?? '');
    final label = _taxonomyTypes[taxonomyType] ?? taxonomyType;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(item == null ? 'Add $label' : 'Edit $label'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: nameCtrl,
            decoration: InputDecoration(labelText: '$label Name *'),
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$label name is required')));
                return;
              }
              final orgId = ref.read(currentUserProvider)?.orgId;
              try {
                if (item == null) {
                  await Supabase.instance.client.from('product_taxonomies').insert({
                    'id': 'ptax_${DateTime.now().millisecondsSinceEpoch}',
                    'org_id': orgId,
                    'taxonomy_type': taxonomyType,
                    'name': nameCtrl.text.trim(),
                  });
                } else {
                  await Supabase.instance.client
                      .from('product_taxonomies')
                      .update({'name': nameCtrl.text.trim()})
                      .eq('id', item['id']);
                }
                if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
                _showSnack(item == null ? '$label added' : '$label updated');
                _load();
              } catch (e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed: $e')));
              }
            },
            child: Text(item == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(String id, String taxonomyType) async {
    final label = _taxonomyTypes[taxonomyType] ?? taxonomyType;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete $label'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await Supabase.instance.client
            .from('product_taxonomies')
            .delete()
            .eq('id', id);
        _showSnack('Deleted');
        _load();
      } catch (e) {
        _showSnack('Failed: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Product Classifications',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Manage dropdown values for product classification fields.',
              style: TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 24),
          TabBar(
            controller: _tabCtrl,
            isScrollable: true,
            labelColor: AppTheme.primary,
            unselectedLabelColor: AppTheme.textSecondary,
            indicatorColor: AppTheme.primary,
            tabs: _taxonomyTypes.values
                .map((label) => Tab(text: label))
                .toList(),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: _taxonomyTypes.entries.map((entry) {
                  final type = entry.key;
                  final label = entry.value;
                  final items = _data[type] ?? [];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text('${items.length} ${label.toLowerCase()} values',
                            style: const TextStyle(color: AppTheme.textSecondary)),
                        const Spacer(),
                        ElevatedButton.icon(
                          onPressed: () => _showDialog(type, null),
                          icon: const Icon(Icons.add, size: 16),
                          label: Text('Add $label'),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppTheme.border),
                          ),
                          child: items.isEmpty
                              ? Center(
                                  child: Text(
                                      'No $label values yet. Add one to use in products.',
                                      style: const TextStyle(
                                          color: AppTheme.textSecondary)))
                              : ListView.separated(
                                  itemCount: items.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 1),
                                  itemBuilder: (_, i) {
                                    final item = items[i];
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 20, vertical: 12),
                                      child: Row(children: [
                                        Expanded(
                                            child: Text(
                                                item['name'] as String? ?? '',
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w600))),
                                        IconButton(
                                          icon: const Icon(
                                              Icons.edit_outlined,
                                              size: 18),
                                          onPressed: () =>
                                              _showDialog(type, item),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                              Icons.delete_outline,
                                              size: 18,
                                              color: AppTheme.danger),
                                          onPressed: () =>
                                              _delete(item['id'] as String, type),
                                        ),
                                      ]),
                                    );
                                  },
                                ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}
