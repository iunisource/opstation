// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/product_picker.dart';

/// Bulk "store item ⇄ Opstation product" matching for a connected store.
/// Lists every product variant in the store with a suggested Opstation product
/// (same barcode / SKU first, then a close name), so the whole catalogue can be
/// matched in one go instead of order by order.
Future<void> showShopProductMatching(
  BuildContext context, {
  required Map<String, dynamic> store,
  required List<Map<String, dynamic>> products,
  required Future<Map<String, dynamic>> Function(Map<String, dynamic> body) call,
}) async {
  await showDialog(
    context: context,
    builder: (_) => _MatchDialog(store: store, products: products, call: call),
  );
}

class _Row {
  final Map<String, dynamic> v; // id, product, variant, sku, barcode, status
  String? savedPid; // already stored
  String? pid; // chosen now
  String how; // saved | barcode | sku | name | none | manual
  double score;
  _Row(this.v, {this.savedPid, this.pid, this.how = 'none', this.score = 0});
  String get title {
    final vt = '${v['variant'] ?? ''}'.trim();
    return vt.isEmpty || vt == 'Default Title' ? '${v['product']}' : '${v['product']} — $vt';
  }
  bool get changed => pid != null && pid != savedPid;
}

class _MatchDialog extends StatefulWidget {
  final Map<String, dynamic> store;
  final List<Map<String, dynamic>> products;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body) call;
  const _MatchDialog({required this.store, required this.products, required this.call});
  @override
  State<_MatchDialog> createState() => _MatchDialogState();
}

class _MatchDialogState extends State<_MatchDialog> {
  List<_Row> _rows = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String _filter = 'todo'; // todo | all | matched
  String _q = '';
  late final Map<String, Map<String, dynamic>> _byId = {for (final p in widget.products) p['id'] as String: p};

  @override
  void initState() {
    super.initState();
    _load();
  }

  static Set<String> _tokens(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .split(' ')
      .where((t) => t.length > 1 && !const {'the', 'and', 'for', 'with', 'default', 'title'}.contains(t))
      .toSet();

  Future<void> _load() async {
    try {
      final r = await widget.call({'action': 'list_variants', 'store_id': widget.store['id']});
      final variants = [for (final v in (r['variants'] as List? ?? const [])) Map<String, dynamic>.from(v as Map)];
      final maps = await Supabase.instance.client.from('shop_product_map')
          .select('ext_key, product_id').eq('store_id', widget.store['id']);
      final saved = {for (final m in maps as List) '${m['ext_key']}': '${m['product_id']}'};

      final byBarcode = <String, String>{}, bySku = <String, String>{};
      final nameTok = <String, Set<String>>{};
      for (final p in widget.products) {
        final id = p['id'] as String;
        final bc = '${p['barcode'] ?? ''}'.trim().toLowerCase();
        final sku = '${p['sku'] ?? ''}'.trim().toLowerCase();
        if (bc.isNotEmpty) byBarcode[bc] = id;
        if (sku.isNotEmpty) bySku[sku] = id;
        nameTok[id] = _tokens('${p['name'] ?? ''}');
      }
      final rows = <_Row>[];
      for (final v in variants) {
        final id = '${v['id']}';
        final sku = '${v['sku'] ?? ''}'.trim().toLowerCase();
        final bc = '${v['barcode'] ?? ''}'.trim().toLowerCase();
        final s0 = saved[id] ?? (sku.isNotEmpty ? saved['sku:$sku'] : null);
        if (s0 != null && _byId.containsKey(s0)) {
          rows.add(_Row(v, savedPid: s0, pid: s0, how: 'saved'));
          continue;
        }
        String? pid;
        var how = 'none';
        var score = 0.0;
        if (bc.isNotEmpty && byBarcode[bc] != null) { pid = byBarcode[bc]; how = 'barcode'; score = 1; }
        else if (sku.isNotEmpty && byBarcode[sku] != null) { pid = byBarcode[sku]; how = 'barcode'; score = 1; }
        else if (sku.isNotEmpty && bySku[sku] != null) { pid = bySku[sku]; how = 'sku'; score = 1; }
        else {
          final vt = _tokens('${v['product']} ${v['variant'] == 'Default Title' ? '' : v['variant']}');
          if (vt.isNotEmpty) {
            String? best;
            var bestScore = 0.0;
            nameTok.forEach((pidx, pt) {
              if (pt.isEmpty) return;
              final inter = vt.intersection(pt).length;
              final sc = inter / (vt.length > pt.length ? vt.length : pt.length);
              if (sc > bestScore) { bestScore = sc; best = pidx; }
            });
            if (best != null && bestScore >= 0.5) { pid = best; how = 'name'; score = bestScore; }
          }
        }
        rows.add(_Row(v, pid: pid, how: how, score: score));
      }
      rows.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      if (!mounted) return;
      setState(() { _rows = rows; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e'.contains('read_products') || '$e'.contains('ACCESS_DENIED')
            ? 'The store app needs the read_products permission to list products. Add it to the app\'s scopes in Shopify, release, then use "Approve again in Shopify" in Stores.'
            : '$e';
      });
    }
  }

  List<_Row> get _visible {
    final q = _q.trim().toLowerCase();
    return _rows.where((r) {
      final okF = switch (_filter) {
        'todo' => r.savedPid == null,
        'matched' => r.savedPid != null,
        _ => true,
      };
      if (!okF) return false;
      if (q.isEmpty) return true;
      return '${r.title} ${r.v['sku']} ${r.v['barcode']} ${_byId[r.pid]?['name'] ?? ''}'.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _save() async {
    final changed = _rows.where((r) => r.changed).toList();
    if (changed.isEmpty) { Navigator.of(context, rootNavigator: true).pop(); return; }
    setState(() => _saving = true);
    final client = Supabase.instance.client;
    try {
      final storeId = widget.store['id'];
      final orgId = widget.store['org_id'];
      for (var i = 0; i < changed.length; i += 200) {
        await client.from('shop_product_map').upsert([
          for (final r in changed.skip(i).take(200))
            {'org_id': orgId, 'store_id': storeId, 'ext_key': '${r.v['id']}', 'product_id': r.pid},
        ], onConflict: 'store_id,ext_key');
      }
      // Fill the match into open orders that still have those items unmatched.
      final byVariant = {for (final r in changed) '${r.v['id']}': r.pid};
      final open = await client.from('shop_orders').select('id, lines')
          .eq('store_id', storeId).inFilter('status', ['new', 'picking', 'packed']);
      for (final o in open as List) {
        final lines = [for (final l in (o['lines'] as List? ?? const [])) Map<String, dynamic>.from(l as Map)];
        var touched = false;
        for (final l in lines) {
          final pid = byVariant['${l['variant_id']}'];
          if (pid != null && l['product_id'] == null) { l['product_id'] = pid; touched = true; }
        }
        if (touched) await client.from('shop_orders').update({'lines': lines}).eq('id', o['id']);
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context, rootNavigator: true).pop();
      messenger.showSnackBar(SnackBar(behavior: SnackBarBehavior.floating,
          content: Text('${changed.length} item${changed.length == 1 ? '' : 's'} matched — used for every future order')));
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = 'Could not save: $e'; });
    }
  }

  Widget _howChip(_Row r) {
    final (String label, Color c) = switch (r.how) {
      'saved' => ('Matched', Colors.green),
      'barcode' => ('Same barcode', Colors.green),
      'sku' => ('Same SKU', Colors.green),
      'name' => ('Similar name ${(r.score * 100).round()}%', Colors.orange),
      'manual' => ('Chosen', Colors.blue),
      _ => ('Not matched', Colors.red),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
      child: Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: c.withOpacity(0.9))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    final pending = _rows.where((r) => r.changed).length;
    final todo = _rows.where((r) => r.savedPid == null).length;
    final suggestedName = _rows.where((r) => r.savedPid == null && r.how == 'name').length;
    return AlertDialog(
      title: Text('Match products · ${widget.store['name'] ?? ''}'),
      content: SizedBox(
        width: 820, height: 560,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _rows.isEmpty
                ? Center(child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.danger)))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${_rows.length} store items · $todo not saved yet. Same barcode / SKU are matched for you; '
                        'similar names are only suggestions — check them (orange). Click any Opstation product to change it.',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: TextField(
                        decoration: const InputDecoration(hintText: 'Search…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
                        onChanged: (v) => setState(() => _q = v),
                      )),
                      const SizedBox(width: 10),
                      for (final f in const [('todo', 'To match'), ('matched', 'Saved'), ('all', 'All')]) ...[
                        ChoiceChip(label: Text(f.$2), selected: _filter == f.$1, onSelected: (_) => setState(() => _filter = f.$1)),
                        const SizedBox(width: 6),
                      ],
                    ]),
                    if (suggestedName > 0)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          icon: const Icon(Icons.clear_all, size: 16),
                          label: Text('Clear all $suggestedName name suggestions (match those by hand)'),
                          onPressed: () => setState(() {
                            for (final r in _rows) {
                              if (r.savedPid == null && r.how == 'name') { r.pid = null; r.how = 'none'; }
                            }
                          }),
                        ),
                      ),
                    const Divider(height: 12),
                    Expanded(
                      child: rows.isEmpty
                          ? const Center(child: Text('Nothing here.', style: TextStyle(color: AppTheme.textSecondary)))
                          : ListView.separated(
                              itemCount: rows.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final r = rows[i];
                                final p = _byId[r.pid];
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                  child: Row(children: [
                                    Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(r.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                      Text([
                                        if ('${r.v['sku']}'.isNotEmpty) 'SKU ${r.v['sku']}',
                                        if ('${r.v['barcode']}'.isNotEmpty) 'Barcode ${r.v['barcode']}',
                                        if ('${r.v['status']}' != 'ACTIVE' && '${r.v['status']}'.isNotEmpty) '${r.v['status']}'.toLowerCase(),
                                      ].join(' · '), style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                    ])),
                                    const Icon(Icons.arrow_forward, size: 16, color: AppTheme.textSecondary),
                                    const SizedBox(width: 8),
                                    Expanded(flex: 5, child: InkWell(
                                      onTap: () async {
                                        final picked = await pickProduct(context, widget.products, title: 'Opstation product for: ${r.title}');
                                        if (picked == null || picked.isEmpty) return;
                                        setState(() { r.pid = picked['id'] as String; r.how = 'manual'; });
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                        decoration: BoxDecoration(
                                          border: Border.all(color: p == null ? Colors.red.withOpacity(0.4) : AppTheme.border),
                                          borderRadius: BorderRadius.circular(6)),
                                        child: Row(children: [
                                          Expanded(child: Text(p == null ? 'Choose product…' : '${p['name']}',
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(fontSize: 13, color: p == null ? AppTheme.textSecondary : null))),
                                          if (p != null && r.savedPid == null)
                                            InkWell(
                                              onTap: () => setState(() { r.pid = null; r.how = 'none'; }),
                                              child: const Icon(Icons.close, size: 14, color: AppTheme.textSecondary)),
                                        ]),
                                      ),
                                    )),
                                    const SizedBox(width: 8),
                                    SizedBox(width: 130, child: Align(alignment: Alignment.centerLeft, child: _howChip(r))),
                                  ]),
                                );
                              }),
                    ),
                    if (_error != null)
                      Padding(padding: const EdgeInsets.only(top: 6),
                          child: Text(_error!, style: const TextStyle(color: AppTheme.danger, fontSize: 12))),
                  ]),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('Close')),
        FilledButton.icon(
          icon: _saving
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save_outlined, size: 18),
          label: Text(pending == 0 ? 'Nothing to save' : 'Save $pending match${pending == 1 ? '' : 'es'}'),
          onPressed: _saving || pending == 0 ? null : _save,
        ),
      ],
    );
  }
}
