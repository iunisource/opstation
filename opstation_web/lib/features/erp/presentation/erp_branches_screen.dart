import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/utils/friendly_error.dart';

class ErpBranchesScreen extends ConsumerStatefulWidget {
  const ErpBranchesScreen({super.key});
  @override
  ConsumerState<ErpBranchesScreen> createState() => _ErpBranchesScreenState();
}

class _ErpBranchesScreenState extends ConsumerState<ErpBranchesScreen> {
  List<Map<String, dynamic>> _branches = [];
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
          .from('branches')
          .select()
          .eq('org_id', orgId)
          .order('name');
      setState(() {
        _branches = List<Map<String, dynamic>>.from(res);
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

  Future<void> _toggleActive(Map<String, dynamic> w) async {
    final newVal = !(w['is_active'] as bool? ?? true);
    try {
      await Supabase.instance.client
          .from('branches')
          .update({'is_active': newVal})
          .eq('id', w['id']);
      _showSnack(newVal ? 'Branch activated' : 'Branch deactivated');
      _load();
    } catch (e) {
      _showSnack(friendlyError('That did not save', e));
    }
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? branch) {
    final nameCtrl = TextEditingController(text: branch?['name'] ?? '');
    final locationCtrl = TextEditingController(text: branch?['location'] ?? '');

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(branch == null ? 'Add Branch' : 'Edit Branch'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Branch Name *')),
            const SizedBox(height: 12),
            TextField(
                controller: locationCtrl,
                decoration: const InputDecoration(labelText: 'Location / Address'),
                maxLines: 2),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Branch name is required')));
                return;
              }
              final orgId = ref.read(currentUserProvider)?.orgId;
              final data = {
                'org_id': orgId,
                'name': nameCtrl.text.trim(),
                'location': locationCtrl.text.trim().isEmpty
                    ? null
                    : locationCtrl.text.trim(),
                'is_active': true,
              };
              try {
                if (branch == null) {
                  final id = 'wh_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client
                      .from('branches')
                      .insert({...data, 'id': id});
                } else {
                  await Supabase.instance.client
                      .from('branches')
                      .update(data)
                      .eq('id', branch['id']);
                }
                if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
                _showSnack(branch == null ? 'Branch added' : 'Branch updated');
                _load();
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(friendlyError('That did not save', e))));
                }
              }
            },
            child: Text(branch == null ? 'Add' : 'Save'),
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
            const Text('Branches',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () => _showDialog(context, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Branch'),
            ),
          ]),
          const SizedBox(height: 8),
          Text('${_branches.length} branches',
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
                        Expanded(flex: 4, child: Text('Location', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 1, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        SizedBox(width: 80),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _branches.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final w = _branches[i];
                          final isActive = w['is_active'] as bool? ?? true;
                          return Opacity(
                            opacity: isActive ? 1.0 : 0.5,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              child: Row(children: [
                                Expanded(
                                    flex: 3,
                                    child: Text(w['name'] as String? ?? '',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600))),
                                Expanded(
                                    flex: 4,
                                    child: Text(
                                        w['location'] as String? ?? '-',
                                        style: const TextStyle(
                                            color: AppTheme.textSecondary,
                                            fontSize: 13))),
                                Expanded(
                                  flex: 1,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: isActive
                                          ? AppTheme.success.withOpacity(0.1)
                                          : AppTheme.danger.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      isActive ? 'Active' : 'Inactive',
                                      style: TextStyle(
                                          color: isActive
                                              ? AppTheme.success
                                              : AppTheme.danger,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 80,
                                  child: Row(children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit_outlined, size: 18),
                                      onPressed: () => _showDialog(context, w),
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
                                      onPressed: () => _toggleActive(w),
                                      tooltip: isActive ? 'Deactivate' : 'Activate',
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
