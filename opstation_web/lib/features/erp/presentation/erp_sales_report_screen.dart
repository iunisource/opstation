import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Sales Report — all sales in a date range, from Sales Invoices and/or POS,
/// filterable by customer Category and Group, broken down Product-wise or
/// Customer-wise, with a post-load search and PDF/print.
class ErpSalesReportScreen extends ConsumerStatefulWidget {
  const ErpSalesReportScreen({super.key});
  @override
  ConsumerState<ErpSalesReportScreen> createState() => _ErpSalesReportScreenState();
}

class _ErpSalesReportScreenState extends ConsumerState<ErpSalesReportScreen> {
  bool _loading = true;
  bool _running = false;
  bool _ran = false;
  String? _orgId;

  // reference data
  final Map<String, Map<String, dynamic>> _customers = {}; // id -> row
  final Map<String, String> _productNames = {};
  final Map<String, Map<String, String>> _productGroups = {}; // id -> {mg, g, sg}
  final Map<String, String> _posCustomerNames = {};
  final Map<String, String> _sessionBranch = {}; // pos session -> branch_id
  List<Map<String, dynamic>> _branches = [];
  List<Map<String, dynamic>> _routes = []; // {id, name} for the Route filter
  final Map<String, Set<String>> _custRoutes = {}; // customer id -> route ids
  List<String> _categories = [];
  List<String> _groups = [];
  List<String> _mainGroupOpts = [];
  List<String> _prodGroupOpts = [];
  List<String> _subGroupOpts = [];
  // Cascading: the group hierarchy isn't stored as parent→child anywhere, so we
  // learn it from the products themselves — which (main, group, sub) values
  // actually co-occur. Selecting a main group then narrows the group/sub lists.
  final Map<String, Set<String>> _mainToGroups = {};
  final Map<String, Set<String>> _mainToSubs = {};
  final Map<String, Set<String>> _groupToSubs = {};

  // filters
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _to = DateTime.now();
  String _source = 'both'; // both | invoice | pos
  String _branch = 'all';
  String _route = 'all';
  String _category = 'all';
  String _group = 'all';
  String _breakdown = 'product'; // product | customer
  // Collapse the filter card after a run so results get the vertical space.
  bool _filtersCollapsed = false;
  // Product-side filters (multi-select; empty set = all). Behind "More filters".
  bool _moreFilters = false;
  final Set<String> _fMainGroups = {};
  final Set<String> _fProdGroups = {};
  final Set<String> _fSubGroups = {};

  // result
  List<Map<String, dynamic>> _rows = [];
  Map<String, List<Map<String, dynamic>>> _children = {};
  final Set<String> _expanded = {};
  double _grandAmount = 0;
  double _grandQty = 0;
  int _docCount = 0;
  final _searchCtrl = TextEditingController();

  final _money = NumberFormat('#,##0');
  final _qtyFmt = NumberFormat('#,##0.##');

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
    _loadRefs();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  double _d(dynamic v) => v == null ? 0.0 : (v as num).toDouble();

  Future<void> _loadRefs() async {
    setState(() => _loading = true);
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    _orgId = orgId;
    try {
      final c = Supabase.instance.client;
      // Paginate so orgs with >1000 customers load their full roster (a single
      // fetch is capped at 1000), otherwise many customers show as "(customer)".
      final custs = <Map<String, dynamic>>[];
      for (int from = 0;; from += 1000) {
        final page = await c
            .from('customers')
            .select('id, shop_name, code, category, group_name')
            .eq('org_id', orgId)
            .range(from, from + 999);
        custs.addAll(List<Map<String, dynamic>>.from(page as List));
        if ((page).length < 1000 || from > 200000) break;
      }
      final prods = await c.from('products')
          .select('id, name, product_main_group, product_group, product_sub_group')
          .eq('org_id', orgId);
      final branches = await c
          .from('branches')
          .select('id, name')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');

      // Routes (markets) + which customers sit on each, for the Route filter.
      List<Map<String, dynamic>> routes = [];
      _custRoutes.clear();
      try {
        routes = List<Map<String, dynamic>>.from(
            await c.from('sales_routes').select('id, name').eq('org_id', orgId).order('name'));
        final rids = [for (final r in routes) r['id'] as String];
        if (rids.isNotEmpty) {
          final stops = await c.from('route_stops')
              .select('route_id, customer_id').inFilter('route_id', rids);
          for (final s in stops as List) {
            final cid = s['customer_id'] as String?;
            final rid = s['route_id'] as String?;
            if (cid != null && rid != null) (_custRoutes[cid] ??= {}).add(rid);
          }
        }
      } catch (_) {/* routes are best-effort */}

      final cats = <String>{};
      final grps = <String>{};
      _customers.clear();
      for (final r in custs) {
        _customers[r['id'] as String] = Map<String, dynamic>.from(r);
        final cat = (r['category'] as String?)?.trim();
        final grp = (r['group_name'] as String?)?.trim();
        if (cat != null && cat.isNotEmpty) cats.add(cat);
        if (grp != null && grp.isNotEmpty) grps.add(grp);
      }
      _productNames
        ..clear()
        ..addEntries(prods.map((p) => MapEntry(p['id'] as String, '${p['name']}')));
      // Product group hierarchy values, for the "More filters" pickers.
      final mgs = <String>{}, pgs = <String>{}, sgs = <String>{};
      _productGroups.clear();
      _mainToGroups.clear();
      _mainToSubs.clear();
      _groupToSubs.clear();
      for (final p in prods) {
        final mg = (p['product_main_group'] as String?)?.trim() ?? '';
        final pg = (p['product_group'] as String?)?.trim() ?? '';
        final sg = (p['product_sub_group'] as String?)?.trim() ?? '';
        _productGroups[p['id'] as String] = {'mg': mg, 'g': pg, 'sg': sg};
        if (mg.isNotEmpty) mgs.add(mg);
        if (pg.isNotEmpty) pgs.add(pg);
        if (sg.isNotEmpty) sgs.add(sg);
        if (mg.isNotEmpty && pg.isNotEmpty) (_mainToGroups[mg] ??= {}).add(pg);
        if (mg.isNotEmpty && sg.isNotEmpty) (_mainToSubs[mg] ??= {}).add(sg);
        if (pg.isNotEmpty && sg.isNotEmpty) (_groupToSubs[pg] ??= {}).add(sg);
      }

      // best-effort POS extras (walk-in customer names + session->branch)
      try {
        final pc = await c.from('pos_customers').select('id, name').eq('org_id', orgId);
        _posCustomerNames
          ..clear()
          ..addEntries(pc.map((p) => MapEntry(p['id'] as String, '${p['name']}')));
      } catch (_) {}
      try {
        final ss = await c.from('pos_sessions').select('id, branch_id').eq('org_id', orgId);
        _sessionBranch
          ..clear()
          ..addEntries(ss
              .where((s) => s['branch_id'] != null)
              .map((s) => MapEntry(s['id'] as String, s['branch_id'] as String)));
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _branches = List<Map<String, dynamic>>.from(branches);
        _routes = routes;
        _categories = cats.toList()..sort();
        _groups = grps.toList()..sort();
        _mainGroupOpts = mgs.toList()..sort();
        _prodGroupOpts = pgs.toList()..sort();
        _subGroupOpts = sgs.toList()..sort();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Load failed: $e');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  bool get _productFilterActive =>
      _fMainGroups.isNotEmpty || _fProdGroups.isNotEmpty || _fSubGroups.isNotEmpty;

  // Cascading choices: Product Group narrows to what co-occurs with the selected
  // Main Group(s); Sub Group narrows to what co-occurs with the selected Main
  // Group(s) AND Group(s). Empty parent selection = show everything.
  List<String> get _prodGroupChoices {
    if (_fMainGroups.isEmpty) return _prodGroupOpts;
    final allowed = <String>{};
    for (final mg in _fMainGroups) allowed.addAll(_mainToGroups[mg] ?? const {});
    return _prodGroupOpts.where(allowed.contains).toList();
  }

  List<String> get _subGroupChoices {
    Set<String>? allowed;
    if (_fMainGroups.isNotEmpty) {
      allowed = <String>{};
      for (final mg in _fMainGroups) allowed.addAll(_mainToSubs[mg] ?? const {});
    }
    if (_fProdGroups.isNotEmpty) {
      final byGroup = <String>{};
      for (final g in _fProdGroups) byGroup.addAll(_groupToSubs[g] ?? const {});
      allowed = allowed == null ? byGroup : allowed.intersection(byGroup);
    }
    if (allowed == null) return _subGroupOpts;
    return _subGroupOpts.where(allowed.contains).toList();
  }

  // After a parent selection changes, drop any child selections that are no
  // longer valid under the new parent(s).
  void _reconcileCascade() {
    final g = _prodGroupChoices.toSet();
    _fProdGroups.removeWhere((x) => !g.contains(x));
    final s = _subGroupChoices.toSet();
    _fSubGroups.removeWhere((x) => !s.contains(x));
  }

  /// Line-level product filter. Empty selection = all. A line whose product is
  /// unknown (e.g. a name-only POS item) can't match a group, so it is excluded
  /// while any product filter is active.
  bool _prodPassesFilter(String? pid) {
    if (!_productFilterActive) return true;
    if (pid == null) return false;
    final g = _productGroups[pid];
    if (g == null) return false;
    if (_fMainGroups.isNotEmpty && !_fMainGroups.contains(g['mg'])) return false;
    if (_fProdGroups.isNotEmpty && !_fProdGroups.contains(g['g'])) return false;
    if (_fSubGroups.isNotEmpty && !_fSubGroups.contains(g['sg'])) return false;
    return true;
  }

  bool _custPassesFilter(String? customerId) {
    if (_route != 'all') {
      final rids = customerId == null ? null : _custRoutes[customerId];
      if (rids == null || !rids.contains(_route)) return false;
    }
    if (_category == 'all' && _group == 'all') return true;
    final cust = customerId == null ? null : _customers[customerId];
    final cat = (cust?['category'] as String?)?.trim() ?? '';
    final grp = (cust?['group_name'] as String?)?.trim() ?? '';
    if (_category != 'all' && cat != _category) return false;
    if (_group != 'all' && grp != _group) return false;
    return true;
  }

  List<List<T>> _chunk<T>(List<T> list, int size) {
    final out = <List<T>>[];
    for (var i = 0; i < list.length; i += size) {
      out.add(list.sublist(i, i + size > list.length ? list.length : i + size));
    }
    return out;
  }

  Future<void> _run() async {
    if (_orgId == null) return;
    if (_to.isBefore(_from)) {
      _snack('"To" date is before "From" date.');
      return;
    }
    setState(() => _running = true);
    final c = Supabase.instance.client;
    final fromStr = _ymd(_from);
    final toStr = _ymd(_to);
    final toExclusive = _ymd(_to.add(const Duration(days: 1)));
    final productMode = _breakdown == 'product';

    // line-level cells at customer × product grain
    final cells = <Map<String, dynamic>>[];
    final orderSets = <String, Set<String>>{}; // customer key -> distinct doc ids
    var docs = 0;
    // With a product filter active, doc/order counts must reflect only the
    // documents that actually contributed a surviving line — tracked here.
    final liveDocs = <String>{};
    final liveOrderSets = <String, Set<String>>{};

    Map<String, String> custInfo(String? cid, {String? posCustId, bool pos = false}) {
      if (cid != null) {
        final cust = _customers[cid];
        return {
          'k': cid,
          'n': cust == null ? '(customer)' : '${cust['shop_name']}',
          's': cust == null ? '' : '${cust['code'] ?? ''}',
        };
      }
      if (pos && posCustId != null) {
        return {'k': 'pos:$posCustId', 'n': _posCustomerNames[posCustId] ?? 'POS customer', 's': 'POS'};
      }
      if (pos) return {'k': 'pos:walkin', 'n': 'Walk-in', 's': 'POS'};
      return {'k': 'walkin', 'n': '(no customer)', 's': ''};
    }

    try {
      // ───────── Sales Invoices ─────────
      if (_source == 'both' || _source == 'invoice') {
        var q = c
            .from('sales_invoices')
            .select('id, customer_id, branch_id, voucher_date, grand_total')
            .eq('org_id', _orgId!)
            .eq('is_voided', false)
            .gte('voucher_date', fromStr)
            .lte('voucher_date', toStr);
        if (_branch != 'all') q = q.eq('branch_id', _branch);
        final invs = await q;
        final docCust = <String, Map<String, String>>{};
        final keptIds = <String>[];
        for (final inv in invs) {
          if (!_custPassesFilter(inv['customer_id'] as String?)) continue;
          final ci = custInfo(inv['customer_id'] as String?);
          docCust[inv['id'] as String] = ci;
          keptIds.add(inv['id'] as String);
          orderSets.putIfAbsent(ci['k']!, () => {}).add(inv['id'] as String);
        }
        docs += keptIds.length;
        for (final part in _chunk(keptIds, 300)) {
          if (part.isEmpty) continue;
          final items = await c
              .from('sales_invoice_items')
              .select('invoice_id, product_id, qty_delivered, line_total')
              .inFilter('invoice_id', part);
          for (final it in items) {
            final ci = docCust[it['invoice_id']];
            if (ci == null) continue;
            final pid = it['product_id'] as String?;
            if (!_prodPassesFilter(pid)) continue;
            liveDocs.add('${it['invoice_id']}');
            liveOrderSets.putIfAbsent(ci['k']!, () => {}).add('${it['invoice_id']}');
            cells.add({
              'ck': ci['k'], 'cn': ci['n'], 'cs': ci['s'],
              'pk': pid ?? 'unknown',
              'pn': pid == null ? '(unknown product)' : (_productNames[pid] ?? pid),
              'qty': _d(it['qty_delivered']),
              'amount': _d(it['line_total']),
            });
          }
        }
      }

      // ───────── POS sales ─────────
      if (_source == 'both' || _source == 'pos') {
        final txAll = await c
            .from('pos_transactions')
            .select('id, customer_id, pos_customer_id, total, transacted_at, transaction_type, session_id')
            .eq('org_id', _orgId!)
            .gte('transacted_at', fromStr)
            .lt('transacted_at', toExclusive);
        final docCust = <String, Map<String, String>>{};
        final keptIds = <String>[];
        for (final tx in txAll) {
          if ('${tx['transaction_type']}'.toLowerCase() == 'return') continue;
          if (_branch != 'all') {
            final b = _sessionBranch[tx['session_id']];
            if (b != _branch) continue;
          }
          if (!_custPassesFilter(tx['customer_id'] as String?)) continue;
          final ci = custInfo(tx['customer_id'] as String?,
              posCustId: tx['pos_customer_id'] as String?, pos: true);
          docCust[tx['id'] as String] = ci;
          keptIds.add(tx['id'] as String);
          orderSets.putIfAbsent(ci['k']!, () => {}).add(tx['id'] as String);
        }
        docs += keptIds.length;
        for (final part in _chunk(keptIds, 300)) {
          if (part.isEmpty) continue;
          final items = await c
              .from('pos_transaction_items')
              .select('transaction_id, product_id, item_name, quantity, unit_price, discount, discount_type')
              .inFilter('transaction_id', part);
          for (final it in items) {
            final ci = docCust[it['transaction_id']];
            if (ci == null) continue;
            final pid = it['product_id'] as String?;
            if (!_prodPassesFilter(pid)) continue;
            liveDocs.add('${it['transaction_id']}');
            liveOrderSets.putIfAbsent(ci['k']!, () => {}).add('${it['transaction_id']}');
            final qty = _d(it['quantity']);
            final gross = qty * _d(it['unit_price']);
            final disc = '${it['discount_type']}'.toLowerCase() == 'percent'
                ? gross * _d(it['discount']) / 100.0
                : _d(it['discount']);
            final name = pid != null
                ? (_productNames[pid] ?? it['item_name'] ?? pid)
                : (it['item_name'] ?? '(unknown product)');
            cells.add({
              'ck': ci['k'], 'cn': ci['n'], 'cs': ci['s'],
              'pk': pid ?? 'name:${it['item_name']}',
              'pn': '$name',
              'qty': qty,
              'amount': gross - disc,
            });
          }
        }
      }

      // With a product filter, replace the document-level counts with the
      // line-accurate ones so "Documents" and per-customer "Orders" don't
      // include documents whose every line was filtered out.
      if (_productFilterActive) {
        docs = liveDocs.length;
        orderSets
          ..clear()
          ..addAll(liveOrderSets);
      }

      // Resolve any customer that wasn't in the pre-loaded roster. Imported
      // customers can carry a different org tag (so an org-scoped roster misses
      // them), and a large roster is capped on first load — either way the cell
      // shows "(customer)". Look those ids up directly (org-agnostic) and patch
      // the names/codes into the cells before rollup, so on-screen children AND
      // the PDF show the real customer name.
      final unresolved = <String>{
        for (final cell in cells)
          if (cell['cn'] == '(customer)') cell['ck'] as String
      };
      if (unresolved.isNotEmpty) {
        final fix = <String, Map<String, String>>{};
        for (final part in _chunk(unresolved.toList(), 300)) {
          if (part.isEmpty) continue;
          try {
            final crows = await c
                .from('customers')
                .select('id, shop_name, code')
                .inFilter('id', part);
            for (final r in crows) {
              fix[r['id'] as String] = {
                'n': '${r['shop_name'] ?? '(customer)'}',
                's': '${r['code'] ?? ''}',
              };
            }
          } catch (_) {/* leave as (customer) if the lookup fails */}
        }
        if (fix.isNotEmpty) {
          for (final cell in cells) {
            if (cell['cn'] != '(customer)') continue;
            final f = fix[cell['ck']];
            if (f != null) {
              cell['cn'] = f['n'];
              cell['cs'] = f['s'];
            }
          }
        }
      }

      // ───────── roll up to top rows + children ─────────
      final topAgg = <String, Map<String, dynamic>>{};
      final childAgg = <String, Map<String, Map<String, dynamic>>>{};
      for (final cell in cells) {
        final topKey = (productMode ? cell['pk'] : cell['ck']) as String;
        final topName = (productMode ? cell['pn'] : cell['cn']) as String;
        final topSub = productMode ? '' : cell['cs'] as String;
        final childKey = (productMode ? cell['ck'] : cell['pk']) as String;
        final childName = (productMode ? cell['cn'] : cell['pn']) as String;
        final childSub = productMode ? cell['cs'] as String : '';
        final qty = cell['qty'] as double;
        final amt = cell['amount'] as double;

        final t = topAgg.putIfAbsent(topKey,
            () => {'key': topKey, 'name': topName, 'sub': topSub, 'qty': 0.0, 'amount': 0.0, 'count': 0});
        t['qty'] = (t['qty'] as double) + qty;
        t['amount'] = (t['amount'] as double) + amt;

        final ch = childAgg.putIfAbsent(topKey, () => {});
        final ca = ch.putIfAbsent(childKey,
            () => {'key': childKey, 'name': childName, 'sub': childSub, 'qty': 0.0, 'amount': 0.0});
        ca['qty'] = (ca['qty'] as double) + qty;
        ca['amount'] = (ca['amount'] as double) + amt;
      }
      if (!productMode) {
        topAgg.forEach((k, v) => v['count'] = orderSets[k]?.length ?? 0);
      }

      final rows = topAgg.values.toList()
        ..sort((a, b) => (b['amount'] as double).compareTo(a['amount'] as double));
      final children = <String, List<Map<String, dynamic>>>{};
      childAgg.forEach((k, m) {
        children[k] = m.values.toList()
          ..sort((a, b) => (b['amount'] as double).compareTo(a['amount'] as double));
      });
      final grandAmt = rows.fold<double>(0, (s, r) => s + (r['amount'] as double));
      final grandQty = rows.fold<double>(0, (s, r) => s + (r['qty'] as double));

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _children = children;
        _expanded.clear();
        _grandAmount = grandAmt;
        _grandQty = grandQty;
        _docCount = docs;
        _ran = true;
        _running = false;
        _filtersCollapsed = true; // reclaim space for the results
        _searchCtrl.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      _snack('Report failed: $e');
    }
  }

  List<Map<String, dynamic>> get _visibleRows {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows.where((r) {
      return '${r['name']}'.toLowerCase().contains(q) ||
          '${r['sub']}'.toLowerCase().contains(q);
    }).toList();
  }

  // ───────────────────────────────────────────────── build
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Compact the title once results are showing so the table gets room.
        Text('Sales Report',
            style: TextStyle(
                fontSize: _ran ? 20 : 28, fontWeight: FontWeight.w800)),
        if (!_ran) ...[
          const SizedBox(height: 4),
          const Text('Sales across invoices and POS for any period',
              style: TextStyle(color: AppTheme.textSecondary)),
        ],
        const SizedBox(height: 12),
        (_ran && _filtersCollapsed) ? _compactFilterBar() : _filterBar(),
        const SizedBox(height: 12),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : !_ran
                  ? const Center(
                      child: Text('Set your filters and run the report.',
                          style: TextStyle(color: AppTheme.textSecondary)))
                  : _resultArea(),
        ),
      ]),
    );
  }

  Widget _filterBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _dateField('From', _from, (d) => setState(() => _from = d)),
        _dateField('To', _to, (d) => setState(() => _to = d)),
        _dropdown('Source', _source, const {
          'both': 'Invoices + POS',
          'invoice': 'Invoices only',
          'pos': 'POS only',
        }, (v) => setState(() => _source = v)),
        _dropdown('Branch', _branch, {
          'all': 'All branches',
          for (final b in _branches) b['id'] as String: '${b['name']}',
        }, (v) => setState(() => _branch = v)),
        if (_routes.isNotEmpty)
          _dropdown('Route / Market', _route, {
            'all': 'All routes',
            for (final r in _routes) r['id'] as String: '${r['name']}',
          }, (v) => setState(() => _route = v)),
        _dropdown('Customer Category', _category, {
          'all': 'All categories',
          for (final c in _categories) c: c,
        }, (v) => setState(() => _category = v)),
        _dropdown('Customer Group', _group, {
          'all': 'All groups',
          for (final g in _groups) g: g,
        }, (v) => setState(() => _group = v)),
        _dropdown('Breakdown', _breakdown, const {
          'product': 'Product-wise',
          'customer': 'Customer-wise',
        }, (v) => setState(() => _breakdown = v)),
        TextButton.icon(
          icon: Icon(_moreFilters ? Icons.expand_less : Icons.tune, size: 18),
          label: Text(_moreFilters
              ? 'Fewer filters'
              : 'More filters${_productFilterActive ? ' •' : ''}'),
          onPressed: () => setState(() => _moreFilters = !_moreFilters),
        ),
        if (_moreFilters) ...[
          _multiField('Product Main Group', _mainGroupOpts, _fMainGroups),
          _multiField('Product Group', _prodGroupChoices, _fProdGroups),
          _multiField('Product Sub Group', _subGroupChoices, _fSubGroups),
        ],
        ElevatedButton.icon(
          icon: _running
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_arrow, size: 18),
          label: Text(_running ? 'Running…' : 'Run report'),
          onPressed: _running ? null : _run,
        ),
      ]),
    );
  }

  // A one-line summary of the active filters shown after a run, with an "Edit
  // filters" button to bring the full form back. Frees vertical space for the
  // results table.
  Widget _compactFilterBar() {
    final srcLabel = {
      'both': 'Invoices + POS',
      'invoice': 'Invoices only',
      'pos': 'POS only',
    }[_source];
    final branchLabel = _branch == 'all'
        ? 'All branches'
        : _branches.firstWhere((b) => b['id'] == _branch,
            orElse: () => {'name': _branch})['name'];
    final chips = <String>[
      '${DateFormat('d MMM').format(_from)} – ${DateFormat('d MMM y').format(_to)}',
      '$srcLabel',
      '$branchLabel',
      if (_route != 'all')
        'Route: ${_routes.firstWhere((r) => r['id'] == _route, orElse: () => {'name': _route})['name']}',
      _breakdown == 'product' ? 'Product-wise' : 'Customer-wise',
      if (_category != 'all') 'Cat: $_category',
      if (_group != 'all') 'Grp: $_group',
      if (_fMainGroups.isNotEmpty) 'Main: ${_fMainGroups.length}',
      if (_fProdGroups.isNotEmpty) 'Group: ${_fProdGroups.length}',
      if (_fSubGroups.isNotEmpty) 'Sub: ${_fSubGroups.length}',
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        const Icon(Icons.filter_list, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final ch in chips)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.background,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(ch,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textPrimary)),
              ),
          ]),
        ),
        const SizedBox(width: 10),
        TextButton.icon(
          icon: const Icon(Icons.tune, size: 16),
          label: const Text('Edit filters'),
          onPressed: () => setState(() => _filtersCollapsed = false),
        ),
      ]),
    );
  }

  /// A multi-select filter field: shows "All" / "N selected", opens a
  /// searchable checkbox picker. Empty selection means "all".
  Widget _multiField(String label, List<String> options, Set<String> selected) {
    final summary = selected.isEmpty
        ? 'All'
        : (selected.length == 1
            ? selected.first
            : '${selected.length} selected');
    return SizedBox(
      width: 190,
      child: InkWell(
        onTap: options.isEmpty
            ? null
            : () => _openMultiPicker(label, options, selected),
        child: InputDecorator(
          decoration: InputDecoration(
              labelText: label, isDense: true, border: const OutlineInputBorder()),
          child: Row(children: [
            Expanded(
              child: Text(options.isEmpty ? 'None defined' : summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: options.isEmpty
                          ? AppTheme.textSecondary
                          : (selected.isEmpty ? null : AppTheme.primary),
                      fontWeight:
                          selected.isEmpty ? null : FontWeight.w600)),
            ),
            const Icon(Icons.arrow_drop_down, size: 20),
          ]),
        ),
      ),
    );
  }

  Future<void> _openMultiPicker(
      String title, List<String> options, Set<String> selected) async {
    final work = Set<String>.from(selected);
    final searchCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        final q = searchCtrl.text.trim().toLowerCase();
        final visible = q.isEmpty
            ? options
            : options.where((o) => o.toLowerCase().contains(q)).toList();
        return AlertDialog(
          title: Text(title, style: const TextStyle(fontSize: 17)),
          content: SizedBox(
            width: 380,
            height: 420,
            child: Column(children: [
              TextField(
                controller: searchCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search…',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () => setDlg(() => searchCtrl.clear())),
                ),
                onChanged: (_) => setDlg(() {}),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Text(
                    work.isEmpty
                        ? 'All included'
                        : '${work.length} of ${options.length} selected',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
                const Spacer(),
                TextButton(
                  onPressed:
                      work.isEmpty ? null : () => setDlg(() => work.clear()),
                  child: const Text('All', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: visible.isEmpty
                      ? null
                      : () => setDlg(() => work.addAll(visible)),
                  child: const Text('Select shown',
                      style: TextStyle(fontSize: 12)),
                ),
              ]),
              const Divider(height: 1),
              Expanded(
                child: visible.isEmpty
                    ? const Center(
                        child: Text('No matches',
                            style: TextStyle(color: AppTheme.textSecondary)))
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (_, i) {
                          final o = visible[i];
                          return CheckboxListTile(
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 4),
                            title: Text(o,
                                style: const TextStyle(fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            value: work.contains(o),
                            onChanged: (v) => setDlg(() =>
                                v == true ? work.add(o) : work.remove(o)),
                          );
                        },
                      ),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  selected
                    ..clear()
                    ..addAll(work);
                  // Keep child selections valid when a parent changes.
                  _reconcileCascade();
                });
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        );
      }),
    );
    searchCtrl.dispose();
  }

  Widget _dateField(String label, DateTime value, ValueChanged<DateTime> onPick) {
    return SizedBox(
      width: 160,
      child: InkWell(
        onTap: () async {
          final d = await showDatePicker(
            context: context,
            initialDate: value,
            firstDate: DateTime(2020),
            lastDate: DateTime(2100),
          );
          if (d != null) onPick(d);
        },
        child: InputDecorator(
          decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
          child: Text(DateFormat('d MMM y').format(value)),
        ),
      ),
    );
  }

  Widget _dropdown(String label, String value, Map<String, String> items,
      ValueChanged<String> onChanged) {
    return SizedBox(
      width: 190,
      child: DropdownButtonFormField<String>(
        value: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
        items: [
          for (final e in items.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) => onChanged(v ?? value),
      ),
    );
  }

  Widget _resultArea() {
    final rows = _visibleRows;
    final productMode = _breakdown == 'product';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Wrap(spacing: 18, runSpacing: 4, children: [
            _kv('Period', '${DateFormat('d MMM y').format(_from)} – ${DateFormat('d MMM y').format(_to)}'),
            _kv(productMode ? 'Products' : 'Customers', '${_rows.length}'),
            _kv('Documents', '$_docCount'),
            if (productMode) _kv('Total qty', _qtyFmt.format(_grandQty)),
            _kv('Total sales', _money.format(_grandAmount)),
          ]),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
          label: const Text('Print / PDF'),
          onPressed: rows.isEmpty ? null : _printPdf,
        ),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        SizedBox(
          width: 360,
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: productMode ? 'Search product…' : 'Search customer…',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _searchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => _searchCtrl.clear()),
            ),
          ),
        ),
        const Spacer(),
        TextButton.icon(
          icon: Icon(_expanded.isEmpty ? Icons.unfold_more : Icons.unfold_less, size: 18),
          label: Text(_expanded.isEmpty ? 'Expand all' : 'Collapse all'),
          onPressed: rows.isEmpty
              ? null
              : () => setState(() {
                    if (_expanded.isEmpty) {
                      _expanded.addAll(rows.map((r) => r['key'] as String));
                    } else {
                      _expanded.clear();
                    }
                  }),
        ),
      ]),
      const SizedBox(height: 10),
      _tableHeader(productMode),
      const Divider(height: 1),
      Expanded(
        child: rows.isEmpty
            ? const Center(
                child: Text('No matching rows.',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _tableRow(i + 1, rows[i], productMode),
              ),
      ),
      const Divider(height: 1, thickness: 1),
      _totalsRow(productMode, rows),
    ]);
  }

  Widget _kv(String k, String v) => RichText(
        text: TextSpan(style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13), children: [
          TextSpan(text: '$k: '),
          TextSpan(text: v, style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _tableHeader(bool productMode) {
    const s = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        const SizedBox(width: 36),
        Expanded(flex: 4, child: Text(productMode ? 'Product' : 'Customer', style: s)),
        if (!productMode) const Expanded(flex: 2, child: Text('Cat / Group', style: s)),
        Expanded(
            flex: 2,
            child: Text(productMode ? 'Qty' : 'Orders', style: s, textAlign: TextAlign.right)),
        Expanded(flex: 2, child: Text('Amount', style: s, textAlign: TextAlign.right)),
        const SizedBox(
            width: 60, child: Text('%', style: s, textAlign: TextAlign.right)),
      ]),
    );
  }

  Widget _tableRow(int n, Map<String, dynamic> r, bool productMode) {
    final amount = r['amount'] as double;
    final pct = _grandAmount == 0 ? 0.0 : amount / _grandAmount * 100;
    final key = r['key'] as String;
    final kids = _children[key] ?? const [];
    final expanded = _expanded.contains(key);
    final cust = productMode ? null : _customers[key];
    final catGrp = cust == null
        ? '${r['sub']}'
        : [cust['category'], cust['group_name']].where((x) => x != null && '$x'.isNotEmpty).join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: kids.isEmpty
            ? null
            : () => setState(() =>
                expanded ? _expanded.remove(key) : _expanded.add(key)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(children: [
            SizedBox(
              width: 36,
              child: Row(children: [
                Text('$n',
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                const SizedBox(width: 2),
                Icon(
                    kids.isEmpty
                        ? Icons.remove
                        : (expanded ? Icons.expand_less : Icons.expand_more),
                    size: 15,
                    color: AppTheme.textSecondary),
              ]),
            ),
            Expanded(
              flex: 4,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${r['name']}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                if (!productMode && '${r['sub']}'.isNotEmpty)
                  Text('${r['sub']}',
                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ]),
            ),
            if (!productMode)
              Expanded(
                flex: 2,
                child: Text(catGrp,
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            Expanded(
              flex: 2,
              child: Text(productMode ? _qtyFmt.format(r['qty']) : '${r['count']}',
                  textAlign: TextAlign.right, style: const TextStyle(fontSize: 13)),
            ),
            Expanded(
              flex: 2,
              child: Text(_money.format(amount),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            SizedBox(
              width: 60,
              child: Text('${pct.toStringAsFixed(1)}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ),
          ]),
        ),
      ),
      if (expanded && kids.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(left: 36, bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(children: [for (final ch in kids) _childRow(ch, productMode)]),
        ),
    ]);
  }

  Widget _childRow(Map<String, dynamic> ch, bool productMode) {
    // In product-mode the children are customers; in customer-mode they're products.
    final childIsProduct = !productMode;
    final amount = ch['amount'] as double;
    final sub = '${ch['sub']}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Icon(childIsProduct ? Icons.inventory_2_outlined : Icons.person_outline,
            size: 13, color: AppTheme.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          flex: 4,
          child: Text(
              sub.isEmpty ? '${ch['name']}' : '${ch['name']}  ·  $sub',
              style: const TextStyle(fontSize: 12.5),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (!productMode) const Expanded(flex: 2, child: SizedBox()),
        Expanded(
          flex: 2,
          child: Text(_qtyFmt.format(ch['qty']),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        ),
        Expanded(
          flex: 2,
          child: Text(_money.format(amount),
              textAlign: TextAlign.right, style: const TextStyle(fontSize: 12.5)),
        ),
        const SizedBox(width: 60),
      ]),
    );
  }

  Widget _totalsRow(bool productMode, List<Map<String, dynamic>> rows) {
    final amt = rows.fold<double>(0, (s, r) => s + (r['amount'] as double));
    final qty = rows.fold<double>(0, (s, r) => s + (r['qty'] as double));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        const SizedBox(width: 36),
        const Expanded(flex: 4, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w800))),
        if (!productMode) const Expanded(flex: 2, child: SizedBox()),
        Expanded(
          flex: 2,
          child: Text(productMode ? _qtyFmt.format(qty) : '',
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
        Expanded(
          flex: 2,
          child: Text(_money.format(amt),
              textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 60),
      ]),
    );
  }

  // ───────────────────────────────────────────────── PDF
  Future<void> _printPdf() async {
    final productMode = _breakdown == 'product';
    final rows = _visibleRows;
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final doc = pw.Document();

    final srcLabel = {'both': 'Invoices + POS', 'invoice': 'Invoices', 'pos': 'POS'}[_source];
    final filterBits = <String>[
      'Source: $srcLabel',
      if (_branch != 'all')
        'Branch: ${_branches.firstWhere((b) => b['id'] == _branch, orElse: () => {'name': _branch})['name']}',
      if (_route != 'all')
        'Route: ${_routes.firstWhere((r) => r['id'] == _route, orElse: () => {'name': _route})['name']}',
      if (_category != 'all') 'Category: $_category',
      if (_group != 'all') 'Group: $_group',
      if (_fMainGroups.isNotEmpty) 'Main Group: ${_fMainGroups.join(', ')}',
      if (_fProdGroups.isNotEmpty) 'Product Group: ${_fProdGroups.join(', ')}',
      if (_fSubGroups.isNotEmpty) 'Sub Group: ${_fSubGroups.join(', ')}',
    ];

    final headers = productMode
        ? ['#', 'Product', 'Qty', 'Amount', '%']
        : ['#', 'Customer', 'Cat / Group', 'Orders', 'Amount', '%'];

    final data = <List<String>>[];
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final amount = r['amount'] as double;
      final pct = _grandAmount == 0 ? 0.0 : amount / _grandAmount * 100;
      if (productMode) {
        data.add([
          '${i + 1}',
          '${r['name']}',
          _qtyFmt.format(r['qty']),
          _money.format(amount),
          '${pct.toStringAsFixed(1)}%',
        ]);
      } else {
        final cust = _customers[r['key']];
        final catGrp = cust == null
            ? '${r['sub']}'
            : [cust['category'], cust['group_name']]
                .where((x) => x != null && '$x'.isNotEmpty)
                .join(' / ');
        data.add([
          '${i + 1}',
          '${r['name']}${'${r['sub']}'.isNotEmpty ? '  (${r['sub']})' : ''}',
          catGrp,
          '${r['count']}',
          _money.format(amount),
          '${pct.toStringAsFixed(1)}%',
        ]);
      }
      for (final ch in (_children[r['key']] ?? const <Map<String, dynamic>>[])) {
        final sub = '${ch['sub']}';
        final cname = sub.isEmpty ? '${ch['name']}' : '${ch['name']}  ($sub)';
        if (productMode) {
          data.add(['', '    - $cname', _qtyFmt.format(ch['qty']), _money.format(ch['amount']), '']);
        } else {
          data.add(['', '    - $cname', '', _qtyFmt.format(ch['qty']), _money.format(ch['amount']), '']);
        }
      }
    }
    final totalAmt = rows.fold<double>(0, (s, r) => s + (r['amount'] as double));
    final totalQty = rows.fold<double>(0, (s, r) => s + (r['qty'] as double));
    final totalRow = productMode
        ? ['', 'Total', _qtyFmt.format(totalQty), _money.format(totalAmt), '']
        : ['', 'Total', '', '', _money.format(totalAmt), ''];

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (ctx) => [
        if (org.isNotEmpty)
          pw.Text(org, style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        pw.Text('Sales Report - ${productMode ? 'Product-wise' : 'Customer-wise'}',
            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text(
            '${DateFormat('d MMM y').format(_from)} to ${DateFormat('d MMM y').format(_to)}     |     ${filterBits.join('     |     ')}',
            style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: headers,
          data: [...data, totalRow],
          headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 9),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          cellAlignments: productMode
              ? {0: pw.Alignment.centerLeft, 2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight}
              : {0: pw.Alignment.centerLeft, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight},
          rowDecoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5))),
        ),
        pw.SizedBox(height: 8),
        pw.Text('Total sales: ${_money.format(totalAmt)}',
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
      ],
    ));

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat f) async => doc.save(),
      name: 'sales-report-${_ymd(_from)}_${_ymd(_to)}.pdf',
    );
  }
}
