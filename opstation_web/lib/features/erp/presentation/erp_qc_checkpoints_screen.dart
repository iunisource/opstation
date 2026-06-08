import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class ErpQcCheckpointsScreen extends ConsumerStatefulWidget {
  const ErpQcCheckpointsScreen({super.key});
  @override
  ConsumerState<ErpQcCheckpointsScreen> createState() => _State();
}

class _State extends ConsumerState<ErpQcCheckpointsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  Map<String, String> _prodLabel = {};
  Map<String, String> _bomLabel = {};
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _boms = [];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) => _load()); }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 400)); if (mounted) _load(); return; }
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final prods = await client.from('products').select('id, name, sku').eq('org_id', orgId).eq('is_active', true).order('name').limit(5000);
      final boms = await client.from('bom_headers').select('id, code, name, product_id').eq('org_id', orgId).order('code').limit(2000);
      final rows = await client.from('qc_checkpoints').select().eq('org_id', orgId).order('sequence').order('name');
      _products = List<Map<String, dynamic>>.from(prods);
      _boms = List<Map<String, dynamic>>.from(boms);
      _prodLabel = {for (final p in _products) p['id'] as String: "${p['sku'] != null && (p['sku'] as String).isNotEmpty ? '${p['sku']} — ' : ''}${p['name'] ?? ''}"};
      _bomLabel = {for (final b in _boms) b['id'] as String: "${b['code'] ?? ''} — ${_prodLabel[b['product_id']] ?? (b['name'] ?? '')}"};
      if (mounted) setState(() { _rows = List<Map<String, dynamic>>.from(rows); _loading = false; });
    } catch (e) { if (mounted) { _snack('Load failed: $e'); setState(() => _loading = false); } }
  }

  String _scopeLabel(Map<String, dynamic> r) {
    final s = r['scope'] as String? ?? 'global';
    if (s == 'product') return 'Product: ${_prodLabel[r['scope_ref']] ?? r['scope_ref'] ?? '?'}';
    if (s == 'bom') return 'BOM: ${_bomLabel[r['scope_ref']] ?? r['scope_ref'] ?? '?'}';
    return 'All products (global)';
  }

  Future<void> _delete(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete checkpoint?'),
      content: Text('Delete QC checkpoint "${r['name']}"? Existing recorded results are kept.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try { await Supabase.instance.client.from('qc_checkpoints').delete().eq('id', r['id'] as String); _snack('Deleted'); await _load(); }
    catch (e) { _snack('Delete failed: $e'); }
  }

  void _showDialog([Map<String, dynamic>? existing]) {
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?['name'] as String? ?? '');
    final seqCtrl = TextEditingController(text: (existing?['sequence'] ?? 0).toString());
    final notesCtrl = TextEditingController(text: existing?['notes'] as String? ?? '');
    String scope = existing?['scope'] as String? ?? 'global';
    String? scopeRef = existing?['scope_ref'] as String?;
    bool gating = (existing?['is_gating'] as bool?) ?? true;
    bool active = (existing?['is_active'] as bool?) ?? true;
    bool saving = false;

    showDialog(context: context, builder: (_) => StatefulBuilder(builder: (dCtx, setS) => AlertDialog(
      title: Text(isEdit ? 'Edit Checkpoint' : 'New QC Checkpoint'),
      content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Checkpoint name *', hintText: 'e.g. Final inspection')),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: scope, decoration: const InputDecoration(labelText: 'Applies to'),
          items: const [
            DropdownMenuItem(value: 'global', child: Text('All products (global)')),
            DropdownMenuItem(value: 'product', child: Text('A specific product')),
            DropdownMenuItem(value: 'bom', child: Text('A specific BOM')),
          ],
          onChanged: (v) => setS(() { scope = v ?? 'global'; scopeRef = null; }),
        ),
        if (scope == 'product') ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: scopeRef, isExpanded: true, decoration: const InputDecoration(labelText: 'Product *'),
            items: _products.map((p) => DropdownMenuItem(value: p['id'] as String, child: Text(_prodLabel[p['id']] ?? '-', overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (v) => setS(() => scopeRef = v),
          ),
        ],
        if (scope == 'bom') ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: scopeRef, isExpanded: true, decoration: const InputDecoration(labelText: 'BOM *'),
            items: _boms.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(_bomLabel[b['id']] ?? '-', overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (v) => setS(() => scopeRef = v),
          ),
        ],
        const SizedBox(height: 12),
        TextField(controller: seqCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Sequence', hintText: 'Order shown during QC')),
        const SizedBox(height: 8),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: gating, onChanged: (v) => setS(() => gating = v),
          title: const Text('Gating', style: TextStyle(fontSize: 14)),
          subtitle: const Text('Must pass before a batch can be posted', style: TextStyle(fontSize: 11))),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: active, onChanged: (v) => setS(() => active = v),
          title: const Text('Active', style: TextStyle(fontSize: 14))),
        const SizedBox(height: 8),
        TextField(controller: notesCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
      ]))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Cancel')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
          onPressed: saving ? null : () async {
            if (nameCtrl.text.trim().isEmpty) { ScaffoldMessenger.of(dCtx).showSnackBar(const SnackBar(content: Text('Name is required'))); return; }
            if (scope != 'global' && (scopeRef == null || scopeRef!.isEmpty)) { ScaffoldMessenger.of(dCtx).showSnackBar(const SnackBar(content: Text('Pick the product or BOM'))); return; }
            setS(() => saving = true);
            try {
              final client = Supabase.instance.client;
              final data = {
                'org_id': _orgId, 'name': nameCtrl.text.trim(), 'scope': scope,
                'scope_ref': scope == 'global' ? null : scopeRef,
                'sequence': int.tryParse(seqCtrl.text.trim()) ?? 0,
                'is_gating': gating, 'is_active': active, 'notes': notesCtrl.text.trim(),
              };
              if (isEdit) {
                await client.from('qc_checkpoints').update(data).eq('id', existing['id'] as String);
              } else {
                data['id'] = 'qcp_${DateTime.now().millisecondsSinceEpoch}';
                await client.from('qc_checkpoints').insert(data);
              }
              if (dCtx.mounted) Navigator.pop(dCtx);
              _snack('Saved');
              await _load();
            } catch (e) { setS(() => saving = false); if (dCtx.mounted) ScaffoldMessenger.of(dCtx).showSnackBar(SnackBar(content: Text('Save failed: $e'))); }
          },
          child: saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(isEdit ? 'Save' : 'Create'),
        ),
      ],
    )));
  }

  @override
  Widget build(BuildContext context) {
    return Container(color: AppTheme.background, padding: const EdgeInsets.all(28), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('QC Checkpoints', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        const Spacer(),
        ElevatedButton.icon(onPressed: () => _showDialog(), icon: const Icon(Icons.add, size: 18), label: const Text('New Checkpoint'),
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary)),
      ]),
      const SizedBox(height: 4),
      const Text('Inspection points that gate a job batch from posting. Scope each to all products, a product, or a BOM.', style: TextStyle(color: AppTheme.textSecondary)),
      const SizedBox(height: 18),
      Expanded(child: _loading ? const Center(child: CircularProgressIndicator())
        : _rows.isEmpty ? const Center(child: Text('No checkpoints yet. Add one to start gating production QC.', style: TextStyle(color: AppTheme.textSecondary)))
        : Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
            child: ListView.separated(
              itemCount: _rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = _rows[i];
                final gating = (r['is_gating'] as bool?) ?? true;
                final active = (r['is_active'] as bool?) ?? true;
                return ListTile(
                  title: Row(children: [
                    Text(r['name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                    const SizedBox(width: 10),
                    _chip(gating ? 'Gating' : 'Advisory', gating ? Colors.deepOrange : Colors.blueGrey),
                    const SizedBox(width: 6),
                    if (!active) _chip('Inactive', Colors.grey),
                  ]),
                  subtitle: Text('${_scopeLabel(r)}  ·  seq ${r['sequence'] ?? 0}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _showDialog(r)),
                    IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red), onPressed: () => _delete(r)),
                  ]),
                );
              },
            ),
          )),
    ]));
  }

  Widget _chip(String label, Color c) => Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
    child: Text(label, style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.w700)));
}
