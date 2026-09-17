import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';
import '../../../core/utils/friendly_error.dart';

class ErpBranchesScreen extends ConsumerStatefulWidget {
  const ErpBranchesScreen({super.key});
  @override
  ConsumerState<ErpBranchesScreen> createState() => _ErpBranchesScreenState();
}

class _ErpBranchesScreenState extends ConsumerState<ErpBranchesScreen> {
  List<Map<String, dynamic>> _branches = [];
  List<Map<String, dynamic>> _suppliers = []; // for the processor supplier picker
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
      final client = Supabase.instance.client;
      final res = await client
          .from('branches')
          .select()
          .eq('org_id', orgId)
          .order('name');
      // Suppliers power the "fee payable to" picker on processor locations.
      List<Map<String, dynamic>> sup = [];
      try {
        final s = await client.from('suppliers')
            .select('id, name').eq('org_id', orgId).order('name');
        sup = List<Map<String, dynamic>>.from(s);
      } catch (_) { /* suppliers optional */ }
      setState(() {
        _branches = List<Map<String, dynamic>>.from(res);
        _suppliers = sup;
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

  // Searchable supplier picker for the processor "fee billed to" field.
  // Returns the chosen supplier id, '' for "none", or null if cancelled.
  Future<String?> _pickSupplier(BuildContext context, String? current) {
    String q = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final ql = q.toLowerCase().trim();
        final list = _suppliers
            .where((s) => ql.isEmpty || (s['name'] as String? ?? '').toLowerCase().contains(ql))
            .toList();
        return AlertDialog(
          title: const Text('Select supplier', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 420,
            height: 480,
            child: Column(children: [
              TextField(
                autofocus: true,
                decoration: const InputDecoration(
                    hintText: 'Search supplier…', prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true, border: OutlineInputBorder()),
                onChanged: (v) => setLocal(() => q = v),
              ),
              const SizedBox(height: 8),
              Expanded(child: ListView(children: [
                ListTile(
                  dense: true,
                  title: const Text('— none —'),
                  selected: current == null,
                  onTap: () => Navigator.pop(ctx, ''),
                ),
                for (final s in list)
                  ListTile(
                    dense: true,
                    title: Text(s['name'] as String? ?? ''),
                    selected: s['id'] == current,
                    onTap: () => Navigator.pop(ctx, s['id'] as String),
                  ),
                if (list.isEmpty) const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No matches', style: TextStyle(color: AppTheme.textSecondary)),
                ),
              ])),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
        );
      }),
    );
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
    bool isVirtual = branch?['is_virtual'] as bool? ?? false;
    String? supplierId = branch?['supplier_id'] as String?;
    // Processor / off-site locations are a Manufacturing-module feature. Without
    // that module the option is hidden (existing processor branches still work).
    final mfgOn =
        ref.read(orgModulesProvider).valueOrNull?.contains('production') ?? false;
    final showProcessor = mfgOn || isVirtual;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(builder: (context, setLocal) => AlertDialog(
        title: Text(branch == null ? 'Add Location' : 'Edit Location'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Location Name *')),
            const SizedBox(height: 12),
            TextField(
                controller: locationCtrl,
                decoration: const InputDecoration(labelText: 'Location / Address'),
                maxLines: 2),
            // A processor / off-site location holds stock we send out for
            // processing. It carries its own stock + cost ledger like any
            // branch, but is kept out of POS / sales / dispatch pickers and
            // shown separately as "Stock with Processors" in reports.
            if (showProcessor) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                value: isVirtual,
                onChanged: (v) => setLocal(() => isVirtual = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Processor / off-site location',
                    style: TextStyle(fontSize: 14)),
                subtitle: const Text(
                    'Stock sent here (e.g. for coating/processing) is tracked but not sold or dispatched from. Shows as "Stock with Processors".',
                    style: TextStyle(fontSize: 11)),
              ),
              // The supplier a processor's conversion fee is billed to — used to
              // pre-fill the payable party on a Job-work receipt. Only relevant
              // once this location is marked a processor.
              if (isVirtual) ...[
                const SizedBox(height: 8),
                Builder(builder: (fieldCtx) {
                  final sel = _suppliers.firstWhere((s) => s['id'] == supplierId, orElse: () => const {});
                  final selName = sel['name'] as String?;
                  return InkWell(
                    onTap: () async {
                      final picked = await _pickSupplier(fieldCtx, supplierId);
                      if (picked != null) setLocal(() => supplierId = picked.isEmpty ? null : picked);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                          labelText: 'Processor supplier (fee billed to)',
                          isDense: true, border: OutlineInputBorder(),
                          helperText: 'Pre-fills the payable on Job-work receipts',
                          helperMaxLines: 2),
                      child: Row(children: [
                        Expanded(child: Text(selName ?? 'Select supplier (optional)',
                            style: TextStyle(fontSize: 14, color: selName == null ? AppTheme.textSecondary : null))),
                        const Icon(Icons.arrow_drop_down, color: AppTheme.textSecondary),
                      ]),
                    ),
                  );
                }),
              ],
            ],
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
                'is_virtual': isVirtual,
                // Supplier link only applies to a processor location.
                'supplier_id': isVirtual ? supplierId : null,
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
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 16 : 32),
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
                                    child: Row(children: [
                                      Flexible(
                                          child: Text(w['name'] as String? ?? '',
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w600))),
                                      if (w['is_virtual'] as bool? ?? false) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 1),
                                            decoration: BoxDecoration(
                                                color: Colors.purple.withOpacity(0.12),
                                                borderRadius: BorderRadius.circular(4)),
                                            child: const Text('Processor',
                                                style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w700,
                                                    color: Colors.purple))),
                                      ],
                                    ])),
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
