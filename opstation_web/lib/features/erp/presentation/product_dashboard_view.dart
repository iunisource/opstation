import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/format/money.dart';
import '../../../core/storage/catalog_image_uploader.dart';
import '../../../core/theme/app_theme.dart';

/// Products ▸ Modern view. A product "dashboard": search list on the left,
/// the selected product's full profile on the right — picture, prices,
/// stock in every branch, purchase history (supplier / qty / price) or
/// production history (job runs + production vouchers), BOMs and where-used.
/// Read-only; editing still goes through the normal product form.
class ProductDashboardView extends StatefulWidget {
  const ProductDashboardView({
    super.key,
    required this.orgId,
    required this.products,
    required this.allProducts,
    required this.searchCtrl,
    required this.posProductIds,
    required this.filtersActive,
    required this.onClearFilters,
    required this.onEdit,
    required this.onPrintLabel,
    required this.onTimeline,
    required this.onReload,
  });

  final String orgId;
  final List<Map<String, dynamic>> products;     // filtered list (left panel)
  final List<Map<String, dynamic>> allProducts;  // for names in BOM tables
  final TextEditingController searchCtrl;
  final Set<String> posProductIds;
  final bool filtersActive;
  final VoidCallback onClearFilters;
  final void Function(Map<String, dynamic> p) onEdit;
  final void Function(Map<String, dynamic> p) onPrintLabel;
  final void Function(Map<String, dynamic> p) onTimeline;
  final Future<void> Function() onReload;

  @override
  State<ProductDashboardView> createState() => _ProductDashboardViewState();
}

class _ProductDashboardViewState extends State<ProductDashboardView> {
  String? _selId;
  bool _loading = false;
  String _tab = 'auto';
  final Map<String, String> _branchName = {};
  final Map<String, Map<String, dynamic>> _byId = {};

  // Loaded for the selected product
  List<Map<String, dynamic>> _stock = [];
  List<Map<String, dynamic>> _purchases = [];
  List<Map<String, dynamic>> _runs = [];
  List<Map<String, dynamic>> _vouchers = [];
  List<Map<String, dynamic>> _boms = [];
  final Map<String, List<Map<String, dynamic>>> _bomComps = {};
  List<Map<String, dynamic>> _usedIn = [];
  List<Map<String, dynamic>> _consumed = []; // issued to job runs / production vouchers
  double _sold90 = 0;

  SupabaseClient get _c => Supabase.instance.client;
  final _d = DateFormat('d MMM y');
  final _qf = NumberFormat('#,##0.##');

  @override
  void initState() {
    super.initState();
    _indexProducts();
    _loadBranches();
    widget.searchCtrl.addListener(_onSearch);
    if (widget.products.isNotEmpty) _select('${widget.products.first['id']}');
  }

  @override
  void didUpdateWidget(covariant ProductDashboardView old) {
    super.didUpdateWidget(old);
    _indexProducts();
  }

  @override
  void dispose() {
    widget.searchCtrl.removeListener(_onSearch);
    super.dispose();
  }

  void _onSearch() { if (mounted) setState(() {}); }

  void _indexProducts() {
    _byId.clear();
    for (final p in widget.allProducts) { _byId['${p['id']}'] = p; }
  }

  Map<String, dynamic>? get _sel => _selId == null ? null : _byId[_selId];

  String _pname(String? id) {
    final p = _byId[id];
    if (p == null) return id ?? '—';
    final sku = '${p['sku'] ?? ''}';
    return sku.isEmpty ? '${p['name'] ?? ''}' : '${p['name'] ?? ''}  ·  $sku';
  }

  String _q(dynamic v) => _qf.format((v as num?)?.toDouble() ?? double.tryParse('$v') ?? 0);
  String _date(dynamic v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '—' : _d.format(d.toLocal());
  }
  double _n(dynamic v) => (v as num?)?.toDouble() ?? double.tryParse('${v ?? ''}') ?? 0;

  Future<void> _loadBranches() async {
    try {
      final rows = await _c.from('branches').select('id, name').eq('org_id', widget.orgId);
      for (final b in rows as List) { _branchName['${b['id']}'] = '${b['name'] ?? ''}'; }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _select(String id) async {
    setState(() { _selId = id; _loading = true; _tab = 'auto'; });
    final org = widget.orgId;
    final stock = <Map<String, dynamic>>[];
    final purchases = <Map<String, dynamic>>[];
    final runs = <Map<String, dynamic>>[];
    final vouchers = <Map<String, dynamic>>[];
    final boms = <Map<String, dynamic>>[];
    final comps = <String, List<Map<String, dynamic>>>{};
    final usedIn = <Map<String, dynamic>>[];
    final consumed = <Map<String, dynamic>>[];
    double sold90 = 0;

    Future<void> loadStock() async {
      try {
        final r = await _c.from('inventory_stock').select('branch_id, quantity').eq('org_id', org).eq('product_id', id);
        stock.addAll(List<Map<String, dynamic>>.from(r as List));
      } catch (_) {}
    }

    Future<void> loadPurchases() async {
      try {
        // 1) Purchase invoices (priced).
        final items = List<Map<String, dynamic>>.from(await _c.from('purchase_invoice_items')
            .select('invoice_id, qty_received, unit_cost, discount, line_total').eq('product_id', id) as List);
        final invIds = {for (final i in items) '${i['invoice_id']}'}.toList();
        final invs = <String, Map<String, dynamic>>{};
        for (var k = 0; k < invIds.length; k += 150) {
          final rows = await _c.from('purchase_invoices')
              .select('id, voucher_number, voucher_date, supplier_id, branch_id, is_voided, is_locked, status, grn_id')
              .inFilter('id', invIds.sublist(k, (k + 150).clamp(0, invIds.length)));
          for (final r in rows as List) { invs['${r['id']}'] = Map<String, dynamic>.from(r as Map); }
        }
        // 2) GRNs received but not (yet) invoiced — e.g. consignment stock or a
        //    pending invoice. They moved stock, so they belong in the history.
        final grnItems = List<Map<String, dynamic>>.from(await _c.from('purchase_grn_items')
            .select('grn_id, qty_received, po_item_id').eq('product_id', id) as List);
        final grnIds = {for (final g in grnItems) '${g['grn_id']}'}.toList();
        final grns = <String, Map<String, dynamic>>{};
        final invoicedGrn = <String>{};
        for (var k = 0; k < grnIds.length; k += 150) {
          final part = grnIds.sublist(k, (k + 150).clamp(0, grnIds.length));
          final rows = await _c.from('purchase_grns')
              .select('id, voucher_number, voucher_date, supplier_id, branch_id, is_voided, status')
              .inFilter('id', part);
          for (final r in rows as List) { grns['${r['id']}'] = Map<String, dynamic>.from(r as Map); }
        }
        // A GRN line counts as invoiced only if an active invoice of that GRN
        // actually carries THIS product. (Consignment lines are left off the
        // invoice, so the GRN having an invoice is not enough.)
        for (final v in invs.values) {
          if (v['is_voided'] != true && v['grn_id'] != null) invoicedGrn.add('${v['grn_id']}');
        }
        final supIds = {
          for (final v in invs.values) if (v['supplier_id'] != null) '${v['supplier_id']}',
          for (final v in grns.values) if (v['supplier_id'] != null) '${v['supplier_id']}',
        }.toList();
        final sup = <String, String>{};
        if (supIds.isNotEmpty) {
          final rows = await _c.from('suppliers').select('id, name').inFilter('id', supIds);
          for (final r in rows as List) { sup['${r['id']}'] = '${r['name'] ?? ''}'; }
        }
        // GRN has no price of its own — fall back to the PO line's price.
        final poPrice = <String, double>{};
        final poIds = {for (final g in grnItems) if (g['po_item_id'] != null) '${g['po_item_id']}'}.toList();
        for (var k = 0; k < poIds.length; k += 150) {
          try {
            final rows = await _c.from('purchase_order_items').select('id, unit_cost')
                .inFilter('id', poIds.sublist(k, (k + 150).clamp(0, poIds.length)));
            for (final r in rows as List) { poPrice['${r['id']}'] = _n(r['unit_cost']); }
          } catch (_) {}
        }
        // Second fallback: the supplier's price list for this product.
        final listPrice = <String, double>{};
        if (grnItems.isNotEmpty) {
          try {
            final rows = await _c.from('supplier_price_list').select('supplier_id, price').eq('org_id', org).eq('product_id', id);
            for (final r in rows as List) { listPrice['${r['supplier_id']}'] = _n(r['price']); }
          } catch (_) {}
        }
        for (final g in grnItems) {
          final grn = grns['${g['grn_id']}'];
          if (grn == null || grn['is_voided'] == true || invoicedGrn.contains('${grn['id']}')) continue;
          final qty = _n(g['qty_received']);
          if (qty <= 0) continue;
          purchases.add({
            'date': grn['voucher_date'], 'number': grn['voucher_number'],
            'supplier': sup['${grn['supplier_id']}'] ?? '—',
            'branch': _branchName['${grn['branch_id']}'] ?? '',
            'qty': qty, 'grn': true, 'posted': '${grn['status'] ?? ''}' != 'draft',
            ...() {
              final po = poPrice['${g['po_item_id']}'] ?? 0;
              final lp = listPrice['${grn['supplier_id']}'] ?? 0;
              final u = po > 0 ? po : lp;
              return {'unit': u, 'net': u, 'total': u * qty,
                      'psrc': po > 0 ? 'PO' : (lp > 0 ? 'price list' : (g['po_item_id'] == null ? 'no PO' : 'PO has no price'))};
            }(),
          });
        }
        for (final i in items) {
          final inv = invs['${i['invoice_id']}'];
          if (inv == null || inv['is_voided'] == true) continue;
          final qty = _n(i['qty_received']);
          final total = _n(i['line_total']);
          purchases.add({
            'date': inv['voucher_date'], 'number': inv['voucher_number'],
            'supplier': sup['${inv['supplier_id']}'] ?? '—',
            'branch': _branchName['${inv['branch_id']}'] ?? '',
            'qty': qty, 'unit': _n(i['unit_cost']), 'disc': _n(i['discount']),
            'net': qty > 0 ? total / qty : _n(i['unit_cost']), 'total': total,
            'posted': inv['is_locked'] == true,
          });
        }
        purchases.sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
      } catch (_) {}
    }

    Future<void> loadProduction() async {
      try {
        final jobs = List<Map<String, dynamic>>.from(await _c.from('job_cards').select().eq('product_id', id) as List);
        if (jobs.isNotEmpty) {
          final jobNo = {for (final j in jobs) '${j['id']}': '${j['job_number'] ?? ''}'};
          final r = await _c.from('job_card_runs').select().inFilter('job_card_id', jobNo.keys.toList());
          for (final x in r as List) {
            final m = Map<String, dynamic>.from(x as Map);
            m['_job'] = jobNo['${m['job_card_id']}'] ?? '';
            runs.add(m);
          }
          runs.sort((a, b) => '${b['run_date'] ?? b['created_at']}'.compareTo('${a['run_date'] ?? a['created_at']}'));
        }
      } catch (_) {}
      try {
        final r = await _c.from('production_vouchers').select().eq('product_id', id);
        vouchers.addAll(List<Map<String, dynamic>>.from(r as List).where((v) => v['is_voided'] != true));
        vouchers.sort((a, b) => '${b['voucher_date'] ?? b['created_at']}'.compareTo('${a['voucher_date'] ?? a['created_at']}'));
      } catch (_) {}
    }

    Future<void> loadBoms() async {
      try {
        final r = await _c.from('bom_headers').select().eq('org_id', org).eq('product_id', id);
        boms.addAll(List<Map<String, dynamic>>.from(r as List).where((b) => b['is_voided'] != true));
        if (boms.isNotEmpty) {
          final cr = await _c.from('bom_components').select('bom_id, product_id, quantity, line_order')
              .inFilter('bom_id', [for (final b in boms) '${b['id']}']);
          for (final x in cr as List) { (comps['${x['bom_id']}'] ??= []).add(Map<String, dynamic>.from(x as Map)); }
          for (final l in comps.values) { l.sort((a, b) => _n(a['line_order']).compareTo(_n(b['line_order']))); }
        }
      } catch (_) {}
      try {
        final cr = List<Map<String, dynamic>>.from(await _c.from('bom_components').select('bom_id, quantity').eq('product_id', id) as List);
        if (cr.isNotEmpty) {
          final qtyBy = {for (final x in cr) '${x['bom_id']}': x['quantity']};
          final hs = await _c.from('bom_headers').select('id, code, name, product_id, status, output_qty').inFilter('id', qtyBy.keys.toList());
          for (final h in hs as List) {
            final m = Map<String, dynamic>.from(h as Map);
            m['_qty'] = qtyBy['${m['id']}'];
            usedIn.add(m);
          }
        }
      } catch (_) {}
    }

    // Where this item was actually CONSUMED (as a material) — from stock movements.
    Future<void> loadConsumed() async {
      try {
        final mv = List<Map<String, dynamic>>.from(await _c.from('inventory_movements')
            .select('quantity, moved_at, reference_id, reference_type, branch_id')
            .eq('org_id', org).eq('product_id', id).lt('quantity', 0)
            .inFilter('reference_type', ['job_run', 'production_voucher'])
            .order('moved_at', ascending: false).limit(1000) as List);
        if (mv.isEmpty) return;
        final runIds = {for (final m in mv) if (m['reference_type'] == 'job_run') '${m['reference_id']}'}.toList();
        final pvIds = {for (final m in mv) if (m['reference_type'] == 'production_voucher') '${m['reference_id']}'}.toList();
        final label = <String, String>{};
        final makes = <String, String?>{};
        final produced = <String, dynamic>{};
        for (var k = 0; k < runIds.length; k += 150) {
          final rows = await _c.from('job_card_runs').select('id, run_no, produced_qty, job_cards(job_number, product_id)')
              .inFilter('id', runIds.sublist(k, (k + 150).clamp(0, runIds.length)));
          for (final r in rows as List) {
            final jc = r['job_cards'];
            label['${r['id']}'] = '${jc is Map ? jc['job_number'] ?? 'JOB' : 'JOB'}-R${r['run_no'] ?? ''}';
            makes['${r['id']}'] = jc is Map ? jc['product_id'] as String? : null;
            produced['${r['id']}'] = r['produced_qty'];
          }
        }
        for (var k = 0; k < pvIds.length; k += 150) {
          final rows = await _c.from('production_vouchers').select('id, voucher_number, product_id, output_qty')
              .inFilter('id', pvIds.sublist(k, (k + 150).clamp(0, pvIds.length)));
          for (final r in rows as List) {
            label['${r['id']}'] = '${r['voucher_number'] ?? ''}';
            makes['${r['id']}'] = r['product_id'] as String?;
            produced['${r['id']}'] = r['output_qty'];
          }
        }
        for (final m in mv) {
          final ref = '${m['reference_id']}';
          consumed.add({
            'date': m['moved_at'], 'doc': label[ref] ?? ref, 'makes': makes[ref], 'produced': produced[ref],
            'qty': -_n(m['quantity']), 'branch': m['branch_id'],
          });
        }
      } catch (_) {}
    }

    Future<void> loadSold() async {
      try {
        final since = DateTime.now().subtract(const Duration(days: 90)).toUtc().toIso8601String();
        final r = await _c.from('inventory_movements').select('quantity')
            .eq('org_id', org).eq('product_id', id).eq('movement_type', 'sale').gte('moved_at', since);
        for (final x in r as List) { sold90 += -_n(x['quantity']); }
      } catch (_) {}
    }

    await Future.wait([loadStock(), loadPurchases(), loadProduction(), loadBoms(), loadSold(), loadConsumed()]);
    if (!mounted || _selId != id) return;
    setState(() {
      _stock = stock;
      _purchases = purchases;
      _runs = runs;
      _vouchers = vouchers;
      _boms = boms;
      _bomComps..clear()..addAll(comps);
      _usedIn = usedIn;
      _consumed = consumed;
      _sold90 = sold90;
      _loading = false;
    });
  }

  Future<void> _changePhoto(Map<String, dynamic> p) async {
    try {
      final url = await CatalogImageUploader.pickAndUpload(orgId: widget.orgId, folder: 'products', keyHint: '${p['id']}');
      if (url == null) return;
      await _c.from('products').update({'image_url': url}).eq('id', '${p['id']}');
      await widget.onReload();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    if (!wide) {
      // Phone / narrow: list first; picking a product opens its profile.
      if (_sel == null) return _listPanel(full: true);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextButton.icon(onPressed: () => setState(() => _selId = null), icon: const Icon(Icons.arrow_back, size: 18), label: const Text('All products')),
        Expanded(child: _profile(narrow: true)),
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 300, child: _listPanel()),
      const SizedBox(width: 16),
      Expanded(child: _sel == null
          ? const Center(child: Text('Pick a product on the left', style: TextStyle(color: AppTheme.textSecondary)))
          : _profile()),
    ]);
  }

  Widget _thumb(Map<String, dynamic> p, double size, {double radius = 8}) {
    final url = p['image_url'] as String?;
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(radius), border: Border.all(color: AppTheme.border)),
      clipBehavior: Clip.antiAlias,
      child: url == null || url.isEmpty
          ? Icon(Icons.inventory_2_outlined, size: size * 0.42, color: const Color(0xFF94A3B8))
          : Image.network(url, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Icon(Icons.broken_image_outlined, size: size * 0.4, color: const Color(0xFF94A3B8))),
    );
  }

  Widget _listPanel({bool full = false}) {
    final list = widget.products;
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: TextField(
            controller: widget.searchCtrl,
            decoration: const InputDecoration(hintText: 'Search name, SKU, barcode…', prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 4),
          child: Row(children: [
            Text('${list.length} products', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            const Spacer(),
            if (widget.filtersActive)
              TextButton(onPressed: widget.onClearFilters, style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: const Text('Clear filters', style: TextStyle(fontSize: 11.5))),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: list.isEmpty
            ? const Center(child: Text('No products', style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.builder(
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final p = list[i];
                  final id = '${p['id']}';
                  final on = id == _selId;
                  final inactive = p['is_active'] == false;
                  return InkWell(
                    onTap: () => _select(id),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: on ? AppTheme.primary.withValues(alpha: 0.08) : null,
                        border: Border(left: BorderSide(color: on ? AppTheme.primary : Colors.transparent, width: 3)),
                      ),
                      child: Row(children: [
                        _thumb(p, 36, radius: 6),
                        const SizedBox(width: 10),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${p['name'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                                  color: inactive ? AppTheme.textSecondary : AppTheme.textPrimary,
                                  decoration: inactive ? TextDecoration.lineThrough : null)),
                          Text([p['sku'], p['product_group']].where((x) => x != null && '$x'.isNotEmpty).join(' · '),
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
                        ])),
                      ]),
                    ),
                  );
                },
              )),
      ]),
    );
  }

  // ── Profile ────────────────────────────────────────────────────────────
  Widget _card({required Widget child, EdgeInsets padding = const EdgeInsets.all(16)}) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
        child: child,
      );

  Widget _chip(String t, {Color c = AppTheme.textSecondary, IconData? icon}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20), border: Border.all(color: c.withValues(alpha: 0.30))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 12, color: c), const SizedBox(width: 4)],
          Text(t, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
        ]),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 108, child: Text(k, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          Expanded(child: Text(v.isEmpty ? '—' : v, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
        ]),
      );

  Widget _tile(String label, String value, {Color color = AppTheme.textPrimary, String? sub}) => Container(
        width: 150,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
          if (sub != null) Text(sub, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
        ]),
      );

  Widget _profile({bool narrow = false}) {
    final p = _sel!;
    final sell = _n(p['selling_price']);
    final cost = _n(p['cost_price']);
    // No cost price → margin is unknown, not 100%.
    final margin = sell > 0 && cost > 0 ? (sell - cost) / sell * 100 : null;
    final totalStock = _stock.fold<double>(0, (s, r) => s + _n(r['quantity']));
    final low = _n(p['low_stock_limit']);
    final uom = (p['uoms'] is Map) ? '${p['uoms']['abbreviation'] ?? p['uoms']['name'] ?? ''}' : '';

    final header = _card(child: Wrap(spacing: 20, runSpacing: 16, crossAxisAlignment: WrapCrossAlignment.start, children: [
      Column(children: [
        _thumb(p, narrow ? 140 : 210, radius: 14),
        const SizedBox(height: 6),
        TextButton.icon(onPressed: () => _changePhoto(p), icon: const Icon(Icons.photo_camera_outlined, size: 16),
            label: Text(p['image_url'] == null ? 'Add photo' : 'Change photo', style: const TextStyle(fontSize: 12))),
      ]),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: narrow ? 560 : 520, minWidth: 260),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${p['name'] ?? ''}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppTheme.primaryDark, height: 1.2)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (p['is_active'] == false) _chip('Inactive', c: AppTheme.danger, icon: Icons.block)
            else _chip('Active', c: AppTheme.success, icon: Icons.check_circle_outline),
            if (widget.posProductIds.contains(p['id'])) _chip('In POS', c: AppTheme.primary, icon: Icons.point_of_sale),
            if (p['supervised_at'] == null) _chip('Supervision pending', c: AppTheme.warning, icon: Icons.hourglass_empty),
            if (p['is_service'] == true) _chip('Service', c: Colors.purple),
            if (p['is_consignment'] == true) _chip('Consignment', c: Colors.teal),
            if (_boms.isNotEmpty) _chip('Manufactured', c: Colors.indigo, icon: Icons.precision_manufacturing_outlined),
          ]),
          const SizedBox(height: 14),
          _kv('SKU', '${p['sku'] ?? ''}'),
          _kv('Barcode', '${p['barcode'] ?? ''}'),
          _kv('Unit', uom),
          _kv('Type', '${p['product_type'] ?? ''}'),
          _kv('Classification', [p['product_main_group'], p['product_group'], p['product_sub_group']]
              .where((x) => x != null && '$x'.isNotEmpty).join('  ›  ')),
          _kv('Class / Movement', [p['product_class'], p['product_movement_category']].where((x) => x != null && '$x'.isNotEmpty).join(' · ')),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ElevatedButton.icon(onPressed: () => widget.onEdit(p), icon: const Icon(Icons.edit_outlined, size: 16), label: const Text('Edit')),
            OutlinedButton.icon(onPressed: () => widget.onPrintLabel(p), icon: const Icon(Icons.qr_code_2, size: 16), label: const Text('Print label')),
            OutlinedButton.icon(onPressed: () => widget.onTimeline(p), icon: const Icon(Icons.timeline, size: 16), label: const Text('Change history')),
          ]),
        ]),
      ),
    ]));

    final tiles = Wrap(spacing: 10, runSpacing: 10, children: [
      _tile('Sell price', money(sell)),
      _tile('Cost price', money(cost)),
      _tile('Margin', margin == null ? '—' : '${margin.toStringAsFixed(1)}%', sub: cost <= 0 ? 'no cost price' : null,
          color: margin == null ? AppTheme.textPrimary : (margin < 0 ? AppTheme.danger : AppTheme.success)),
      _tile('On hand', _q(totalStock), sub: uom.isEmpty ? null : uom,
          color: low > 0 && totalStock <= low ? AppTheme.danger : AppTheme.textPrimary),
      _tile('Stock value', cost > 0 ? money(totalStock * cost) : '—', sub: cost > 0 ? 'at cost' : 'no cost price'),
      _tile('Sold (90 days)', _q(_sold90), sub: uom.isEmpty ? null : uom),
    ]);

    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      header,
      const SizedBox(height: 12),
      tiles,
      const SizedBox(height: 12),
      if (_loading)
        const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
      else ...[
        _stockCard(p, totalStock, low, uom),
        const SizedBox(height: 12),
        _historyCard(),
        const SizedBox(height: 24),
      ],
    ]));
  }

  Widget _sectionTitle(IconData icon, String t, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Container(width: 28, height: 28, alignment: Alignment.center,
              decoration: BoxDecoration(color: AppTheme.primary.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 16, color: AppTheme.primary)),
          const SizedBox(width: 8),
          Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (trailing != null) trailing,
        ]),
      );

  Widget _stockCard(Map<String, dynamic> p, double total, double low, String uom) {
    final rows = [..._stock]..sort((a, b) => _n(b['quantity']).compareTo(_n(a['quantity'])));
    final maxQ = rows.isEmpty ? 1.0 : rows.map((r) => _n(r['quantity']).abs()).fold<double>(1, (a, b) => a > b ? a : b);
    return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(Icons.warehouse_outlined, 'Stock levels',
          trailing: low > 0 ? Text('Low-stock limit: ${_q(low)}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)) : null),
      if (rows.isEmpty)
        const Text('No stock in any branch.', style: TextStyle(color: AppTheme.textSecondary))
      else
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              SizedBox(width: 190, child: Text(_branchName['${r['branch_id']}'] ?? '${r['branch_id']}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
              Expanded(child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (_n(r['quantity']).abs() / maxQ).clamp(0.0, 1.0),
                  minHeight: 10,
                  backgroundColor: const Color(0xFFF1F5F9),
                  color: _n(r['quantity']) < 0 ? AppTheme.danger : AppTheme.primary,
                ),
              )),
              SizedBox(width: 110, child: Text('${_q(r['quantity'])} ${uom}'.trim(), textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _n(r['quantity']) < 0 ? AppTheme.danger : AppTheme.textPrimary))),
            ]),
          ),
      if (rows.length > 1) ...[
        const Divider(),
        Row(children: [
          const Text('Total', style: TextStyle(fontWeight: FontWeight.w800)),
          const Spacer(),
          Text('${_q(total)} $uom'.trim(), style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      ],
    ]));
  }

  Widget _historyCard() {
    final produced = _runs.isNotEmpty || _vouchers.isNotEmpty;
    final purchased = _purchases.isNotEmpty;
    var tab = _tab;
    if (tab == 'auto') tab = produced && !purchased ? 'production' : (purchased ? 'purchases' : (_boms.isNotEmpty ? 'bom' : 'purchases'));
    final tabs = <(String, String, int)>[
      ('purchases', 'Purchases', _purchases.length),
      ('production', 'Production', _runs.length + _vouchers.length),
      ('bom', 'BOM', _boms.length),
      ('used', 'Used in', _usedIn.length + _consumed.length),
    ];
    return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final t in tabs)
          ChoiceChip(
            label: Text('${t.$2}${t.$3 > 0 ? '  (${t.$3})' : ''}'),
            selected: tab == t.$1,
            onSelected: (_) => setState(() => _tab = t.$1),
          ),
      ]),
      const SizedBox(height: 14),
      if (tab == 'purchases') _purchasesView()
      else if (tab == 'production') _productionView()
      else if (tab == 'bom') _bomView()
      else _usedInView(),
    ]));
  }

  Widget _table(List<String> head, List<List<String>> rows, {Set<int> right = const {}, List<int>? flex}) {
    final f = flex ?? List.filled(head.length, 1);
    Widget cell(String t, int i, {bool h = false}) => Expanded(
          flex: f[i],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Text(t, textAlign: right.contains(i) ? TextAlign.right : TextAlign.left,
                style: TextStyle(fontSize: h ? 11.5 : 12.5, fontWeight: h ? FontWeight.w800 : FontWeight.w500,
                    color: h ? AppTheme.textSecondary : AppTheme.textPrimary)),
          ),
        );
    return Container(
      decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        Container(color: AppTheme.background, child: Row(children: [for (var i = 0; i < head.length; i++) cell(head[i], i, h: true)])),
        for (var r = 0; r < rows.length; r++)
          Container(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFF1F5F9)))),
            child: Row(children: [for (var i = 0; i < rows[r].length; i++) cell(rows[r][i], i)]),
          ),
      ]),
    );
  }

  Widget _empty(String t) => Padding(padding: const EdgeInsets.symmetric(vertical: 18), child: Text(t, style: const TextStyle(color: AppTheme.textSecondary)));

  Widget _purchasesView() {
    if (_purchases.isEmpty) return _empty('No purchases or goods received for this product.');
    final invoiced = _purchases.where((r) => r['grn'] != true).toList();
    // Invoices give the true price; if there are none, fall back to GRNs at PO price.
    final grnPriced = _purchases.where((r) => r['grn'] == true && _n(r['unit']) > 0).toList();
    final usingGrn = invoiced.isEmpty && grnPriced.isNotEmpty;
    final priced = usingGrn ? grnPriced : invoiced;
    final unInvoiced = _purchases.where((r) => r['grn'] == true).toList();
    final qty = _purchases.fold<double>(0, (s, r) => s + _n(r['qty']));
    final pQty = priced.fold<double>(0, (s, r) => s + _n(r['qty']));
    final amt = priced.fold<double>(0, (s, r) => s + _n(r['total']));
    final last = priced.isEmpty ? null : priced.first;
    final bySup = <String, double>{};
    for (final r in _purchases) { bySup['${r['supplier']}'] = (bySup['${r['supplier']}'] ?? 0) + _n(r['qty']); }
    final top = (bySup.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first;
    final nets = priced.map((r) => _n(r['net'])).where((v) => v > 0).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 10, runSpacing: 10, children: [
        if (last != null) _tile('Last price', money(_n(last['net'])), sub: '${_date(last['date'])} · ${last['supplier']}${usingGrn ? ' · ${last['psrc']}' : ''}'),
        if (pQty > 0) _tile('Average price', money(amt / pQty), sub: usingGrn ? 'from GRNs (PO / price list)' : 'weighted'),
        if (nets.isNotEmpty) _tile('Lowest / Highest', '${money(nets.reduce((a, b) => a < b ? a : b))} / ${money(nets.reduce((a, b) => a > b ? a : b))}'),
        _tile('Total received', _q(qty), sub: '${invoiced.length} invoice${invoiced.length == 1 ? '' : 's'}${unInvoiced.isEmpty ? '' : ' · ${unInvoiced.length} GRN not invoiced'}'),
        _tile('Main supplier', top.key, sub: '${_q(top.value)} units'),
      ]),
      if (unInvoiced.isNotEmpty) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFFCD34D))),
          child: Text(
            '${_q(unInvoiced.fold<double>(0, (s, r) => s + _n(r['qty'])))} received on GRN without a purchase invoice yet'
            '${_sel?['is_consignment'] == true ? ' (consignment stock — invoiced later)' : ''}. Until invoiced, their price comes from the PO, else the supplier price list.',
            style: const TextStyle(fontSize: 12, color: Color(0xFF92400E), fontWeight: FontWeight.w600)),
        ),
      ],
      const SizedBox(height: 12),
      _table(
        ['Date', 'Document', 'Supplier', 'Qty', 'Unit cost', 'Disc', 'Net price', 'Amount'],
        [
          for (final r in _purchases)
            r['grn'] == true
                ? [_date(r['date']), '${r['number'] ?? ''} · GRN, not invoiced${r['posted'] == true ? '' : ' (draft)'}', '${r['supplier']}',
                   _q(r['qty']),
                   _n(r['unit']) > 0 ? '${money(_n(r['unit']))} (${r['psrc']})' : '— (${r['psrc']})', '—',
                   _n(r['net']) > 0 ? money(_n(r['net'])) : '—',
                   _n(r['total']) > 0 ? money(_n(r['total'])) : '—']
                : [_date(r['date']), '${r['number'] ?? ''}${r['posted'] == true ? '' : ' (draft)'}', '${r['supplier']}',
                   _q(r['qty']), money(_n(r['unit'])), _n(r['disc']) == 0 ? '—' : _q(r['disc']), money(_n(r['net'])), money(_n(r['total']))],
        ],
        right: {3, 4, 5, 6, 7},
        flex: [3, 3, 5, 2, 3, 2, 3, 3],
      ),
    ]);
  }

  Widget _productionView() {
    if (_runs.isEmpty && _vouchers.isEmpty) return _empty('No job runs or production vouchers for this product.');
    final produced = _runs.fold<double>(0, (s, r) => s + _n(r['produced_qty'])) + _vouchers.fold<double>(0, (s, v) => s + _n(v['output_qty']));
    final rejected = _runs.fold<double>(0, (s, r) => s + _n(r['rejected_qty']));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 10, runSpacing: 10, children: [
        _tile('Total produced', _q(produced)),
        if (_runs.isNotEmpty) _tile('Rejected', _q(rejected), color: rejected > 0 ? AppTheme.danger : AppTheme.textPrimary,
            sub: produced + rejected > 0 ? '${(rejected / (produced + rejected) * 100).toStringAsFixed(1)}% of output' : null),
        _tile('Job runs', '${_runs.length}'),
        _tile('Production vouchers', '${_vouchers.length}'),
      ]),
      if (_runs.isNotEmpty) ...[
        const SizedBox(height: 14),
        const Text('Job runs', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        const SizedBox(height: 6),
        _table(
          ['Date', 'Job / Run', 'Produced', 'Rejected', 'Status'],
          [
            for (final r in _runs)
              [_date(r['run_date'] ?? r['created_at']), '${r['_job']}-R${r['run_no'] ?? ''}', _q(r['produced_qty']),
               _q(r['rejected_qty']), '${r['status'] ?? '—'}'],
          ],
          right: {2, 3},
          flex: [3, 4, 2, 2, 2],
        ),
      ],
      if (_vouchers.isNotEmpty) ...[
        const SizedBox(height: 14),
        const Text('Production vouchers', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        const SizedBox(height: 6),
        _table(
          ['Date', 'Voucher', 'Output qty', 'Total cost', 'Unit cost', 'Status'],
          [
            for (final v in _vouchers)
              [_date(v['voucher_date'] ?? v['created_at']), '${v['voucher_number'] ?? ''}', _q(v['output_qty']),
               money(_n(v['total_cost'])), _n(v['output_qty']) > 0 ? money(_n(v['total_cost']) / _n(v['output_qty'])) : '—', '${v['status'] ?? '—'}'],
          ],
          right: {2, 3, 4},
          flex: [3, 3, 2, 3, 3, 2],
        ),
      ],
    ]);
  }

  Widget _bomView() {
    if (_boms.isEmpty) return _empty('This product has no BOM.');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final b in _boms) ...[
        Row(children: [
          Text('${b['code'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, color: AppTheme.primary)),
          const SizedBox(width: 8),
          Expanded(child: Text('${b['name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          _chip('${b['status'] ?? 'draft'}', c: '${b['status']}' == 'active' ? AppTheme.success : AppTheme.textSecondary),
          const SizedBox(width: 6),
          if (b['supervised_at'] != null) _chip('Supervised', c: AppTheme.success, icon: Icons.verified_outlined)
          else if (b['rejected_at'] != null) _chip('Rejected', c: AppTheme.danger)
          else _chip('Pending', c: AppTheme.warning),
        ]),
        const SizedBox(height: 4),
        Text('Makes ${_q(b['output_qty'] ?? 1)} unit(s). Components:', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        _table(
          ['Component', 'Qty'],
          [for (final c in _bomComps['${b['id']}'] ?? const <Map<String, dynamic>>[]) [_pname('${c['product_id']}'), _q(c['quantity'])]],
          right: {1},
          flex: [6, 1],
        ),
        const SizedBox(height: 16),
      ],
    ]);
  }

  Widget _usedInView() {
    if (_usedIn.isEmpty && _consumed.isEmpty) return _empty('Not used as a component in any BOM, and never consumed in production.');
    final total = _consumed.fold<double>(0, (s, r) => s + _n(r['qty']));
    final last = _consumed.isEmpty ? null : _consumed.first;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_consumed.isNotEmpty) ...[
        Wrap(spacing: 10, runSpacing: 10, children: [
          _tile('Consumed', _q(total), sub: 'in ${_consumed.length} run${_consumed.length == 1 ? '' : 's'} / voucher${_consumed.length == 1 ? '' : 's'}'),
          if (last != null) _tile('Last used', _date(last['date']), sub: '${last['doc']}'),
        ]),
        const SizedBox(height: 12),
        const Text('Consumed in production', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        const SizedBox(height: 6),
        _table(
          ['Date', 'Job run / Voucher', 'Making', 'Output', 'Qty used'],
          [
            for (final r in _consumed)
              [_date(r['date']), '${r['doc']}', r['makes'] == null ? '—' : _pname('${r['makes']}'),
               r['produced'] == null ? '—' : _q(r['produced']), _q(r['qty'])],
          ],
          right: {3, 4},
          flex: [3, 3, 6, 2, 2],
        ),
        const SizedBox(height: 16),
      ],
      const Text('BOMs that use it', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
      const SizedBox(height: 6),
      if (_usedIn.isEmpty)
        _empty('Not a component in any BOM.')
      else
        _table(
          ['BOM', 'Makes', 'Qty per output', 'Status'],
          [for (final b in _usedIn) ['${b['code'] ?? ''}', _pname('${b['product_id']}'), _q(b['_qty']), '${b['status'] ?? '—'}']],
          right: {2},
          flex: [2, 6, 2, 2],
        ),
    ]);
  }
}
