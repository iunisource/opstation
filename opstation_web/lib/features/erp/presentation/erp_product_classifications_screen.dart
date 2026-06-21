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
  List<Map<String, dynamic>> _uoms = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // taxonomy tabs + one Units of Measure tab
    _tabCtrl = TabController(length: _taxonomyTypes.length + 1, vsync: this);
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
    final client = Supabase.instance.client;
    try {
      final res = await client
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
      // UOMs live in their own table; load best-effort so the taxonomy tabs
      // still render even if this fails.
      List<Map<String, dynamic>> uoms = [];
      try {
        final ures = await client
            .from('uoms')
            .select()
            .eq('org_id', orgId)
            .order('name');
        uoms = List<Map<String, dynamic>>.from(ures);
      } catch (_) {}
      setState(() {
        _data
          ..clear()
          ..addAll(grouped);
        _uoms = uoms;
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

  // ─────────────────────────── Taxonomy CRUD ───────────────────────────
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

  // ───────────────────────── Units of Measure CRUD ─────────────────────────
  void _showUomDialog(Map<String, dynamic>? uom) {
    final nameCtrl = TextEditingController(text: uom?['name'] ?? '');
    final abbrCtrl = TextEditingController(text: uom?['abbreviation'] ?? '');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(uom == null ? 'Add Unit of Measure' : 'Edit UOM'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                    labelText: 'Name *', hintText: 'e.g. Kilogram')),
            const SizedBox(height: 12),
            TextField(
                controller: abbrCtrl,
                decoration: const InputDecoration(
                    labelText: 'Abbreviation *', hintText: 'e.g. kg')),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty || abbrCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Name and abbreviation are required')));
                return;
              }
              final orgId = ref.read(currentUserProvider)?.orgId;
              final data = {
                'org_id': orgId,
                'name': nameCtrl.text.trim(),
                'abbreviation': abbrCtrl.text.trim(),
              };
              try {
                if (uom == null) {
                  final id = 'uom_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client
                      .from('uoms')
                      .insert({...data, 'id': id});
                } else {
                  await Supabase.instance.client
                      .from('uoms')
                      .update(data)
                      .eq('id', uom['id']);
                }
                if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
                _showSnack(uom == null ? 'UOM added' : 'UOM updated');
                _load();
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed: $e')));
                }
              }
            },
            child: Text(uom == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteUom(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete UOM'),
        content: const Text(
            'This cannot be undone. Only delete if no products use this UOM.'),
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
        await Supabase.instance.client.from('uoms').delete().eq('id', id);
        _showSnack('UOM deleted');
        _load();
      } catch (e) {
        _showSnack('Failed: $e');
      }
    }
  }

  // ─────────────────────────────── Views ───────────────────────────────
  Widget _taxonomyView(String type, String label) {
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
                    child: Text('No $label values yet. Add one to use in products.',
                        style: const TextStyle(color: AppTheme.textSecondary)))
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final item = items[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        child: Row(children: [
                          Expanded(
                              child: Text(item['name'] as String? ?? '',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600))),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: () => _showDialog(type, item),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                size: 18, color: AppTheme.danger),
                            onPressed: () => _delete(item['id'] as String, type),
                          ),
                        ]),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _uomView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text('${_uoms.length} units of measure',
              style: const TextStyle(color: AppTheme.textSecondary)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: () => _showUomDialog(null),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add UOM'),
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
            child: _uoms.isEmpty
                ? const Center(
                    child: Text('No units yet. Add one to use in products.',
                        style: TextStyle(color: AppTheme.textSecondary)))
                : Column(children: [
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: const BoxDecoration(
                        color: AppTheme.background,
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(12)),
                      ),
                      child: const Row(children: [
                        Expanded(
                            flex: 3,
                            child: Text('Name',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                    color: AppTheme.textSecondary))),
                        Expanded(
                            flex: 2,
                            child: Text('Abbreviation',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                    color: AppTheme.textSecondary))),
                        SizedBox(width: 80),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _uoms.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final u = _uoms[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 12),
                            child: Row(children: [
                              Expanded(
                                  flex: 3,
                                  child: Text(u['name'] as String? ?? '',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600))),
                              Expanded(
                                  flex: 2,
                                  child: Text(u['abbreviation'] as String? ?? '',
                                      style: const TextStyle(
                                          color: AppTheme.primary,
                                          fontWeight: FontWeight.w600))),
                              SizedBox(
                                width: 80,
                                child: Row(children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit_outlined, size: 18),
                                    onPressed: () => _showUomDialog(u),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        size: 18, color: AppTheme.danger),
                                    onPressed: () => _deleteUom(u['id'] as String),
                                    tooltip: 'Delete',
                                  ),
                                ]),
                              ),
                            ]),
                          );
                        },
                      ),
                    ),
                  ]),
          ),
        ),
      ],
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
          const Text('Product Classifications',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text(
              'Manage dropdown values for product classification fields and units of measure.',
              style: TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 24),
          TabBar(
            controller: _tabCtrl,
            isScrollable: true,
            labelColor: AppTheme.primary,
            unselectedLabelColor: AppTheme.textSecondary,
            indicatorColor: AppTheme.primary,
            tabs: [
              ..._taxonomyTypes.values.map((label) => Tab(text: label)),
              const Tab(text: 'Units of Measure'),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  ..._taxonomyTypes.entries.map((e) => _taxonomyView(e.key, e.value)),
                  _uomView(),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
