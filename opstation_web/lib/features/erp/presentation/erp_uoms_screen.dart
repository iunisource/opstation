import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/utils/friendly_error.dart';

class ErpUomsScreen extends ConsumerStatefulWidget {
  const ErpUomsScreen({super.key});
  @override
  ConsumerState<ErpUomsScreen> createState() => _ErpUomsScreenState();
}

class _ErpUomsScreenState extends ConsumerState<ErpUomsScreen> {
  List<Map<String, dynamic>> _uoms = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final res = await Supabase.instance.client
          .from('uoms')
          .select()
          .eq('org_id', orgId)
          .order('name');
      setState(() {
        _uoms = List<Map<String, dynamic>>.from(res);
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

  Future<void> _delete(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete UOM'),
        content: const Text('This cannot be undone. Only delete if no products use this UOM.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
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
        _showSnack(friendlyError('That did not save', e));
      }
    }
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? uom) {
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
                      SnackBar(content: Text(friendlyError('That did not save', e))));
                }
              }
            },
            child: Text(uom == null ? 'Add' : 'Save'),
          ),
        ],
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
            const Text('Units of Measure',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () => _showDialog(context, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add UOM'),
            ),
          ]),
          const SizedBox(height: 8),
          Text('${_uoms.length} units',
              style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 24),
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
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: const BoxDecoration(
                        color: AppTheme.background,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                      ),
                      child: const Row(children: [
                        Expanded(flex: 3, child: Text('Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Abbreviation', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
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
                                  child: Text(
                                      u['abbreviation'] as String? ?? '',
                                      style: const TextStyle(
                                          color: AppTheme.primary,
                                          fontWeight: FontWeight.w600))),
                              SizedBox(
                                width: 80,
                                child: Row(children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit_outlined, size: 18),
                                    onPressed: () => _showDialog(context, u),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        size: 18, color: AppTheme.danger),
                                    onPressed: () => _delete(u['id'] as String),
                                    tooltip: 'Delete',
                                  ),
                                ]),
                              ),
                            ]),
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
