// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/product_picker.dart';

/// Bulk "store item ⇄ Opstation product" matching for a connected store.
/// Suggestions come from the item codes (ALO 202, ALA 301 (S) …) in the store
/// SKU and the Opstation product name, looking only at finished products
/// (the main groups chosen at the top). A store item with several codes is a
/// bundle of several products.
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

class _Part {
  String? code; // item code from the store SKU, e.g. "ALA 301 (S)"
  double qty;
  String? pid;
  List<String> choices;
  _Part({this.code, this.qty = 1, this.pid, this.choices = const []});
  _Part copy() => _Part(code: code, qty: qty, pid: pid, choices: choices);
}

class _Row {
  final Map<String, dynamic> v; // id, product, variant, sku, barcode, status
  final List<_Part>? saved; // what is stored now
  final String autoHow; // barcode | sku | code | bundle | unsure | none
  final List<_Part> auto;
  List<_Part> parts; // what will be saved
  bool manual = false;
  _Row(this.v, this.saved, this.autoHow, this.auto, this.parts);

  String get title {
    final vt = '${v['variant'] ?? ''}'.trim();
    return vt.isEmpty || vt == 'Default Title' ? '${v['product']}' : '${v['product']} — $vt';
  }

  static String sig(List<_Part>? ps) {
    if (ps == null || ps.isEmpty) return '';
    final l = [for (final p in ps) '${p.pid}*${p.qty}']..sort();
    return l.join('|');
  }

  bool get complete => parts.isNotEmpty && parts.every((p) => p.pid != null);
  bool get autoComplete => auto.isNotEmpty && auto.every((p) => p.pid != null);
  bool get changed => (complete || (parts.isEmpty && saved != null)) && sig(parts) != sig(saved);
  bool get isBundle => parts.length > 1 || (parts.length == 1 && parts.first.qty > 1);
  /// Saved, but the item codes point to something else.
  bool get disagrees => saved != null && autoComplete && sig(saved) != sig(auto);
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
  String _filter = 'todo'; // todo | check | matched | all
  String _q = '';
  List<String> _groups = []; // main groups matched against
  Map<String, int> _allGroups = {};
  late final Map<String, Map<String, dynamic>> _byId = {for (final p in widget.products) p['id'] as String: p};

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _grp(Map<String, dynamic>? p) {
    final g = '${p?['product_main_group'] ?? ''}'.trim();
    return g.isEmpty ? '(none)' : g;
  }

  List<Map<String, dynamic>> get _finished =>
      widget.products.where((p) => _groups.contains(_grp(p))).toList();

  static List<_Part> _parts(dynamic list, {bool auto = false}) => [
        for (final x in (list as List? ?? const []))
          _Part(
            code: auto ? (x as Map)['code'] as String? : null,
            qty: ((x as Map)['qty'] as num?)?.toDouble() ?? 1,
            pid: x['product_id'] as String?,
            choices: auto ? [for (final c in (x['choices'] as List? ?? const [])) '$c'] : const [],
          ),
      ];

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final r = await widget.call({'action': 'list_variants', 'store_id': widget.store['id']});
      _groups = [for (final g in (r['groups'] as List? ?? const [])) '$g'];
      _allGroups = {
        for (final e in ((r['all_groups'] as Map?) ?? const {}).entries) '${e.key}': (e.value as num).toInt(),
      };
      final rows = <_Row>[];
      for (final x in (r['variants'] as List? ?? const [])) {
        final v = Map<String, dynamic>.from(x as Map);
        final saved = v['saved'] == null ? null : _parts(v['saved']);
        final a = Map<String, dynamic>.from((v['auto'] as Map?) ?? const {});
        final auto = _parts(a['parts'], auto: true);
        final start = saved != null
            ? [for (final p in saved) p.copy()]
            : [for (final p in auto) p.copy()];
        rows.add(_Row(v, saved, '${a['how'] ?? 'none'}', auto, start));
      }
      rows.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      if (!mounted) return;
      setState(() { _rows = rows; _loading = false; });
    } catch (e) {
      // Show what this connection is actually allowed to do.
      String granted = '';
      try {
        final g = await widget.call({'action': 'granted_scopes', 'store_id': widget.store['id']});
        granted = (g['scopes'] as List? ?? const []).join(', ');
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _loading = false;
        final denied = '$e'.contains('read_products') || '$e'.contains('ACCESS_DENIED');
        _error = denied
            ? 'Shopify says this connection is not allowed to read products yet.\n\n'
              'Approved for this store right now: ${granted.isEmpty ? '(could not check)' : granted}\n\n'
              'Adding a permission in the Dev Dashboard is not enough on its own — the store has to approve it: '
              'release the version, then Stores → ⋮ → "Approve again in Shopify" and approve.'
            : '$e';
      });
    }
  }

  Future<void> _setGroups(List<String> g) async {
    if (g.isEmpty) return;
    try {
      await Supabase.instance.client.from('shop_stores').update({'match_groups': g}).eq('id', widget.store['id']);
      widget.store['match_groups'] = g;
      await _load();
    } catch (e) {
      setState(() => _error = 'Could not save: $e');
    }
  }

  List<_Row> get _visible {
    final q = _q.trim().toLowerCase();
    return _rows.where((r) {
      final okF = switch (_filter) {
        'todo' => r.saved == null,
        'check' => r.disagrees,
        'matched' => r.saved != null,
        _ => true,
      };
      if (!okF) return false;
      if (q.isEmpty) return true;
      final names = r.parts.map((p) => _byId[p.pid]?['name'] ?? '').join(' ');
      return '${r.title} ${r.v['sku']} ${r.v['barcode']} $names'.toLowerCase().contains(q);
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
      final put = changed.where((r) => r.parts.isNotEmpty).toList();
      final drop = changed.where((r) => r.parts.isEmpty).map((r) => '${r.v['id']}').toList();
      for (var i = 0; i < put.length; i += 200) {
        await client.from('shop_product_map').upsert([
          for (final r in put.skip(i).take(200))
            {
              'org_id': orgId, 'store_id': storeId, 'ext_key': '${r.v['id']}',
              'product_id': r.isBundle ? null : r.parts.first.pid,
              'components': r.isBundle
                  ? [for (final p in r.parts) {'product_id': p.pid, 'qty': p.qty}]
                  : null,
            },
        ], onConflict: 'store_id,ext_key');
      }
      for (var i = 0; i < drop.length; i += 200) {
        await client.from('shop_product_map').delete().eq('store_id', storeId).inFilter('ext_key', drop.skip(i).take(200).toList());
      }
      // Apply to open orders that aren't being picked yet.
      var orders = 0;
      try {
        final r = await widget.call({'action': 'rematch', 'store_id': storeId});
        orders = (r['orders'] as num?)?.toInt() ?? 0;
      } catch (_) {}
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context, rootNavigator: true).pop();
      messenger.showSnackBar(SnackBar(behavior: SnackBarBehavior.floating,
          content: Text('${put.length} item${put.length == 1 ? '' : 's'} matched — used for every future order'
              '${orders > 0 ? ' · $orders open order${orders == 1 ? '' : 's'} updated' : ''}')));
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = 'Could not save: $e'; });
    }
  }

  Future<void> _choose(_Row r, _Part part) async {
    String? pick;
    if (part.choices.length > 1) {
      pick = await showDialog<String>(context: context, builder: (d) => SimpleDialog(
        title: Text('Which one is ${part.code ?? 'it'}?', style: const TextStyle(fontSize: 16)),
        children: [
          for (final id in part.choices)
            SimpleDialogOption(
              onPressed: () => Navigator.of(d, rootNavigator: true).pop(id),
              child: Text('${_byId[id]?['name'] ?? id}', style: const TextStyle(fontSize: 13.5)),
            ),
          const Divider(),
          SimpleDialogOption(
            onPressed: () => Navigator.of(d, rootNavigator: true).pop('__search'),
            child: const Text('Search other products…', style: TextStyle(color: AppTheme.primary)),
          ),
        ],
      ));
      if (pick == null) return;
    }
    if (pick == null || pick == '__search') {
      if (!mounted) return;
      final list = _finished.isEmpty ? widget.products : _finished;
      final p = await pickProduct(context, list, title: '${part.code ?? 'Product'} for: ${r.title}');
      if (p == null || p.isEmpty) return;
      pick = p['id'] as String;
    }
    setState(() { part.pid = pick; r.manual = true; });
  }

  Widget _howChip(_Row r) {
    final (String label, Color c) = r.manual
        ? ('Chosen', Colors.blue)
        : r.saved != null
            ? (r.disagrees ? ('Saved · code differs', Colors.deepOrange) : ('Matched', Colors.green))
            : switch (r.autoHow) {
                'barcode' => ('Same barcode', Colors.green),
                'sku' => ('Same SKU', Colors.green),
                'code' => ('Same code', Colors.green),
                'bundle' => ('Bundle by codes', Colors.green),
                'unsure' => ('Pick one', Colors.orange),
                _ => ('Not matched', Colors.red),
              };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
      child: Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: c.withOpacity(0.9))),
    );
  }

  Widget _partBox(_Row r, _Part part) {
    final p = _byId[part.pid];
    final notFinished = p != null && !_groups.contains(_grp(p));
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        if (r.parts.length > 1 || part.qty > 1)
          SizedBox(width: 34, child: InkWell(
            onTap: () async {
              final c = TextEditingController(text: part.qty % 1 == 0 ? '${part.qty.toInt()}' : '${part.qty}');
              final v = await showDialog<double>(context: context, builder: (d) => AlertDialog(
                title: const Text('How many in this item?'),
                content: TextField(controller: c, autofocus: true, keyboardType: TextInputType.number),
                actions: [FilledButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(double.tryParse(c.text.trim())), child: const Text('OK'))],
              ));
              if (v != null && v > 0) setState(() { part.qty = v; r.manual = true; });
            },
            child: Text('${part.qty % 1 == 0 ? part.qty.toInt() : part.qty}×',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
          )),
        Expanded(child: InkWell(
          onTap: () => _choose(r, part),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: p == null ? Colors.orange.withOpacity(0.6) : (notFinished ? Colors.deepOrange : AppTheme.border)),
              borderRadius: BorderRadius.circular(6)),
            child: Row(children: [
              if (part.code != null) ...[
                Text(part.code!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                const SizedBox(width: 6),
              ],
              Expanded(child: Text(
                p != null ? '${p['name']}' : (part.choices.length > 1 ? '${part.choices.length} possible — pick one…' : 'Choose product…'),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: p == null ? AppTheme.textSecondary : null))),
              if (notFinished)
                const Tooltip(message: 'Not in the finished products groups',
                    child: Icon(Icons.warning_amber_rounded, size: 15, color: Colors.deepOrange)),
              InkWell(
                onTap: () => setState(() { r.parts.remove(part); r.manual = true; }),
                child: const Icon(Icons.close, size: 14, color: AppTheme.textSecondary)),
            ]),
          ),
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    final pending = _rows.where((r) => r.changed).length;
    final todo = _rows.where((r) => r.saved == null).length;
    final check = _rows.where((r) => r.disagrees).length;
    final unsure = _rows.where((r) => r.saved == null && !r.complete).length;
    return AlertDialog(
      title: Text('Match products · ${widget.store['name'] ?? ''}'),
      content: SizedBox(
        width: 900, height: 600,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _rows.isEmpty
                ? Center(child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.danger)))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${_rows.length} store items · $todo not saved yet${unsure > 0 ? ' · $unsure need a choice' : ''}. '
                        'Matched by the item code (e.g. ALA 301, "(S)" = special quality); several codes in one SKU make a bundle. '
                        'Tap any product to change it.',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      const Text('Match only with:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      for (final g in _allGroups.keys)
                        FilterChip(
                          visualDensity: VisualDensity.compact,
                          label: Text('$g (${_allGroups[g]})', style: const TextStyle(fontSize: 11.5)),
                          selected: _groups.contains(g),
                          onSelected: (on) {
                            final next = [..._groups];
                            on ? next.add(g) : next.remove(g);
                            _setGroups(next);
                          },
                        ),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: TextField(
                        decoration: const InputDecoration(hintText: 'Search…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
                        onChanged: (v) => setState(() => _q = v),
                      )),
                      const SizedBox(width: 10),
                      for (final f in [('todo', 'To match ($todo)'), if (check > 0) ('check', 'Check ($check)'), ('matched', 'Saved'), ('all', 'All')]) ...[
                        ChoiceChip(label: Text(f.$2), selected: _filter == f.$1, onSelected: (_) => setState(() => _filter = f.$1)),
                        const SizedBox(width: 6),
                      ],
                    ]),
                    if (check > 0)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          icon: const Icon(Icons.auto_fix_high, size: 16),
                          label: Text('$check saved match${check == 1 ? '' : 'es'} differ from the item code — use the code match for all'),
                          onPressed: () => setState(() {
                            for (final r in _rows.where((r) => r.disagrees)) {
                              r.parts = [for (final p in r.auto) p.copy()];
                              r.manual = true;
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
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(r.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                      Text([
                                        if ('${r.v['sku']}'.isNotEmpty) 'SKU ${r.v['sku']}',
                                        if ('${r.v['barcode']}'.isNotEmpty) 'Barcode ${r.v['barcode']}',
                                        if ('${r.v['status']}' != 'ACTIVE' && '${r.v['status']}'.isNotEmpty) '${r.v['status']}'.toLowerCase(),
                                      ].join(' · '), style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                      if (r.disagrees)
                                        Text('Code says: ${r.auto.map((p) => '${p.qty > 1 ? '${p.qty.toInt()}× ' : ''}${_byId[p.pid]?['name'] ?? p.code}').join(' + ')}',
                                            style: const TextStyle(fontSize: 11, color: Colors.deepOrange)),
                                    ])),
                                    const Padding(padding: EdgeInsets.only(top: 6),
                                        child: Icon(Icons.arrow_forward, size: 16, color: AppTheme.textSecondary)),
                                    const SizedBox(width: 8),
                                    Expanded(flex: 6, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      for (final part in [...r.parts]) _partBox(r, part),
                                      InkWell(
                                        onTap: () async {
                                          final part = _Part();
                                          setState(() => r.parts.add(part));
                                          await _choose(r, part);
                                          if (part.pid == null && mounted) setState(() => r.parts.remove(part));
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 2),
                                          child: Text(r.parts.isEmpty ? '+ Choose product' : '+ Add item (bundle)',
                                              style: const TextStyle(fontSize: 11.5, color: AppTheme.primary, fontWeight: FontWeight.w600)),
                                        ),
                                      ),
                                    ])),
                                    const SizedBox(width: 8),
                                    SizedBox(width: 140, child: Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Align(alignment: Alignment.centerLeft, child: _howChip(r)))),
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
