import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:excel/excel.dart' as xls;

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import 'package:opstation_web/core/pdf/pdf_output.dart';

/// Price List Generator — pick Main Group / Group / Sub Group (each All or a
/// multi-select), a margin %, and a cost source (Purchase = cost price,
/// Selling = selling price, BoM = bill-of-materials roll-up). Rate = base ×
/// (1 + margin). Output: Sr# / SKU / Product / UOM / Rate as an on-screen
/// preview and a PDF (print or save).
class ErpPriceListScreen extends ConsumerStatefulWidget {
  const ErpPriceListScreen({super.key});
  @override
  ConsumerState<ErpPriceListScreen> createState() => _ErpPriceListScreenState();
}

class _P {
  final String id, sku, name, main, group, sub, uom;
  final double cost, sell;
  _P(this.id, this.sku, this.name, this.main, this.group, this.sub, this.uom, this.cost, this.sell);
}

/// One printed line — from the live generator or from a saved snapshot.
class _Line {
  final String productId, sku, name, uom;
  final double rate;
  final bool edited;
  const _Line(this.productId, this.sku, this.name, this.uom, this.rate, this.edited);
}

class _ErpPriceListScreenState extends ConsumerState<ErpPriceListScreen> {
  bool _loading = true;
  String? _error;
  List<_P> _products = [];
  final Map<String, double> _bomRate = {}; // product_id -> BOM roll-up per unit
  bool _bomLoaded = false;

  final Set<String> _mains = {};
  final Set<String> _groups = {};
  final Set<String> _subs = {};
  final _searchCtrl = TextEditingController();     // brand / keyword filter (name or SKU)
  final Set<String> _pickedIds = {};               // explicit product picks (overrides the filtered set)
  final _marginCtrl = TextEditingController(); // user-entered; 15 shown only as a hint
  String _source = 'purchase'; // purchase | selling | bom
  String _method = 'markup';   // markup (× (1+m)) | margin (÷ (1−m))
  String _title = 'Price List'; // printed heading: 'Price List' | 'Cost Sheet'
  final Map<String, double> _override = {}; // product_id -> manually entered rate
  Map<String, dynamic>? _snap; // a saved price list being viewed (read-only); null = live generator
  final _qty = NumberFormat('#,##0.##');

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _marginCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { setState(() => _loading = false); return; }
    try {
      final c = Supabase.instance.client;
      final uoms = await c.from('uoms').select('id, abbreviation').eq('org_id', orgId);
      final uomMap = {for (final u in uoms as List) u['id'] as String: (u['abbreviation'] as String? ?? '')};
      final rows = <_P>[];
      for (int from = 0;; from += 1000) {
        final page = List<Map<String, dynamic>>.from(await c.from('products')
            .select('id, sku, name, product_main_group, product_group, product_sub_group, cost_price, selling_price, base_uom_id, is_active')
            .eq('org_id', orgId).eq('is_active', true).order('name').range(from, from + 999));
        for (final p in page) {
          rows.add(_P(
            p['id'] as String,
            (p['sku'] as String?) ?? '',
            (p['name'] as String?) ?? '(unnamed)',
            (p['product_main_group'] as String?)?.trim() ?? '',
            (p['product_group'] as String?)?.trim() ?? '',
            (p['product_sub_group'] as String?)?.trim() ?? '',
            uomMap[p['base_uom_id']] ?? '',
            (p['cost_price'] as num?)?.toDouble() ?? 0,
            (p['selling_price'] as num?)?.toDouble() ?? 0,
          ));
        }
        if (page.length < 1000 || from > 500000) break;
      }
      if (!mounted) return;
      setState(() { _products = rows; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString().split('\n').first; _loading = false; });
    }
  }

  Future<void> _ensureBomRates() async {
    if (_bomLoaded) return;
    final orgId = _orgId;
    if (orgId == null) return;
    final c = Supabase.instance.client;
    final costById = {for (final p in _products) p.id: p.cost};
    final headers = List<Map<String, dynamic>>.from(await c.from('bom_headers')
        .select('id, product_id, output_qty').eq('org_id', orgId).eq('status', 'active'));
    final bomIds = headers.map((h) => h['id'] as String).toList();
    final comps = bomIds.isEmpty ? <Map<String, dynamic>>[] : List<Map<String, dynamic>>.from(
        await c.from('bom_components').select('bom_id, product_id, quantity').inFilter('bom_id', bomIds));
    final ohs = bomIds.isEmpty ? <Map<String, dynamic>>[] : List<Map<String, dynamic>>.from(
        await c.from('bom_overheads').select('bom_id, amount').inFilter('bom_id', bomIds));
    final compByBom = <String, double>{};
    for (final r in comps) {
      final bid = r['bom_id'] as String;
      final qty = (r['quantity'] as num?)?.toDouble() ?? 0;
      final cc = costById[r['product_id'] as String?] ?? 0;
      compByBom[bid] = (compByBom[bid] ?? 0) + qty * cc;
    }
    final ohByBom = <String, double>{};
    for (final r in ohs) {
      final bid = r['bom_id'] as String;
      ohByBom[bid] = (ohByBom[bid] ?? 0) + ((r['amount'] as num?)?.toDouble() ?? 0);
    }
    _bomRate.clear();
    for (final h in headers) {
      final out = (h['output_qty'] as num?)?.toDouble() ?? 1;
      if (out <= 0) continue;
      final total = (compByBom[h['id']] ?? 0) + (ohByBom[h['id']] ?? 0);
      _bomRate[h['product_id'] as String] = total / out;
    }
    _bomLoaded = true;
  }

  // ── options that cascade with the higher-level selection ──────────────────
  List<String> get _mainOptions =>
      (_products.map((p) => p.main).where((s) => s.isNotEmpty).toSet().toList()..sort());
  List<String> get _groupOptions => (_products
      .where((p) => _mains.isEmpty || _mains.contains(p.main))
      .map((p) => p.group).where((s) => s.isNotEmpty).toSet().toList()..sort());
  List<String> get _subOptions => (_products
      .where((p) => (_mains.isEmpty || _mains.contains(p.main)) && (_groups.isEmpty || _groups.contains(p.group)))
      .map((p) => p.sub).where((s) => s.isNotEmpty).toSet().toList()..sort());

  int _cmp(_P a, _P b) {
    final m = a.main.compareTo(b.main);
    if (m != 0) return m;
    final g = a.group.compareTo(b.group);
    if (g != 0) return g;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  bool _matchGroups(_P p) {
    if (_mains.isNotEmpty && !_mains.contains(p.main)) return false;
    if (_groups.isNotEmpty && !_groups.contains(p.group)) return false;
    if (_subs.isNotEmpty && !_subs.contains(p.sub)) return false;
    return true;
  }

  // Split a search into words; a product matches when EVERY word appears
  // somewhere in its name or SKU (order/adjacency don't matter).
  List<String> _terms(String s) =>
      s.trim().toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  bool _matchTerms(_P p, List<String> terms) {
    if (terms.isEmpty) return true;
    final hay = '${p.name} ${p.sku}'.toLowerCase();
    return terms.every(hay.contains);
  }

  // Products matching the group filters + the brand/keyword search.
  List<_P> get _candidates {
    final terms = _terms(_searchCtrl.text);
    return _products.where((p) => _matchGroups(p) && _matchTerms(p, terms)).toList()
      ..sort(_cmp);
  }

  // The final list: an explicit pick if the user made one, else all candidates.
  List<_P> get _rows {
    if (_pickedIds.isEmpty) return _candidates;
    return (_products.where((p) => _pickedIds.contains(p.id)).toList()..sort(_cmp));
  }

  double get _margin => (double.tryParse(_marginCtrl.text.trim()) ?? 0);

  double _base(_P p) {
    switch (_source) {
      case 'selling': return p.sell;
      case 'bom': return _bomRate[p.id] ?? p.cost; // fallback to purchase cost
      default: return p.cost;
    }
  }

  /// Rate printed / exported: a manual override if one was entered, else the
  /// calculated rate.
  double _rate(_P p) => _override[p.id] ?? _calcRate(p);

  double _calcRate(_P p) {
    final b = _base(p);
    final m = _margin / 100;
    if (_method == 'margin') {
      // Margin on price: margin is a % OF the final price. Guard m>=100%.
      return m >= 1 ? b : b / (1 - m);
    }
    return b * (1 + m); // markup on cost
  }

  /// For a manually quoted rate: what % it works out to on the same cost
  /// source and method as the formula, and how far it is from the formula.
  /// e.g. "Quoted 160 = 45.5% markup on Purchase Cost 110 · formula 40% → 154 (+6, +3.9%)"
  String _quoteBasis(_P p, double rate) {
    final b = _base(p);
    final calc = _calcRate(p);
    final diff = rate - calc;
    final diffPct = calc > 0 ? diff / calc * 100 : 0.0;
    final sign = diff >= 0 ? '+' : '−';
    final vs = 'formula ${_qty.format(_margin)}% → ${_qty.format(calc)} '
        '($sign${_qty.format(diff.abs())}, $sign${diffPct.abs().toStringAsFixed(1)}%)';
    if (b <= 0) return 'Quoted ${_qty.format(rate)} · no $_sourceLabel to compare · $vs';
    final pct = _method == 'margin'
        ? (rate > 0 ? (rate - b) / rate * 100 : 0.0)
        : (rate / b - 1) * 100;
    return 'Quoted ${_qty.format(rate)} = ${pct.toStringAsFixed(1)}% $_methodLabel '
        '($_sourceLabel ${_qty.format(b)}) · $vs';
  }

  Future<void> _editRate(_P p) async {
    final calc = _calcRate(p);
    final ctrl = TextEditingController(text: _rate(p).toStringAsFixed(2));
    ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Calculated rate: ${_qty.format(calc)}  ($_sourceLabel, ${_qty.format(_margin)}% $_methodLabel)',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          StatefulBuilder(builder: (ctx2, setLocal) {
            final v = double.tryParse(ctrl.text.trim().replaceAll(',', ''));
            final changed = v != null && (v - calc).abs() >= 0.005;
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Rate', isDense: true, border: OutlineInputBorder()),
                onChanged: (_) => setLocal(() {}),
                onSubmitted: (_) => Navigator.pop(ctx, 'save'),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: 380,
                child: Text(
                    changed ? _quoteBasis(p, v!) : 'Same as the formula.',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: changed ? const Color(0xFF92400E) : AppTheme.textSecondary,
                        fontWeight: changed ? FontWeight.w600 : FontWeight.normal)),
              ),
            ]);
          }),
        ]),
        actions: [
          if (_override.containsKey(p.id))
            TextButton(onPressed: () => Navigator.pop(ctx, 'reset'), child: const Text('Use calculated')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (!mounted || res == null) return;
    setState(() {
      if (res == 'reset') {
        _override.remove(p.id);
      } else {
        final v = double.tryParse(ctrl.text.trim().replaceAll(',', ''));
        if (v == null || v < 0) return;
        if ((v - calc).abs() < 0.005) {
          _override.remove(p.id); // same as calculated — no need to pin it
        } else {
          _override[p.id] = v;
        }
      }
    });
  }

  String get _sourceLabel =>
      _source == 'selling' ? 'Selling Price' : (_source == 'bom' ? 'BoM Cost' : 'Purchase Cost');

  String get _methodLabel => _method == 'margin' ? 'margin on price' : 'markup on cost';

  Future<void> _pick(String title, List<String> options, Set<String> sel) async {
    final temp = Set<String>.from(sel);
    final searchCtrl = TextEditingController();
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final q = searchCtrl.text.trim().toLowerCase();
        final list = q.isEmpty ? options : options.where((o) => o.toLowerCase().contains(q)).toList();
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                TextButton(onPressed: () => setD(() => temp..clear()..addAll(list)), child: const Text('Select all')),
                TextButton(onPressed: () => setD(() => temp.clear()), child: const Text('Clear')),
              ]),
              TextField(
                controller: searchCtrl, autofocus: true,
                decoration: const InputDecoration(hintText: 'Search…', isDense: true, prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
                onChanged: (_) => setD(() {}),
              ),
              const SizedBox(height: 8),
              Flexible(child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: ListView(shrinkWrap: true, children: [
                  for (final o in list)
                    CheckboxListTile(
                      dense: true, controlAffinity: ListTileControlAffinity.leading,
                      title: Text(o, style: const TextStyle(fontSize: 13.5)),
                      value: temp.contains(o),
                      onChanged: (v) => setD(() { if (v == true) temp.add(o); else temp.remove(o); }),
                    ),
                  if (list.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No options', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))),
                ]),
              )),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Apply (${temp.length})')),
          ],
        );
      }),
    );
    if (res == true) {
      setState(() {
        sel..clear()..addAll(temp);
        // clear lower levels that no longer belong
        _groups.removeWhere((g) => !_groupOptions.contains(g));
        _subs.removeWhere((s) => !_subOptions.contains(s));
      });
    }
  }

  // Expandable popup product picker — search the whole catalogue (by brand,
  // product name or SKU) and tick the exact items to include. This is how you
  // bifurcate at brand level, e.g. "Alfa" + "Honda" air filters.
  Future<void> _pickProducts() async {
    final temp = Set<String>.from(_pickedIds);
    final searchCtrl = TextEditingController(text: _searchCtrl.text.trim());
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final terms = _terms(searchCtrl.text);
        final matches = (terms.isEmpty
                ? _products.where((p) => temp.contains(p.id))
                : _products.where((p) => _matchTerms(p, terms)))
            .toList()
          ..sort(_cmp);
        final shown = matches.take(400).toList();
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Text('Choose products', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: searchCtrl, autofocus: true,
                decoration: const InputDecoration(hintText: 'Search brand / product / SKU…', isDense: true, prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
                onChanged: (_) => setD(() {}),
              ),
              const SizedBox(height: 6),
              Row(children: [
                Text('${temp.length} selected', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                const Spacer(),
                if (terms.isNotEmpty)
                  TextButton(onPressed: () => setD(() => temp.addAll(shown.map((p) => p.id))), child: Text('Add all ${shown.length}')),
                TextButton(onPressed: () => setD(() => temp.clear()), child: const Text('Clear')),
              ]),
              Flexible(child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 380),
                child: shown.isEmpty
                    ? Center(child: Padding(padding: const EdgeInsets.all(24),
                        child: Text(terms.isEmpty ? 'Type a brand or product to search…' : 'No matches.',
                            style: const TextStyle(color: AppTheme.textSecondary))))
                    : ListView.builder(
                        shrinkWrap: true, itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final p = shown[i];
                          return CheckboxListTile(
                            dense: true, controlAffinity: ListTileControlAffinity.leading,
                            title: Text(p.name, style: const TextStyle(fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text([p.sku, p.main, p.group].where((s) => s.isNotEmpty).join('  ·  '),
                                style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                            value: temp.contains(p.id),
                            onChanged: (v) => setD(() { if (v == true) temp.add(p.id); else temp.remove(p.id); }),
                          );
                        }),
              )),
              if (matches.length > shown.length)
                Padding(padding: const EdgeInsets.only(top: 6),
                    child: Text('Showing first ${shown.length} of ${matches.length} — refine the search to see the rest.',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Use ${temp.length} product(s)')),
          ],
        );
      }),
    );
    if (res == true) setState(() { _pickedIds..clear()..addAll(temp); });
  }

  Widget _filterChip(String label, Set<String> sel, List<String> options, {IconData icon = Icons.category_outlined}) {
    final txt = sel.isEmpty ? 'All' : '${sel.length} selected';
    return OutlinedButton.icon(
      icon: Icon(icon, size: 16),
      onPressed: () => _pick(label, options, sel),
      label: Text('$label: $txt', overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(foregroundColor: AppTheme.textPrimary, alignment: Alignment.centerLeft),
    );
  }

  // ── What gets printed / exported / saved ─────────────────────────────────
  String get _outTitle => (_snap?['title'] as String?) ?? _title;

  List<_Line> _snapLines(Map<String, dynamic> snap) => [
        for (final l in (snap['lines'] as List? ?? const []))
          _Line('${l['product_id'] ?? ''}', '${l['sku'] ?? ''}', '${l['name'] ?? ''}', '${l['uom'] ?? ''}',
              (l['rate'] as num?)?.toDouble() ?? 0, l['edited'] == true),
      ];

  List<_Line> get _outLines => _snap != null
      ? _snapLines(_snap!)
      : [for (final p in _rows) _Line(p.id, p.sku, p.name, p.uom, _rate(p), _override.containsKey(p.id))];

  Future<void> _prepare() async {
    if (_snap == null && _source == 'bom') { await _ensureBomRates(); if (mounted) setState(() {}); }
  }

  // ── Save a generated list (manual, for the record) ────────────────────────
  Future<void> _save() async {
    await _prepare();
    final lines = _outLines;
    if (lines.isEmpty || !mounted) return;
    final nameCtrl = TextEditingController(text: '$_title – ${DateFormat('d MMM y').format(DateTime.now())}');
    final notesCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Save $_title', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Keeps a copy of these ${lines.length} lines and rates exactly as they are now'
                '${_override.isEmpty ? '' : ' (including ${_override.length} edited rate${_override.length == 1 ? '' : 's'})'}'
                ', with the settings used.',
                style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary, height: 1.4)),
            const SizedBox(height: 14),
            TextField(controller: nameCtrl, autofocus: true,
                decoration: const InputDecoration(labelText: 'Name *', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: notesCtrl, maxLines: 3, minLines: 2,
                decoration: const InputDecoration(labelText: 'Notes (optional)', hintText: 'e.g. Quoted to Al-Rehman Autos, valid till month end',
                    isDense: true, border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton.icon(onPressed: () => Navigator.pop(ctx, true), icon: const Icon(Icons.bookmark_add_outlined, size: 16), label: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) { _toast('Give it a name'); return; }
    final user = ref.read(currentUserProvider);
    try {
      await Supabase.instance.client.from('price_list_snapshots').insert({
        'id': 'pls_${DateTime.now().microsecondsSinceEpoch}',
        'org_id': user?.orgId,
        'title': _title,
        'name': name,
        'notes': notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
        'settings': {
          'source': _source, 'source_label': _sourceLabel, 'method': _method, 'method_label': _methodLabel,
          'margin': _margin, 'main_groups': _mains.toList(), 'groups': _groups.toList(), 'sub_groups': _subs.toList(),
          'search': _searchCtrl.text.trim(), 'picked_products': _pickedIds.length,
        },
        'lines': [
          for (final l in lines)
            {'product_id': l.productId, 'sku': l.sku, 'name': l.name, 'uom': l.uom,
             'rate': double.parse(l.rate.toStringAsFixed(4)), 'edited': l.edited},
        ],
        'item_count': lines.length,
        'edited_count': lines.where((l) => l.edited).length,
        'created_by': user?.id,
        'created_by_name': user?.name,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      _toast('Saved "$name"');
    } catch (e) {
      _toast(e.toString().contains('price_list_snapshots')
          ? 'Saving needs SQL 314 — run it in Supabase first.'
          : 'Could not save: $e');
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  // ── Saved lists ───────────────────────────────────────────────────────────
  Future<void> _openSaved() async {
    final orgId = _orgId;
    if (orgId == null) return;
    List<Map<String, dynamic>> list = [];
    String? err;
    try {
      list = List<Map<String, dynamic>>.from(await Supabase.instance.client.from('price_list_snapshots')
          .select('id, title, name, notes, item_count, edited_count, created_by, created_by_name, created_at, settings')
          .eq('org_id', orgId).order('created_at', ascending: false).limit(300));
    } catch (e) {
      err = e.toString().contains('price_list_snapshots') ? 'Run SQL 314 in Supabase to enable saved lists.' : '$e';
    }
    if (!mounted) return;
    final user = ref.read(currentUserProvider);
    final isAdmin = user?.role == WebUserRole.admin || user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.superAdmin;
    final q = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final shown = list.where((r) {
          final t = q.text.trim().toLowerCase();
          return t.isEmpty || '${r['name']} ${r['notes'] ?? ''} ${r['title']} ${r['created_by_name'] ?? ''}'.toLowerCase().contains(t);
        }).toList();
        return AlertDialog(
          title: const Text('Saved price lists & cost sheets', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: 640, height: 480,
            child: err != null
                ? Center(child: Text(err, style: const TextStyle(color: AppTheme.danger)))
                : Column(children: [
                    TextField(controller: q, onChanged: (_) => setD(() {}),
                        decoration: const InputDecoration(hintText: 'Search name, notes, person…', prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder())),
                    const SizedBox(height: 8),
                    Expanded(child: shown.isEmpty
                        ? const Center(child: Text('Nothing saved yet. Use Save on a generated list to keep a record.', style: TextStyle(color: AppTheme.textSecondary)))
                        : ListView.separated(
                            itemCount: shown.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final r = shown[i];
                              final st = Map<String, dynamic>.from(r['settings'] as Map? ?? {});
                              final when = DateTime.tryParse('${r['created_at']}')?.toLocal();
                              final isCost = r['title'] == 'Cost Sheet';
                              final canDelete = isAdmin || r['created_by'] == user?.id;
                              return ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                                leading: CircleAvatar(
                                  radius: 16,
                                  backgroundColor: (isCost ? Colors.deepPurple : AppTheme.primary).withValues(alpha: 0.1),
                                  child: Icon(isCost ? Icons.calculate_outlined : Icons.sell_outlined, size: 16,
                                      color: isCost ? Colors.deepPurple : AppTheme.primary),
                                ),
                                title: Text('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                                subtitle: Text(
                                  '${r['title']} · ${r['item_count'] ?? 0} items'
                                  '${(r['edited_count'] ?? 0) > 0 ? ' · ${r['edited_count']} edited' : ''}'
                                  ' · ${st['source_label'] ?? st['source'] ?? ''} ${st['margin'] ?? ''}%'
                                  '\n${r['created_by_name'] ?? '—'} · ${when == null ? '' : DateFormat('d MMM y, h:mm a').format(when)}'
                                  '${(r['notes'] as String?)?.isNotEmpty == true ? '\n${r['notes']}' : ''}',
                                  style: const TextStyle(fontSize: 11.5, height: 1.35),
                                ),
                                isThreeLine: true,
                                onTap: () async {
                                  Navigator.pop(ctx);
                                  await _loadSnap(r['id'] as String);
                                },
                                trailing: canDelete
                                    ? IconButton(
                                        tooltip: 'Delete',
                                        icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                                        onPressed: () async {
                                          final yes = await showDialog<bool>(context: ctx, builder: (c2) => AlertDialog(
                                            title: const Text('Delete saved list?'),
                                            content: Text('"${r['name']}" will be removed. This can\'t be undone.'),
                                            actions: [
                                              TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('Cancel')),
                                              TextButton(onPressed: () => Navigator.pop(c2, true), child: const Text('Delete', style: TextStyle(color: AppTheme.danger))),
                                            ],
                                          ));
                                          if (yes != true) return;
                                          try {
                                            await Supabase.instance.client.from('price_list_snapshots').delete().eq('id', r['id'] as String);
                                            setD(() => list.removeWhere((x) => x['id'] == r['id']));
                                            if (_snap?['id'] == r['id'] && mounted) setState(() => _snap = null);
                                          } catch (e) { _toast('Could not delete: $e'); }
                                        },
                                      )
                                    : null,
                              );
                            },
                          )),
                  ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        );
      }),
    );
  }

  Future<void> _loadSnap(String id) async {
    try {
      final row = await Supabase.instance.client.from('price_list_snapshots').select().eq('id', id).single();
      if (mounted) setState(() => _snap = Map<String, dynamic>.from(row));
    } catch (e) { _toast('Could not open: $e'); }
  }

  Widget _snapBanner() {
    final s = _snap!;
    final st = Map<String, dynamic>.from(s['settings'] as Map? ?? {});
    final when = DateTime.tryParse('${s['created_at']}')?.toLocal();
    return Container(
      constraints: const BoxConstraints(maxWidth: 1040),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF2FF), borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFC7D2FE)),
      ),
      child: Row(children: [
        const Icon(Icons.bookmark, size: 20, color: Color(0xFF3730A3)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Saved: ${s['name']}', style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF312E81))),
          Text('${s['title']} · ${s['item_count'] ?? 0} items · ${st['source_label'] ?? st['source'] ?? ''}, '
              '${st['margin'] ?? ''}% ${st['method_label'] ?? ''} · saved by ${s['created_by_name'] ?? '—'}'
              '${when == null ? '' : ' on ${DateFormat('d MMM y, h:mm a').format(when)}'}',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF4338CA))),
          if ((s['notes'] as String?)?.isNotEmpty == true)
            Padding(padding: const EdgeInsets.only(top: 3),
                child: Text('${s['notes']}', style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
        ])),
        TextButton.icon(
          onPressed: () => setState(() => _snap = null),
          icon: const Icon(Icons.close, size: 16),
          label: const Text('Back to generator'),
        ),
      ]),
    );
  }

  Future<void> _generatePdf() async {
    await _prepare();
    final rows = _outLines;
    if (rows.isEmpty) return;
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    // Customer-facing document: heading + org + generated timestamp ONLY.
    // Never print margin %, cost source, or group scope (confidential).
    final stamp = DateFormat('d MMM y, h:mm a').format(DateTime.now());

    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (ctx) => [
        if (org.isNotEmpty) pw.Text(org, style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        pw.Text(_outTitle, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text('Generated: $stamp', style: pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: const ['Sr.#', 'SKU', 'Product Name', 'UOM', 'Rate'],
          data: [
            for (var i = 0; i < rows.length; i++)
              ['${i + 1}', rows[i].sku, rows[i].name, rows[i].uom, _qty.format(rows[i].rate)],
          ],
          headerStyle: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 9.5),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          columnWidths: {
            0: const pw.FixedColumnWidth(34),
            1: const pw.FixedColumnWidth(60),
            2: const pw.FlexColumnWidth(4),
            3: const pw.FixedColumnWidth(44),
            4: const pw.FixedColumnWidth(64),
          },
          cellAlignments: const {0: pw.Alignment.centerLeft, 3: pw.Alignment.center, 4: pw.Alignment.centerRight},
        ),
      ],
    ));
    await outputPdf(await doc.save(), _outTitle);
  }

  Future<void> _exportExcel() async {
    await _prepare();
    final rows = _outLines;
    if (rows.isEmpty) return;
    final title = _outTitle;
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final stamp = DateFormat('d MMM y, h:mm a').format(DateTime.now());
    final excel = xls.Excel.createExcel();
    final sheetName = title;
    final sheet = excel[sheetName];
    final def = excel.getDefaultSheet();
    if (def != null && def != sheetName) excel.delete(def);

    // Same customer-facing content as the PDF (heading, org, timestamp, table) —
    // styled to match it. No margin / cost source / scope (confidential).
    xls.ExcelColor c(String hex) => xls.ExcelColor.fromHexString(hex);
    final thin = xls.Border(borderStyle: xls.BorderStyle.Thin, borderColorHex: c('#CBD5E1'));
    final head = xls.Border(borderStyle: xls.BorderStyle.Thin, borderColorHex: c('#1E3A8A'));
    xls.CellIndex at(int col, int row) => xls.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row);
    const lastCol = 4; // A..E

    final orgStyle = xls.CellStyle(bold: true, fontSize: 11, fontColorHex: c('#475569'));
    final titleStyle = xls.CellStyle(bold: true, fontSize: 18, fontColorHex: c('#1E3A8A'));
    final stampStyle = xls.CellStyle(italic: true, fontSize: 9, fontColorHex: c('#64748B'));
    final hdrStyle = xls.CellStyle(
      bold: true, fontSize: 10, fontColorHex: c('#FFFFFF'), backgroundColorHex: c('#1E3A8A'),
      horizontalAlign: xls.HorizontalAlign.Center, verticalAlign: xls.VerticalAlign.Center,
      leftBorder: head, rightBorder: head, topBorder: head, bottomBorder: head,
    );
    xls.CellStyle body({bool zebra = false, xls.HorizontalAlign align = xls.HorizontalAlign.Left,
        bool bold = false, bool money = false}) => xls.CellStyle(
          fontSize: 10, bold: bold,
          backgroundColorHex: zebra ? c('#F1F5F9') : c('#FFFFFF'),
          horizontalAlign: align, verticalAlign: xls.VerticalAlign.Center,
          leftBorder: thin, rightBorder: thin, topBorder: thin, bottomBorder: thin,
          numberFormat: money ? xls.NumFormat.standard_4 : xls.NumFormat.standard_0,
        );

    var r = 0;
    if (org.isNotEmpty) {
      sheet.merge(at(0, r), at(lastCol, r), customValue: xls.TextCellValue(org));
      sheet.cell(at(0, r)).cellStyle = orgStyle;
      r++;
    }
    sheet.merge(at(0, r), at(lastCol, r), customValue: xls.TextCellValue(title));
    sheet.cell(at(0, r)).cellStyle = titleStyle;
    sheet.setRowHeight(r, 28);
    r++;
    sheet.merge(at(0, r), at(lastCol, r), customValue: xls.TextCellValue('Generated: $stamp'));
    sheet.cell(at(0, r)).cellStyle = stampStyle;
    r += 2; // blank spacer row

    const headers = ['Sr.#', 'SKU', 'Product Name', 'UOM', 'Rate'];
    for (var i = 0; i < headers.length; i++) {
      sheet.updateCell(at(i, r), xls.TextCellValue(headers[i]), cellStyle: hdrStyle);
    }
    sheet.setRowHeight(r, 22);
    r++;

    for (var i = 0; i < rows.length; i++) {
      final p = rows[i];
      final z = i.isOdd;
      sheet.updateCell(at(0, r), xls.IntCellValue(i + 1), cellStyle: body(zebra: z, align: xls.HorizontalAlign.Center));
      sheet.updateCell(at(1, r), xls.TextCellValue(p.sku), cellStyle: body(zebra: z));
      sheet.updateCell(at(2, r), xls.TextCellValue(p.name), cellStyle: body(zebra: z));
      sheet.updateCell(at(3, r), xls.TextCellValue(p.uom), cellStyle: body(zebra: z, align: xls.HorizontalAlign.Center));
      sheet.updateCell(at(4, r), xls.DoubleCellValue(double.parse(p.rate.toStringAsFixed(2))),
          cellStyle: body(zebra: z, align: xls.HorizontalAlign.Right, bold: true, money: true));
      r++;
    }

    r++;
    sheet.merge(at(0, r), at(lastCol, r),
        customValue: xls.TextCellValue('${rows.length} item${rows.length == 1 ? '' : 's'}'));
    sheet.cell(at(0, r)).cellStyle = stampStyle;

    sheet.setColumnWidth(0, 7);
    sheet.setColumnWidth(1, 14);
    sheet.setColumnWidth(2, 52);
    sheet.setColumnWidth(3, 9);
    sheet.setColumnWidth(4, 15);

    excel.save(fileName: '${title.toLowerCase().replaceAll(' ', '-')}-${DateFormat('yyyyMMdd').format(DateTime.now())}.xlsx');
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return LayoutBuilder(builder: (context, c) {
      final mobile = c.maxWidth < 640;
      return Container(
        color: AppTheme.background,
        padding: EdgeInsets.all(mobile ? 16 : 28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Price List Generator', style: TextStyle(fontSize: mobile ? 22 : 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Pick the groups, a margin and a cost source, then generate a printable price list.',
              style: TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Expanded(child: Center(child: Text('Failed to load: $_error', style: const TextStyle(color: AppTheme.danger))))
          else ...[
            Container(
              constraints: const BoxConstraints(maxWidth: 1040),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SizedBox(width: mobile ? double.infinity : 240, child: _filterChip('Main Group', _mains, _mainOptions, icon: Icons.folder_outlined)),
                  SizedBox(width: mobile ? double.infinity : 240, child: _filterChip('Group', _groups, _groupOptions, icon: Icons.folder_open_outlined)),
                  SizedBox(width: mobile ? double.infinity : 240, child: _filterChip('Sub Group', _subs, _subOptions, icon: Icons.subdirectory_arrow_right)),
                ]),
                const SizedBox(height: 12),
                // Brand / keyword narrowing + explicit product picker
                Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SizedBox(width: mobile ? double.infinity : 320, child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      labelText: 'Search brand / product / SKU',
                      hintText: 'e.g. Alfa  ·  Honda  ·  Air Filter',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      isDense: true, border: const OutlineInputBorder(),
                      suffixIcon: _searchCtrl.text.isEmpty ? null
                          : IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => _searchCtrl.clear()),
                    ),
                  )),
                  OutlinedButton.icon(
                    onPressed: _pickProducts,
                    icon: const Icon(Icons.checklist_rtl, size: 18),
                    label: Text(_pickedIds.isEmpty ? 'Choose specific products…' : 'Chosen: ${_pickedIds.length}'),
                    style: OutlinedButton.styleFrom(foregroundColor: AppTheme.primary),
                  ),
                  if (_pickedIds.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => setState(() => _pickedIds.clear()),
                      icon: const Icon(Icons.close, size: 15),
                      label: const Text('Use all filtered instead'),
                    ),
                ]),
                const SizedBox(height: 12),
                Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SizedBox(width: 150, child: TextField(
                    controller: _marginCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Margin %', hintText: '15', isDense: true, border: OutlineInputBorder(), suffixText: '%'),
                  )),
                  SizedBox(width: 220, child: DropdownButtonFormField<String>(
                    value: _source, isDense: true,
                    decoration: const InputDecoration(labelText: 'Source of cost', isDense: true, border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'purchase', child: Text('Purchase (cost price)')),
                      DropdownMenuItem(value: 'selling', child: Text('Selling (selling price)')),
                      DropdownMenuItem(value: 'bom', child: Text('BoM (recipe roll-up)')),
                    ],
                    onChanged: (v) => setState(() => _source = v ?? 'purchase'),
                  )),
                  SizedBox(width: 240, child: DropdownButtonFormField<String>(
                    value: _method, isDense: true,
                    decoration: const InputDecoration(labelText: 'Costing method', isDense: true, border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'markup', child: Text('Markup on cost')),
                      DropdownMenuItem(value: 'margin', child: Text('Margin on price')),
                    ],
                    onChanged: (v) => setState(() => _method = v ?? 'markup'),
                  )),
                  SizedBox(width: 180, child: DropdownButtonFormField<String>(
                    value: _title, isDense: true,
                    decoration: const InputDecoration(labelText: 'Document title', isDense: true, border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'Price List', child: Text('Price List')),
                      DropdownMenuItem(value: 'Cost Sheet', child: Text('Cost Sheet')),
                    ],
                    onChanged: (v) => setState(() => _title = v ?? 'Price List'),
                  )),
                  ElevatedButton.icon(
                    onPressed: (rows.isEmpty && _snap == null) ? null : _generatePdf,
                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: const Text('PDF / Print'),
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
                  ),
                  OutlinedButton.icon(
                    onPressed: (rows.isEmpty && _snap == null) ? null : _exportExcel,
                    icon: const Icon(Icons.table_view_outlined, size: 18),
                    label: const Text('Excel'),
                    style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF1D6F42)),
                  ),
                  if (_snap == null)
                    OutlinedButton.icon(
                      onPressed: rows.isEmpty ? null : _save,
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      label: const Text('Save'),
                      style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF3730A3)),
                    ),
                  TextButton.icon(
                    onPressed: _openSaved,
                    icon: const Icon(Icons.bookmarks_outlined, size: 18),
                    label: const Text('Saved'),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFF3730A3)),
                  ),
                ]),
              ]),
            ),
            const SizedBox(height: 10),
            if (_snap != null) _snapBanner() else
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
              Text('${rows.length} product(s)  ·  Rate = $_sourceLabel, ${_qty.format(_margin)}% ($_methodLabel)'
                  '  ·  tap a rate to edit it',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              if (_override.isNotEmpty)
                TextButton.icon(
                  onPressed: () => setState(_override.clear),
                  icon: const Icon(Icons.restart_alt, size: 15),
                  label: Text('Reset ${_override.length} edited rate${_override.length == 1 ? '' : 's'}', style: const TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(foregroundColor: const Color(0xFFB45309), visualDensity: VisualDensity.compact),
                ),
            ]),
            const SizedBox(height: 8),
            Expanded(child: _preview(_outLines, mobile)),
          ],
        ]),
      );
    });
  }

  Widget _preview(List<_Line> rows, bool mobile) {
    final live = _snap == null;
    final byId = live ? {for (final p in _rows) p.id: p} : const <String, _P>{};
    return Container(
      constraints: const BoxConstraints(maxWidth: 1040),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: rows.isEmpty
          ? const Center(child: Text('No products match the selected groups.', style: TextStyle(color: AppTheme.textSecondary)))
          : Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                child: Row(children: const [
                  SizedBox(width: 40, child: Text('Sr.#', style: _hs)),
                  SizedBox(width: 80, child: Text('SKU', style: _hs)),
                  Expanded(child: Text('Product Name', style: _hs)),
                  SizedBox(width: 60, child: Text('UOM', style: _hs, textAlign: TextAlign.center)),
                  SizedBox(width: 110, child: Text('Rate', style: _hs, textAlign: TextAlign.right)),
                ]),
              ),
              const Divider(height: 1),
              Expanded(child: ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = rows[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    child: Row(children: [
                      SizedBox(width: 40, child: Text('${i + 1}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                      SizedBox(width: 80, child: Text(p.sku, style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Expanded(child: Builder(builder: (_) {
                        final src = live && p.edited ? byId[p.productId] : null;
                        final name = Text(p.name, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis);
                        if (src == null) return name;
                        // Manually quoted: show what that rate works out to vs the formula.
                        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          name,
                          const SizedBox(height: 2),
                          Text(_quoteBasis(src, p.rate),
                              maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11, color: Color(0xFF92400E))),
                        ]);
                      })),
                      SizedBox(width: 60, child: Text(p.uom, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.center)),
                      SizedBox(width: 110, child: Builder(builder: (_) {
                        final edited = p.edited;
                        final src = byId[p.productId];
                        return InkWell(
                          onTap: (live && src != null) ? () => _editRate(src) : null,
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            decoration: BoxDecoration(
                              color: edited ? const Color(0xFFFFF7E6) : null,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: edited ? const Color(0xFFF5C26B) : (live ? AppTheme.border : Colors.transparent)),
                            ),
                            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                              if (live || edited) Icon(edited ? Icons.edit : Icons.edit_outlined, size: 11,
                                  color: edited ? const Color(0xFFB45309) : AppTheme.textSecondary),
                              const SizedBox(width: 4),
                              Flexible(child: Text(_qty.format(p.rate), textAlign: TextAlign.right, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700,
                                      color: edited ? const Color(0xFF7C4A03) : AppTheme.textPrimary))),
                            ]),
                          ),
                        );
                      })),
                    ]),
                  );
                },
              )),
            ]),
    );
  }
}

const _hs = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
