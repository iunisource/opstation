import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';

/// Product timeline (Products screen ▸ timeline icon).
///
/// Two sources, merged newest first:
///  • Recorded changes to the product itself (product_history, SQL 317) —
///    name / SKU / groups / UOM / prices / status … with old → new and who.
///  • Business events read from existing data (full history): purchases (with
///    cost changes), sale-price changes, BOM saves, production, adjustments,
///    transfers, damage, returns, and out-of-stock / back-in-stock moments.
Future<void> showProductTimeline(BuildContext context, {required String orgId, required Map<String, dynamic> product}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ProductTimelineDialog(orgId: orgId, product: product),
  );
}

class _Ev {
  final DateTime at;
  final String cat; // price | details | stock | bom
  final IconData icon;
  final Color color;
  final String title;
  final String? sub;
  final String? who;
  final String? ref;
  final List<(String, String, String)> diffs; // field, old, new
  const _Ev({required this.at, required this.cat, required this.icon, required this.color, required this.title,
      this.sub, this.who, this.ref, this.diffs = const []});
}

class _ProductTimelineDialog extends StatefulWidget {
  final String orgId;
  final Map<String, dynamic> product;
  const _ProductTimelineDialog({required this.orgId, required this.product});
  @override
  State<_ProductTimelineDialog> createState() => _ProductTimelineDialogState();
}

class _ProductTimelineDialogState extends State<_ProductTimelineDialog> {
  bool _loading = true;
  String? _note; // non-fatal notice (e.g. SQL 317 not run yet)
  List<_Ev> _events = [];
  String _filter = 'all';
  final List<(DateTime, double)> _costPts = [];
  final List<(DateTime, double)> _sellPts = [];
  bool _historyAvailable = true;

  final _df = DateFormat('d MMM y');
  final _dtf = DateFormat('d MMM y, h:mm a');

  String get _pid => '${widget.product['id']}';
  SupabaseClient get _c => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static double _n(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
  static DateTime? _d(dynamic v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
  static String _q(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  Future<List<Map<String, dynamic>>> _byIds(String table, String select, Set<String> ids) async {
    final out = <Map<String, dynamic>>[];
    final list = ids.where((e) => e.isNotEmpty).toList();
    for (var i = 0; i < list.length; i += 150) {
      final chunk = list.sublist(i, math.min(i + 150, list.length));
      try {
        out.addAll(List<Map<String, dynamic>>.from(await _c.from(table).select(select).inFilter('id', chunk)));
      } catch (_) {}
    }
    return out;
  }

  Future<void> _load() async {
    final ev = <_Ev>[];
    final uomName = <String, String>{};
    try {
      for (final u in (await _c.from('uoms').select('id, abbreviation, name').eq('org_id', widget.orgId)) as List) {
        uomName['${u['id']}'] = '${u['abbreviation'] ?? u['name'] ?? ''}';
      }
    } catch (_) {}

    // ── 0. Created ───────────────────────────────────────────────────────────
    final created = _d(widget.product['created_at']);
    if (created != null) {
      ev.add(_Ev(at: created, cat: 'details', icon: Icons.fiber_new_outlined, color: AppTheme.primary,
          title: 'Product created', sub: '${widget.product['name'] ?? ''}'));
    }

    // ── 1. Recorded master changes (SQL 317) ────────────────────────────────
    try {
      final rows = await _c.from('product_history').select().eq('org_id', widget.orgId).eq('product_id', _pid)
          .order('changed_at', ascending: false).limit(500);
      for (final r in rows as List) {
        if (r['event_type'] == 'created') continue; // covered by "Product created"
        final ch = Map<String, dynamic>.from(r['changes'] as Map? ?? {});
        if (ch.isEmpty) continue;
        final diffs = <(String, String, String)>[];
        var priceTouch = false;
        for (final e in ch.entries) {
          final m = Map<String, dynamic>.from(e.value as Map? ?? {});
          diffs.add((_fieldLabel(e.key), _fmtVal(e.key, m['old'], uomName), _fmtVal(e.key, m['new'], uomName)));
          if (e.key == 'selling_price' || e.key == 'cost_price') priceTouch = true;
          final at = _d(r['changed_at']);
          if (at != null && e.key == 'cost_price') _costPts.add((at, _n(m['new'])));
          if (at != null && e.key == 'selling_price') _sellPts.add((at, _n(m['new'])));
        }
        final only = ch.keys.length == 1 ? ch.keys.first : null;
        ev.add(_Ev(
          at: _d(r['changed_at']) ?? DateTime(2000),
          cat: priceTouch ? 'price' : 'details',
          icon: priceTouch ? Icons.sell_outlined : Icons.edit_note,
          color: priceTouch ? Colors.deepPurple : Colors.blueGrey,
          title: only == 'supervised_at' ? 'Supervised'
              : only == 'is_active' ? ((ch['is_active']?['new'] == true) ? 'Re-activated' : 'Deactivated')
              : priceTouch && ch.length <= 2 ? 'Price updated' : 'Details updated',
          who: r['changed_by_name'] as String?,
          diffs: diffs,
        ));
      }
    } catch (e) {
      _historyAvailable = false;
    }

    // ── 2. BOM saves ─────────────────────────────────────────────────────────
    try {
      final rows = await _c.from('product_lifecycle').select('code, event_type, changed_at, changed_by_name')
          .eq('org_id', widget.orgId).eq('product_id', _pid).order('changed_at', ascending: false).limit(200);
      for (final r in rows as List) {
        ev.add(_Ev(at: _d(r['changed_at']) ?? DateTime(2000), cat: 'bom', icon: Icons.account_tree_outlined,
            color: Colors.teal, title: r['event_type'] == 'created' ? 'BOM created' : 'BOM updated',
            ref: r['code'] as String?, who: r['changed_by_name'] as String?));
      }
    } catch (_) {}

    // ── 3. Purchases (each one, with cost change vs the previous purchase) ───
    try {
      final items = List<Map<String, dynamic>>.from(await _c.from('purchase_invoice_items').select().eq('product_id', _pid).limit(2000));
      final heads = {for (final h in await _byIds('purchase_invoices', '*', items.map((i) => '${i['invoice_id']}').toSet())) '${h['id']}': h};
      final sups = <String, String>{};
      for (final s in await _byIds('suppliers', 'id, name', heads.values.map((h) => '${h['supplier_id'] ?? ''}').toSet())) {
        sups['${s['id']}'] = '${s['name'] ?? ''}';
      }
      final buys = <(DateTime, double, double, String, String)>[]; // at, qty, rate, ref, supplier
      for (final it in items) {
        final h = heads['${it['invoice_id']}'];
        if (h == null || h['org_id'] != widget.orgId || h['is_voided'] == true) continue;
        final qty = _n(it['qty_received'] ?? it['quantity']);
        if (qty <= 0) continue;
        final lt = _n(it['line_total']);
        final rate = lt > 0 ? lt / qty : _n(it['unit_cost'] ?? it['unit_price'] ?? it['rate']);
        final at = _d(h['voucher_date']) ?? _d(h['created_at']) ?? DateTime(2000);
        buys.add((at, qty, rate, '${h['voucher_number'] ?? ''}', sups['${h['supplier_id']}'] ?? ''));
      }
      buys.sort((a, b) => a.$1.compareTo(b.$1));
      double? prev;
      for (var i = 0; i < buys.length; i++) {
        final b = buys[i];
        final chg = prev == null || prev == 0 ? null : (b.$3 - prev) / prev * 100;
        final moved = chg != null && chg.abs() >= 0.5;
        ev.add(_Ev(
          at: b.$1, cat: moved || i == 0 ? 'price' : 'stock',
          icon: Icons.shopping_cart_outlined,
          color: moved ? (chg > 0 ? AppTheme.danger : AppTheme.success) : Colors.indigo,
          title: i == 0 ? 'First purchase' : (moved ? 'Purchase cost ${chg > 0 ? 'up' : 'down'} ${chg.abs().toStringAsFixed(1)}%' : 'Purchased'),
          sub: '${_q(b.$2)} @ ${money(b.$3)}${b.$5.isEmpty ? '' : ' from ${b.$5}'}'
              '${moved ? '  (was ${money(prev)})' : ''}',
          ref: b.$4,
        ));
        _costPts.add((b.$1, b.$3));
        prev = b.$3;
      }
    } catch (_) {}

    // ── 4. Sale price changes (first sale + whenever the invoice rate moves) ─
    try {
      final items = List<Map<String, dynamic>>.from(await _c.from('sales_invoice_items').select().eq('product_id', _pid).limit(3000));
      final heads = {for (final h in await _byIds('sales_invoices', '*', items.map((i) => '${i['invoice_id']}').toSet())) '${h['id']}': h};
      final sales = <(DateTime, double, String)>[];
      for (final it in items) {
        final h = heads['${it['invoice_id']}'];
        if (h == null || h['org_id'] != widget.orgId || h['is_voided'] == true || it['is_foc'] == true) continue;
        final price = _n(it['unit_price']);
        if (price <= 0) continue;
        sales.add((_d(h['voucher_date']) ?? _d(h['created_at']) ?? DateTime(2000), price, '${h['voucher_number'] ?? ''}'));
      }
      sales.sort((a, b) => a.$1.compareTo(b.$1));
      double? last;
      for (var i = 0; i < sales.length; i++) {
        final s = sales[i];
        _sellPts.add((s.$1, s.$2));
        if (i == 0) {
          ev.add(_Ev(at: s.$1, cat: 'price', icon: Icons.point_of_sale, color: Colors.green.shade700,
              title: 'First sale', sub: 'at ${money(s.$2)}', ref: s.$3));
        } else if (last != null && last > 0 && ((s.$2 - last) / last).abs() >= 0.005) {
          final pct = (s.$2 - last) / last * 100;
          ev.add(_Ev(at: s.$1, cat: 'price', icon: Icons.trending_flat, color: pct > 0 ? Colors.green.shade700 : Colors.orange.shade800,
              title: 'Sold at a new price (${pct > 0 ? '+' : ''}${pct.toStringAsFixed(1)}%)',
              sub: '${money(s.$2)}  (was ${money(last)})', ref: s.$3));
        }
        last = s.$2;
      }
    } catch (_) {}

    // ── 5. Stock movements: other documents + out-of-stock / back-in-stock ──
    try {
      final mv = <Map<String, dynamic>>[];
      for (var from = 0; from < 50000; from += 1000) {
        final page = List<Map<String, dynamic>>.from(await _c.from('inventory_movements')
            .select('quantity, movement_type, reference_type, reference_id, moved_at, created_at, notes')
            .eq('org_id', widget.orgId).eq('product_id', _pid)
            .order('moved_at', ascending: true).range(from, from + 999));
        mv.addAll(page);
        if (page.length < 1000) break;
      }
      // Group "other" documents (not purchases / sales — shown above) per reference.
      final groups = <String, Map<String, dynamic>>{};
      double bal = 0;
      var wasOut = true;
      var started = false;
      for (final m in mv) {
        final q = _n(m['quantity']);
        final at = _d(m['moved_at']) ?? _d(m['created_at']) ?? DateTime(2000);
        final before = bal;
        bal += q;
        if (started || bal > 0) {
          if (!wasOut && before > 0 && bal <= 0) {
            ev.add(_Ev(at: at, cat: 'stock', icon: Icons.remove_shopping_cart_outlined, color: AppTheme.danger,
                title: 'Out of stock', sub: 'All branches reached ${_q(bal)}'));
            wasOut = true;
          } else if (wasOut && before <= 0 && bal > 0) {
            if (started) {
              ev.add(_Ev(at: at, cat: 'stock', icon: Icons.inventory_outlined, color: AppTheme.success,
                  title: 'Back in stock', sub: 'Now ${_q(bal)}'));
            }
            wasOut = false;
          }
          started = true;
        }
        final t = '${m['movement_type'] ?? m['reference_type'] ?? ''}'.toLowerCase();
        final r = '${m['reference_type'] ?? ''}'.toLowerCase();
        final isBuySell = (t.contains('purchase') && !t.contains('return')) || t.contains('grn') ||
            (t.contains('sale') && !t.contains('return')) || t.contains('pos') || r.startsWith('pos') ||
            r.startsWith('sales_invoice') || r.startsWith('delivery') || r.startsWith('purchase_invoice') || r.startsWith('grn') || r.startsWith('purchase_grn');
        if (isBuySell) continue;
        final key = '${m['reference_id'] ?? at.toIso8601String()}|$t';
        final g = groups.putIfAbsent(key, () => {'at': at, 't': t, 'r': r, 'qty': 0.0, 'notes': m['notes'], 'id': m['reference_id']});
        g['qty'] = (g['qty'] as double) + q;
      }
      for (final g in groups.values) {
        final t = g['t'] as String;
        final q = g['qty'] as double;
        final (label, icon, color) = _mvLabel(t, q);
        ev.add(_Ev(at: g['at'] as DateTime, cat: 'stock', icon: icon, color: color, title: label,
            sub: '${q > 0 ? '+' : ''}${_q(q)}${(g['notes'] as String?)?.trim().isNotEmpty == true ? '  ·  ${g['notes']}' : ''}'));
      }
    } catch (_) {}

    ev.sort((a, b) => b.at.compareTo(a.at));
    _costPts.sort((a, b) => a.$1.compareTo(b.$1));
    _sellPts.sort((a, b) => a.$1.compareTo(b.$1));
    if (!mounted) return;
    setState(() {
      _events = ev;
      _loading = false;
      if (!_historyAvailable) _note = 'Run SQL 317 to start recording changes to product details and prices.';
    });
  }

  (String, IconData, Color) _mvLabel(String t, double q) {
    if (t.contains('opening')) return ('Opening stock', Icons.flag_outlined, Colors.blueGrey);
    if (t.contains('return')) return (t.contains('purchase') ? 'Returned to supplier' : 'Returned by customer', Icons.undo, Colors.orange.shade800);
    if (t.contains('damage')) return ('Damaged', Icons.broken_image_outlined, AppTheme.danger);
    if (t.contains('waste')) return ('Waste', Icons.delete_sweep_outlined, Colors.brown);
    if (t.contains('transfer')) return (q < 0 ? 'Transferred out' : 'Transferred in', Icons.swap_horiz, Colors.indigo);
    if (t.contains('adjust') || t.contains('reconcil')) return ('Stock adjusted', Icons.tune, Colors.blueGrey);
    if (t.contains('jobwork')) return (q < 0 ? 'Sent through job-work' : 'Received from job-work', Icons.handyman_outlined, Colors.teal);
    if (t.contains('production') || t.contains('job') || t.contains('assembl') || t.contains('manufactur')) {
      return (q < 0 ? 'Used in production' : 'Produced', Icons.precision_manufacturing_outlined, Colors.teal);
    }
    final pretty = t.split('_').where((w) => w.isNotEmpty).map((w) => '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
    return (pretty.isEmpty ? 'Stock movement' : pretty, Icons.swap_vert, Colors.blueGrey);
  }

  String _fieldLabel(String f) => const {
        'name': 'Name', 'sku': 'SKU', 'barcode': 'Barcode', 'base_uom_id': 'Unit', 'product_type': 'Type',
        'product_main_group': 'Main group', 'product_group': 'Group', 'product_sub_group': 'Sub group',
        'product_class': 'Class', 'product_movement_category': 'Movement category',
        'selling_price': 'Selling price', 'cost_price': 'Cost price', 'low_stock_limit': 'Low-stock limit',
        'is_active': 'Active', 'is_consignment': 'Consignment', 'is_service': 'Service item', 'supervised_at': 'Supervised',
      }[f] ?? f;

  String _fmtVal(String f, dynamic v, Map<String, String> uoms) {
    if (v == null || '$v'.isEmpty) return '—';
    if (f == 'selling_price' || f == 'cost_price') return money(_n(v));
    if (f == 'low_stock_limit') return _q(_n(v));
    if (v is bool) return v ? 'Yes' : 'No';
    if (f == 'base_uom_id') return uoms['$v'] ?? '$v';
    if (f == 'supervised_at') { final d = _d(v); return d == null ? '$v' : _dtf.format(d); }
    return '$v';
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  List<_Ev> get _shown => _filter == 'all' ? _events : _events.where((e) => e.cat == _filter).toList();

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final counts = <String, int>{};
    for (final e in _events) { counts[e.cat] = (counts[e.cat] ?? 0) + 1; }
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 760),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
            child: Row(children: [
              const Icon(Icons.timeline, color: AppTheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p['name'] ?? 'Product'}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text('${(p['sku'] ?? '').toString().isEmpty ? '' : 'SKU ${p['sku']}  ·  '}Timeline — changes and events over time',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ])),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
          ),
          const Divider(height: 1),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(20, 14, 20, 20), children: [
              if (_note != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFFFFF7E6), borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFF5C26B))),
                  child: Text(_note!, style: const TextStyle(fontSize: 12, color: Color(0xFF7C4A03))),
                ),
              if (_costPts.length + _sellPts.length >= 2) ...[
                _chartCard(),
                const SizedBox(height: 14),
              ],
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final f in const [('all', 'All'), ('price', 'Price & Cost'), ('details', 'Product details'), ('stock', 'Stock'), ('bom', 'BOM')])
                  ChoiceChip(
                    label: Text(f.$1 == 'all' ? '${f.$2} (${_events.length})' : '${f.$2} (${counts[f.$1] ?? 0})',
                        style: TextStyle(fontSize: 12, fontWeight: _filter == f.$1 ? FontWeight.w700 : FontWeight.w500,
                            color: _filter == f.$1 ? Colors.white : AppTheme.textPrimary)),
                    selected: _filter == f.$1,
                    showCheckmark: false,
                    selectedColor: AppTheme.primary,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _filter = f.$1),
                  ),
              ]),
              const SizedBox(height: 12),
              if (_shown.isEmpty)
                const Padding(padding: EdgeInsets.all(30),
                    child: Center(child: Text('Nothing here yet.', style: TextStyle(color: AppTheme.textSecondary))))
              else
                for (var i = 0; i < _shown.length; i++) _tile(_shown[i], i == _shown.length - 1),
            ])),
        ]),
      ),
    );
  }

  Widget _tile(_Ev e, bool last) {
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 34,
          child: Column(children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(color: e.color.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(e.icon, size: 15, color: e.color),
            ),
            if (!last) Expanded(child: Container(width: 2, color: AppTheme.border)),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(child: Padding(
          padding: const EdgeInsets.only(bottom: 16, top: 3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(e.title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700))),
              if (e.ref != null && e.ref!.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(4), border: Border.all(color: AppTheme.border)),
                  child: Text(e.ref!, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600)),
                ),
            ]),
            const SizedBox(height: 2),
            Text('${_df.format(e.at)}${e.who == null || e.who!.isEmpty ? '' : '  ·  ${e.who}'}',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            if (e.sub != null && e.sub!.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(e.sub!, style: const TextStyle(fontSize: 12.5)),
            ],
            if (e.diffs.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final d in e.diffs)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: 120, child: Text(d.$1, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                        Expanded(child: Text.rich(TextSpan(children: [
                          TextSpan(text: d.$2, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, decoration: TextDecoration.lineThrough)),
                          const TextSpan(text: '  →  ', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                          TextSpan(text: d.$3, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                        ]))),
                      ]),
                    ),
                ]),
              ),
            ],
          ]),
        )),
      ]),
    );
  }

  Widget _chartCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Cost vs selling price', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          const Spacer(),
          _legend(Colors.indigo, 'Cost (purchases & cost price)'),
          const SizedBox(width: 12),
          _legend(Colors.green.shade700, 'Selling price'),
        ]),
        const SizedBox(height: 8),
        SizedBox(height: 150, child: CustomPaint(size: Size.infinite, painter: _PricePainter(_costPts, _sellPts, Colors.indigo, Colors.green.shade700))),
      ]),
    );
  }

  Widget _legend(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 14, height: 3, color: c),
        const SizedBox(width: 5),
        Text(t, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
      ]);
}

class _PricePainter extends CustomPainter {
  final List<(DateTime, double)> a, b;
  final Color ca, cb;
  _PricePainter(this.a, this.b, this.ca, this.cb);

  @override
  void paint(Canvas canvas, Size size) {
    final all = [...a, ...b];
    if (all.length < 2) return;
    final t0 = all.map((e) => e.$1.millisecondsSinceEpoch).reduce(math.min).toDouble();
    final t1 = all.map((e) => e.$1.millisecondsSinceEpoch).reduce(math.max).toDouble();
    var v0 = all.map((e) => e.$2).reduce(math.min);
    var v1 = all.map((e) => e.$2).reduce(math.max);
    if (v1 - v0 < 1e-9) { v0 -= 1; v1 += 1; }
    final pad = (v1 - v0) * 0.08;
    v0 -= pad; v1 += pad;
    const left = 52.0, bottom = 18.0;
    final w = size.width - left, h = size.height - bottom;
    double x(DateTime d) => left + (t1 == t0 ? w / 2 : (d.millisecondsSinceEpoch - t0) / (t1 - t0) * w);
    double y(double v) => h - (v - v0) / (v1 - v0) * h;

    final grid = Paint()..color = const Color(0xFFEEF1F6)..strokeWidth = 1;
    final tp = TextPainter(textDirection: ui.TextDirection.ltr);
    for (var i = 0; i <= 3; i++) {
      final v = v0 + (v1 - v0) * i / 3;
      final yy = y(v);
      canvas.drawLine(Offset(left, yy), Offset(size.width, yy), grid);
      tp.text = TextSpan(text: money(v), style: const TextStyle(fontSize: 9, color: Color(0xFF64748B)));
      tp.layout(maxWidth: left - 4);
      tp.paint(canvas, Offset(left - 4 - tp.width, yy - tp.height / 2));
    }
    final df = DateFormat('MMM yy');
    for (final d in [DateTime.fromMillisecondsSinceEpoch(t0.toInt()), DateTime.fromMillisecondsSinceEpoch(t1.toInt())]) {
      tp.text = TextSpan(text: df.format(d), style: const TextStyle(fontSize: 9, color: Color(0xFF64748B)));
      tp.layout();
      final xx = (x(d) - tp.width / 2).clamp(left, size.width - tp.width).toDouble();
      tp.paint(canvas, Offset(xx, h + 4));
    }

    void line(List<(DateTime, double)> pts, Color c) {
      if (pts.isEmpty) return;
      final paint = Paint()..color = c..strokeWidth = 2..style = PaintingStyle.stroke;
      final path = Path()..moveTo(x(pts.first.$1), y(pts.first.$2));
      for (var i = 1; i < pts.length; i++) {
        // step line: a price holds until the next change
        path.lineTo(x(pts[i].$1), y(pts[i - 1].$2));
        path.lineTo(x(pts[i].$1), y(pts[i].$2));
      }
      path.lineTo(left + w, y(pts.last.$2));
      canvas.drawPath(path, paint);
      final dot = Paint()..color = c;
      for (final p in pts) { canvas.drawCircle(Offset(x(p.$1), y(p.$2)), 2.4, dot); }
    }

    line(a, ca);
    line(b, cb);
  }

  @override
  bool shouldRepaint(covariant _PricePainter old) => old.a != a || old.b != b;
}
