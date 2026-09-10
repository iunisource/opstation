import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class CompetitorCategoriesScreen extends ConsumerStatefulWidget {
  const CompetitorCategoriesScreen({super.key});
  @override
  ConsumerState<CompetitorCategoriesScreen> createState() => _CompetitorCategoriesScreenState();
}

class _CompetitorCategoriesScreenState extends ConsumerState<CompetitorCategoriesScreen> {
  List<Map<String, dynamic>> _items = [];
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
          .from('competitor_categories')
          .select()
          .eq('org_id', orgId)
          .order('position')
          .order('name');
      setState(() {
        _items = List<Map<String, dynamic>>.from(rows);
        _filtered = _items;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _filter() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filtered = _items.where((c) {
        return matchesQuery('${c['name'] ?? ''}', q);
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

  Future<void> _toggleActive(Map<String, dynamic> c) async {
    final newVal = !(c['is_active'] as bool? ?? true);
    try {
      await Supabase.instance.client.from('competitor_categories').update({
        'is_active': newVal,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', c['id']);
      _showSnack(newVal ? 'Category activated' : 'Category deactivated');
      _load();
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
    }
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? category) {
    final nameCtrl = TextEditingController(text: category?['name'] ?? '');
    final posCtrl = TextEditingController(text: (category?['position'] ?? 0).toString());

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(category == null ? 'Add Category' : 'Edit Category'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Category Name *',
                hintText: 'e.g. Tubes, Helmets, Tires',
              ),
              autofocus: true,
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
              final data = {
                'name': nameCtrl.text.trim(),
                'position': position,
                'org_id': orgId,
                'is_active': true,
                'updated_at': DateTime.now().toIso8601String(),
              };
              final isNew = category == null;
              try {
                if (isNew) {
                  final id = 'cc_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client.from('competitor_categories').insert({...data, 'id': id});
                } else {
                  await Supabase.instance.client.from('competitor_categories').update(data).eq('id', category['id']);
                }
                if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
                _showSnack(isNew ? 'Category added' : 'Category updated');
                _load();
              } catch (e) {
                _showSnack('Failed: ${e.toString().split('\n').first}');
              }
            },
            child: Text(category == null ? 'Add' : 'Save'),
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
            const Text('Competitor Categories', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            if (canEdit)
              ElevatedButton.icon(
                onPressed: () => _showDialog(context, null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Category'),
              ),
          ]),
          const SizedBox(height: 8),
          Text('${_filtered.length} categories', style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          const Text(
            'Categories surveyors will tag competitor brands against. These can differ from your own product catalog (e.g. track competitor presence in adjacent categories you do not sell).',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search categories...',
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
                      Expanded(child: Text('Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 100, child: Text('Position', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 100, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 120),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      itemCount: _filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final c = _filtered[i];
                        final isActive = c['is_active'] as bool? ?? true;
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          child: Row(children: [
                            Expanded(child: Text(c['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600))),
                            SizedBox(width: 100, child: Text((c['position'] ?? 0).toString(), style: const TextStyle(fontSize: 13))),
                            SizedBox(width: 100, child: Text(
                              isActive ? 'Active' : 'Inactive',
                              style: TextStyle(fontSize: 13, color: isActive ? AppTheme.success : AppTheme.textSecondary, fontWeight: FontWeight.w600),
                            )),
                            SizedBox(width: 120, child: canEdit ? Row(children: [
                              IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _showDialog(context, c)),
                              IconButton(
                                icon: Icon(isActive ? Icons.block : Icons.check_circle_outline, size: 18,
                                  color: isActive ? AppTheme.danger : AppTheme.success),
                                tooltip: isActive ? 'Deactivate' : 'Activate',
                                onPressed: () => _toggleActive(c),
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
