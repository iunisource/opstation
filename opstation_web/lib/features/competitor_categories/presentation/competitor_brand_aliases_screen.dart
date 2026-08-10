import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Admin-editable map of competitor brand (mis)spellings -> the correct name.
/// The Intelligence dashboard and main dashboard roll spottings up under the
/// canonical name; "Apply to existing spottings" also rewrites stored rows.
class CompetitorBrandAliasesScreen extends ConsumerStatefulWidget {
  const CompetitorBrandAliasesScreen({super.key});
  @override
  ConsumerState<CompetitorBrandAliasesScreen> createState() =>
      _CompetitorBrandAliasesScreenState();
}

class _CompetitorBrandAliasesScreenState
    extends ConsumerState<CompetitorBrandAliasesScreen> {
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loading = true;
  bool _applying = false;
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
          .from('competitor_brand_aliases')
          .select()
          .eq('org_id', orgId)
          .order('canonical')
          .order('alias');
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
        if (q.isEmpty) return true;
        return (c['alias'] as String? ?? '').toLowerCase().contains(q) ||
            (c['canonical'] as String? ?? '').toLowerCase().contains(q);
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

  Future<void> _delete(Map<String, dynamic> a) async {
    try {
      await Supabase.instance.client
          .from('competitor_brand_aliases')
          .delete()
          .eq('id', a['id']);
      _showSnack('Alias removed');
      _load();
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _applyToExisting() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apply to existing spottings?'),
        content: const Text(
            'This rewrites the brand name on already-recorded competitor '
            'spottings to the correct name, using the aliases below. It cannot '
            'be undone (but you can add a reverse alias to fix mistakes).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Apply')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _applying = true);
    try {
      final res = await Supabase.instance.client
          .rpc('apply_brand_aliases', params: {'p_org': orgId});
      final n = (res is int) ? res : int.tryParse('$res') ?? 0;
      _showSnack('Updated $n spotting${n == 1 ? '' : 's'} to the correct brand.');
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? alias) {
    final aliasCtrl = TextEditingController(text: alias?['alias'] ?? '');
    final canonCtrl = TextEditingController(text: alias?['canonical'] ?? '');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(alias == null ? 'Add brand alias' : 'Edit brand alias'),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: aliasCtrl,
              decoration: const InputDecoration(
                labelText: 'Misspelling / variant *',
                hintText: 'e.g. Excal, Semco, Brihtoo',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: canonCtrl,
              decoration: const InputDecoration(
                labelText: 'Correct brand *',
                hintText: 'e.g. Excel, Smeco, Brightoo',
              ),
            ),
            const SizedBox(height: 10),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  'Matching is case- and space-insensitive. New spottings roll '
                  'up automatically; use "Apply to existing" to fix old ones.',
                  style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
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
              final aliasTxt = aliasCtrl.text.trim();
              final canonTxt = canonCtrl.text.trim();
              if (aliasTxt.isEmpty || canonTxt.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Both the variant and the correct brand are required')));
                return;
              }
              final orgId = ref.read(currentUserProvider)?.orgId;
              final data = {
                'org_id': orgId,
                'alias': aliasTxt,
                'canonical': canonTxt,
              };
              try {
                if (alias == null) {
                  final id = 'cba_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client
                      .from('competitor_brand_aliases')
                      .insert({...data, 'id': id});
                } else {
                  await Supabase.instance.client
                      .from('competitor_brand_aliases')
                      .update(data)
                      .eq('id', alias['id']);
                }
                if (context.mounted) {
                  Navigator.of(context, rootNavigator: true).pop();
                }
                _showSnack(alias == null ? 'Alias added' : 'Alias updated');
                _load();
              } catch (e) {
                _showSnack('Failed: ${e.toString().split('\n').first}');
              }
            },
            child: Text(alias == null ? 'Add' : 'Save'),
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
            const Text('Competitor Brand Aliases',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            if (canEdit) ...[
              OutlinedButton.icon(
                onPressed: _applying ? null : _applyToExisting,
                icon: _applying
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cleaning_services_outlined, size: 18),
                label: const Text('Apply to existing'),
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                onPressed: () => _showDialog(context, null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add alias'),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          Text('${_filtered.length} aliases',
              style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          const Text(
            'Map the (mis)spellings surveyors type to the correct competitor '
            'brand. Spottings roll up under the correct name on the dashboards. '
            'New entries apply automatically; "Apply to existing" also rewrites '
            'already-recorded spottings.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search aliases...',
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
                      Expanded(
                          child: Text('Misspelling / variant',
                              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 30),
                      Expanded(
                          child: Text('Correct brand',
                              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 100),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _filtered.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(28),
                              child: Text('No aliases yet. Add one to roll up typos.',
                                  style: TextStyle(color: AppTheme.textSecondary)),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _filtered.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final a = _filtered[i];
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                child: Row(children: [
                                  Expanded(
                                      child: Text(a['alias'] as String? ?? '',
                                          style: const TextStyle(fontSize: 13.5))),
                                  const SizedBox(
                                      width: 30,
                                      child: Icon(Icons.arrow_forward, size: 15, color: AppTheme.textSecondary)),
                                  Expanded(
                                      child: Text(a['canonical'] as String? ?? '',
                                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700))),
                                  SizedBox(
                                    width: 100,
                                    child: canEdit
                                        ? Row(children: [
                                            IconButton(
                                                icon: const Icon(Icons.edit_outlined, size: 18),
                                                onPressed: () => _showDialog(context, a)),
                                            IconButton(
                                                icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                                                tooltip: 'Remove',
                                                onPressed: () => _delete(a)),
                                          ])
                                        : null,
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
      ),
    );
  }
}
