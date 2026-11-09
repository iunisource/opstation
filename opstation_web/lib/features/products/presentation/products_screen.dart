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
  // Auto Pilot links: Intelligence product id -> linked system products.
  Map<String, List<Map<String, dynamic>>> _links = {};
  List<Map<String, dynamic>> _sysProducts = []; // id, name, sku
  Map<String, Map<String, dynamic>> _sysById = {};

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
          .from('intelligence_products')
          .select()
          .eq('org_id', orgId)
          .order('position')
          .order('name');
      setState(() {
        _products = List<Map<String, dynamic>>.from(rows);
        _filtered = _products;
        _loading = false;
      });
      _loadLinks();
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadLinks() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final client = Supabase.instance.client;
    try {
      if (_sysProducts.isEmpty) {
        final all = <Map<String, dynamic>>[];
        for (var from = 0; from < 200000; from += 1000) {
          final page = await client.from('products').select('id, name, sku')
              .eq('org_id', orgId).eq('is_active', true).order('id').range(from, from + 999);
          final list = List<Map<String, dynamic>>.from(page as List);
          all.addAll(list);
          if (list.length < 1000) break;
        }
        all.sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
        _sysProducts = all;
        _sysById = {for (final p in all) p['id'] as String: p};
      }
      final rows = await client.from('intelligence_product_links')
          .select('id, intel_product_id, product_id').eq('org_id', orgId);
      final map = <String, List<Map<String, dynamic>>>{};
      for (final r in rows as List) {
        map.putIfAbsent('${r['intel_product_id']}', () => []).add(Map<String, dynamic>.from(r as Map));
      }
      if (mounted) setState(() => _links = map);
    } catch (_) {
      // Links table not set up yet (SQL 456) — the screen works as before.
    }
  }

  String _sysLabel(String pid) {
    final p = _sysById[pid];
    if (p == null) return '(removed product)';
    final sku = '${p['sku'] ?? ''}'.trim();
    return sku.isEmpty ? '${p['name']}' : '${p['name']} [$sku]';
  }

  static Set<String> _tokens(String s) =>
      s.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((t) => t.isNotEmpty).toSet();

  /// How well a system product matches an Intelligence product (0..1).
  double _match(Map<String, dynamic> ip, Map<String, dynamic> sp) {
    final code = '${ip['sku_code'] ?? ''}'.trim().toLowerCase();
    if (code.isNotEmpty && code == '${sp['sku'] ?? ''}'.trim().toLowerCase()) return 1.0;
    final a = _tokens('${ip['name'] ?? ''}');
    if (a.isEmpty) return 0;
    final b = _tokens('${sp['name'] ?? ''}');
    return a.intersection(b).length / a.length;
  }

  Future<void> _saveLinks(Map<String, dynamic> ip, Set<String> chosen) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final ipId = ip['id'] as String;
    final current = {for (final l in _links[ipId] ?? const <Map<String, dynamic>>[]) l['product_id'] as String: l['id'] as String};
    final add = chosen.difference(current.keys.toSet());
    final remove = [for (final e in current.entries) if (!chosen.contains(e.key)) e.value];
    final client = Supabase.instance.client;
    try {
      if (remove.isNotEmpty) await client.from('intelligence_product_links').delete().inFilter('id', remove);
      if (add.isNotEmpty) {
        await client.from('intelligence_product_links').insert([
          for (final pid in add)
            {'org_id': orgId, 'intel_product_id': ipId, 'product_id': pid, 'created_by': ref.read(currentUserProvider)?.id},
        ]);
      }
      _showSnack(chosen.isEmpty ? 'Links removed' : 'Linked ${chosen.length} system product${chosen.length == 1 ? '' : 's'}');
      await _loadLinks();
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
    }
  }

  void _linkDialog(Map<String, dynamic> ip) {
    final chosen = {for (final l in _links[ip['id']] ?? const <Map<String, dynamic>>[]) l['product_id'] as String};
    var q = '';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final qq = q.trim().toLowerCase();
        // Ticked ones first, then the best matches for this item / the search.
        final scored = [
          for (final sp in _sysProducts)
            if (chosen.contains(sp['id']) ||
                (qq.isEmpty ? _match(ip, sp) >= 0.5 : '${sp['name']} ${sp['sku'] ?? ''}'.toLowerCase().contains(qq)))
              sp
        ]..sort((a, b) {
            final ca = chosen.contains(a['id']) ? 1 : 0, cb = chosen.contains(b['id']) ? 1 : 0;
            if (ca != cb) return cb - ca;
            return _match(ip, b).compareTo(_match(ip, a));
          });
        final shown = scored.take(60).toList();
        return AlertDialog(
          title: Text('Link “${ip['name']}”'),
          content: SizedBox(
            width: 520,
            height: 460,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Pick the system products that count as this item. A sale of any of them marks it as placed (Auto Pilot).',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
              const SizedBox(height: 10),
              TextField(
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search system products by name or SKU', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
                onChanged: (v) => setD(() => q = v),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: shown.isEmpty
                    ? const Center(child: Text('No matching products — try searching.', style: TextStyle(color: AppTheme.textSecondary)))
                    : ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final sp = shown[i];
                          final id = sp['id'] as String;
                          final best = i == 0 && qq.isEmpty && !chosen.contains(id) && _match(ip, sp) >= 0.75;
                          return CheckboxListTile(
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: chosen.contains(id),
                            onChanged: (v) => setD(() => v == true ? chosen.add(id) : chosen.remove(id)),
                            title: Text(_sysLabel(id), style: const TextStyle(fontSize: 13)),
                            secondary: best
                                ? Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
                                    child: const Text('Best match', style: TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w600)))
                                : null,
                          );
                        },
                      ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                Navigator.of(ctx, rootNavigator: true).pop();
                _saveLinks(ip, chosen);
              },
              child: Text(chosen.isEmpty ? 'Save (no links)' : 'Link ${chosen.length} product${chosen.length == 1 ? '' : 's'}'),
            ),
          ],
        );
      }),
    );
  }

  /// Proposes the best system product for every unlinked item; the admin
  /// ticks which to keep.
  Future<void> _suggestLinks() async {
    if (_sysProducts.isEmpty) await _loadLinks();
    final proposals = <(Map<String, dynamic>, Map<String, dynamic>, double)>[];
    for (final ip in _products) {
      if ((_links[ip['id']] ?? const []).isNotEmpty) continue;
      Map<String, dynamic>? best;
      var bestScore = 0.0;
      for (final sp in _sysProducts) {
        final m = _match(ip, sp);
        if (m > bestScore) { bestScore = m; best = sp; }
      }
      if (best != null && bestScore >= 0.6) proposals.add((ip, best, bestScore));
    }
    if (!mounted) return;
    if (proposals.isEmpty) { _showSnack('No confident matches found — link these by hand.'); return; }
    final keep = {for (var i = 0; i < proposals.length; i++) i};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Text('Suggested links (${proposals.length})'),
        content: SizedBox(
          width: 620,
          height: 420,
          child: ListView.builder(
            itemCount: proposals.length,
            itemBuilder: (_, i) {
              final (ip, sp, sc) = proposals[i];
              return CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: keep.contains(i),
                onChanged: (v) => setD(() => v == true ? keep.add(i) : keep.remove(i)),
                title: Text('${ip['name']}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: Text('→ ${_sysLabel(sp['id'] as String)}  ·  ${(sc * 100).round()}% match', style: const TextStyle(fontSize: 12)),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true), child: Text('Link ${keep.length}')),
        ],
      )),
    );
    if (ok != true || keep.isEmpty) return;
    final orgId = ref.read(currentUserProvider)?.orgId;
    try {
      await Supabase.instance.client.from('intelligence_product_links').insert([
        for (final i in keep)
          {'org_id': orgId, 'intel_product_id': proposals[i].$1['id'], 'product_id': proposals[i].$2['id'], 'created_by': ref.read(currentUserProvider)?.id},
      ]);
      _showSnack('Linked ${keep.length} item${keep.length == 1 ? '' : 's'}');
      await _loadLinks();
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
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
      await Supabase.instance.client.from('intelligence_products').update({
        'is_active': newVal,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
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
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              };
              final isNew = product == null;
              try {
                if (isNew) {
                  final id = 'prod_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client.from('intelligence_products').insert({...data, 'id': id});
                } else {
                  await Supabase.instance.client.from('intelligence_products').update(data).eq('id', product['id']);
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
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 16 : 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Products', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            if (canEdit && _products.isNotEmpty) ...[
              OutlinedButton.icon(
                onPressed: _suggestLinks,
                icon: const Icon(Icons.auto_fix_high, size: 16),
                label: const Text('Suggest links'),
              ),
              const SizedBox(width: 8),
            ],
            if (canEdit)
              ElevatedButton.icon(
                onPressed: () => _showDialog(context, null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Product'),
              ),
          ]),
          const SizedBox(height: 8),
          Text(
            (() {
              final linked = _products.where((p) => (_links[p['id']] ?? const []).isNotEmpty).length;
              return '${_filtered.length} products · $linked linked to system products · ${_products.length - linked} not linked';
            })(),
            style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          const Text(
            'Your own SKU catalog. Surveyors will tick which of these are physically displayed at each shop during Placement Audit. '
            'Link each one to its system products so Auto Pilot can count sales.',
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
                      Expanded(flex: 5, child: Text('Linked system products', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 80, child: Text('Position', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 80, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 160),
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
                            Expanded(flex: 5, child: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: (() {
                                final ls = _links[p['id']] ?? const <Map<String, dynamic>>[];
                                if (ls.isEmpty) {
                                  return const Align(alignment: Alignment.centerLeft, child: Text('⚠ Not linked — sales can\'t count',
                                      style: TextStyle(fontSize: 12, color: Color(0xFFB45309), fontWeight: FontWeight.w600)));
                                }
                                return Wrap(spacing: 6, runSpacing: 4, children: [
                                  for (final l in ls)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(10)),
                                      child: Text('✓ ${_sysLabel(l['product_id'] as String)}',
                                          style: const TextStyle(fontSize: 11.5, color: Color(0xFF047857), fontWeight: FontWeight.w600)),
                                    ),
                                ]);
                              })(),
                            )),
                            SizedBox(width: 80, child: Text((p['position'] ?? 0).toString(), style: const TextStyle(fontSize: 13))),
                            SizedBox(width: 80, child: Text(
                              isActive ? 'Active' : 'Inactive',
                              style: TextStyle(fontSize: 13, color: isActive ? AppTheme.success : AppTheme.textSecondary, fontWeight: FontWeight.w600),
                            )),
                            SizedBox(width: 160, child: canEdit ? Row(children: [
                              IconButton(
                                icon: Icon(Icons.link, size: 18,
                                    color: (_links[p['id']] ?? const []).isEmpty ? AppTheme.primary : AppTheme.textSecondary),
                                tooltip: 'Link to system products',
                                onPressed: () => _linkDialog(p),
                              ),
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
