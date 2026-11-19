// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/format/time_format.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../core/widgets/saving_overlay.dart';
import '../../auth/auth_controller.dart';

/// Scheme Vouchers: every Sales Order, Delivery Order and Sales Invoice that
/// carries a scheme. A scheme is applied on the Sales Order (free goods) or on
/// the Sales Invoice (discounts / promo prices); the Delivery Order and the
/// invoice raised from an order carry the order's schemes forward, so one order
/// can show up as its SO, its DO(s) and its SI.
class ErpSchemeVouchersReportScreen extends ConsumerStatefulWidget {
  const ErpSchemeVouchersReportScreen({super.key});
  @override
  ConsumerState<ErpSchemeVouchersReportScreen> createState() => _ErpSchemeVouchersReportScreenState();
}

class _RepRow {
  final String type; // SO | DO | SI
  final String number;
  final DateTime? date;
  final String customer;
  final String group;
  final String scheme;
  final String status;
  final double? freeQty;
  final double? discount;
  final double? amount;
  const _RepRow({
    required this.type,
    required this.number,
    required this.date,
    required this.customer,
    required this.group,
    required this.scheme,
    required this.status,
    this.freeQty,
    this.discount,
    this.amount,
  });
}

class _ErpSchemeVouchersReportScreenState extends ConsumerState<ErpSchemeVouchersReportScreen> {
  String _type = 'ALL';
  Set<String> _schemeIds = {};
  String? _group;
  Set<String> _custIds = {};
  late DateTimeRange _range;

  List<Map<String, dynamic>> _schemes = [];
  List<Map<String, dynamic>> _customers = [];
  List<_RepRow> _rows = [];
  bool _metaLoading = true;
  bool _loading = false;
  bool _loaded = false;

  static const _typeNames = {'SO': 'Sales Order', 'DO': 'Delivery Order', 'SI': 'Sales Invoice'};
  static const _typeOrder = ['SO', 'DO', 'SI'];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _range = DateTimeRange(start: DateTime(now.year, now.month, 1), end: DateTime(now.year, now.month, now.day));
    _loadMeta().then((_) { if (mounted) _run(); });
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  Future<List<Map<String, dynamic>>> _pagedAll(Future<List<Map<String, dynamic>>> Function(int from, int to) page) async {
    final out = <Map<String, dynamic>>[];
    for (var from = 0;; from += 1000) {
      final chunk = await page(from, from + 999);
      out.addAll(chunk);
      if (chunk.length < 1000) break;
    }
    return out;
  }

  Future<void> _loadMeta() async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final sch = await client.from('schemes').select('id, name').eq('org_id', orgId).order('name');
      final cust = await _pagedAll((a, b) async => List<Map<String, dynamic>>.from(
          await client.from('customers').select('id, code, shop_name, group_name').eq('org_id', orgId).order('id').range(a, b) as List));
      if (!mounted) return;
      setState(() {
        _schemes = List<Map<String, dynamic>>.from(sch as List);
        _customers = cust;
        _metaLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _metaLoading = false);
      _snack(friendlyError('Could not load the filter lists', e));
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  List<String> get _groups {
    final g = <String>{for (final c in _customers) if (((c['group_name'] as String?)?.trim() ?? '').isNotEmpty) (c['group_name'] as String).trim()};
    return g.toList()..sort();
  }

  Future<List<Map<String, dynamic>>> _byIds(SupabaseClient c, String table, String cols, String col, List<String> ids, String from, String toExcl) async {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < ids.length; i += 150) {
      final chunk = ids.sublist(i, (i + 150).clamp(0, ids.length));
      final r = await c.from(table).select(cols).inFilter(col, chunk).gte('voucher_date', from).lt('voucher_date', toExcl);
      out.addAll(List<Map<String, dynamic>>.from(r as List));
    }
    return out;
  }

  Future<void> _run() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final from = DateFormat('yyyy-MM-dd').format(_range.start);
      final toExcl = DateFormat('yyyy-MM-dd').format(_range.end.add(const Duration(days: 1)));

      // Customer filter: chosen customers, narrowed to the chosen group.
      Set<String>? allow;
      if (_custIds.isNotEmpty) allow = {..._custIds};
      if (_group != null) {
        final g = <String>{for (final c in _customers) if ((c['group_name'] as String?)?.trim() == _group) c['id'] as String};
        allow = allow == null ? g : allow.intersection(g);
      }
      final Set<String>? allowed = allow;
      bool okCust(String? id) => allowed == null || (id != null && allowed.contains(id));
      final groupOf = {for (final c in _customers) c['id'] as String: ((c['group_name'] as String?)?.trim() ?? '')};

      // 1) the scheme log (one row per scheme per Sales Order / Sales Invoice)
      final reds = await _pagedAll((a, b) async {
        var q = client.from('scheme_redemptions')
            .select('id, scheme_id, scheme_name, voucher_type, voucher_id, free_qty, discount_amount')
            .eq('org_id', orgId);
        if (_schemeIds.isNotEmpty) q = q.inFilter('scheme_id', _schemeIds.toList());
        return List<Map<String, dynamic>>.from(await q.order('id').range(a, b) as List);
      });
      final soRed = <String, List<Map<String, dynamic>>>{};
      final siRed = <String, List<Map<String, dynamic>>>{};
      for (final r in reds) {
        final id = r['voucher_id'] as String?;
        if (id == null) continue;
        if (r['voucher_type'] == 'SO') { (soRed[id] ??= []).add(r); }
        else if (r['voucher_type'] == 'SI') { (siRed[id] ??= []).add(r); }
      }

      DateTime? d(dynamic v) => v == null ? null : DateTime.tryParse('$v');
      double? n(dynamic v) => (v as num?)?.toDouble();
      final out = <_RepRow>[];
      const custCols = 'customers(shop_name, code, group_name)';

      // 2) Sales Orders carrying a scheme
      if ((_type == 'ALL' || _type == 'SO') && soRed.isNotEmpty) {
        final rows = await _byIds(client, 'sales_orders', 'id, voucher_number, voucher_date, status, customer_id, $custCols', 'id', soRed.keys.toList(), from, toExcl);
        for (final so in rows) {
          if ('${so['status']}' == 'cancelled') continue;
          final cid = so['customer_id'] as String?;
          if (!okCust(cid)) continue;
          for (final r in soRed[so['id']] ?? const <Map<String, dynamic>>[]) {
            out.add(_RepRow(
              type: 'SO', number: '${so['voucher_number'] ?? ''}', date: d(so['voucher_date']),
              customer: '${(so['customers'] as Map?)?['shop_name'] ?? 'Walk-in'}',
              group: groupOf[cid] ?? '', scheme: '${r['scheme_name'] ?? ''}',
              status: '${so['status'] ?? ''}'.replaceAll('_', ' '), freeQty: n(r['free_qty']),
            ));
          }
        }
      }

      // 3) Delivery Orders of those Sales Orders (the scheme is carried forward)
      if ((_type == 'ALL' || _type == 'DO') && soRed.isNotEmpty) {
        final rows = await _byIds(client, 'delivery_orders', 'id, voucher_number, voucher_date, status, is_voided, so_id, customer_id, $custCols', 'so_id', soRed.keys.toList(), from, toExcl);
        for (final dO in rows) {
          if (dO['is_voided'] == true) continue;
          final cid = dO['customer_id'] as String?;
          if (!okCust(cid)) continue;
          for (final r in soRed[dO['so_id']] ?? const <Map<String, dynamic>>[]) {
            out.add(_RepRow(
              type: 'DO', number: '${dO['voucher_number'] ?? ''}', date: d(dO['voucher_date']),
              customer: '${(dO['customers'] as Map?)?['shop_name'] ?? 'Walk-in'}',
              group: groupOf[cid] ?? '', scheme: '${r['scheme_name'] ?? ''}',
              status: '${dO['status'] ?? ''}'.replaceAll('_', ' '),
            ));
          }
        }
      }

      // 4) Sales Invoices: those from a scheme order, and those with their own scheme
      if (_type == 'ALL' || _type == 'SI') {
        const siCols = 'id, voucher_number, voucher_date, is_voided, is_locked, so_id, customer_id, grand_total, $custCols, sales_orders(customer_id, $custCols)';
        final bySo = soRed.isEmpty ? <Map<String, dynamic>>[] : await _byIds(client, 'sales_invoices', siCols, 'so_id', soRed.keys.toList(), from, toExcl);
        final byOwn = siRed.isEmpty ? <Map<String, dynamic>>[] : await _byIds(client, 'sales_invoices', siCols, 'id', siRed.keys.toList(), from, toExcl);
        final sis = <String, Map<String, dynamic>>{for (final s in [...bySo, ...byOwn]) s['id'] as String: s};
        for (final si in sis.values) {
          if (si['is_voided'] == true) continue;
          final so = si['sales_orders'] as Map?;
          final cid = (si['customer_id'] as String?) ?? (so?['customer_id'] as String?);
          if (!okCust(cid)) continue;
          final custMap = (si['customers'] as Map?) ?? (so?['customers'] as Map?);
          // schemes: the order's (carried forward) and the invoice's own; own wins
          final perScheme = <String, Map<String, dynamic>>{};
          for (final r in soRed[si['so_id']] ?? const <Map<String, dynamic>>[]) { perScheme['${r['scheme_id']}'] = {'name': r['scheme_name'], 'disc': null}; }
          for (final r in siRed[si['id']] ?? const <Map<String, dynamic>>[]) { perScheme['${r['scheme_id']}'] = {'name': r['scheme_name'], 'disc': n(r['discount_amount'])}; }
          for (final e in perScheme.values) {
            out.add(_RepRow(
              type: 'SI', number: '${si['voucher_number'] ?? ''}', date: d(si['voucher_date']),
              customer: '${custMap?['shop_name'] ?? 'Walk-in'}', group: groupOf[cid] ?? '',
              scheme: '${e['name'] ?? ''}', status: si['is_locked'] == true ? 'Posted' : 'Draft',
              discount: e['disc'] as double?, amount: n(si['grand_total']),
            ));
          }
        }
      }

      out.sort((a, b) {
        final t = _typeOrder.indexOf(a.type).compareTo(_typeOrder.indexOf(b.type));
        if (t != 0) return t;
        final c = (b.date ?? DateTime(1970)).compareTo(a.date ?? DateTime(1970));
        return c != 0 ? c : a.number.compareTo(b.number);
      });
      if (!mounted) return;
      setState(() { _rows = out; _loading = false; _loaded = true; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _snack(friendlyError('Could not load the report', e));
    }
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime(2100), initialDateRange: _range);
    if (r != null) { setState(() => _range = r); _run(); }
  }

  Future<Set<String>?> _pickMany(String title, List<MapEntry<String, String>> items, Set<String> initial) {
    final sel = <String>{...initial};
    final searchCtrl = TextEditingController();
    return showDialog<Set<String>>(
      context: context,
      builder: (dctx) => StatefulBuilder(builder: (ctx, setS) {
        final q = searchCtrl.text.trim();
        final list = q.isEmpty ? items : items.where((e) => matchesQuery(e.value, q)).toList();
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 440, height: 460,
            child: Column(children: [
              TextField(
                controller: searchCtrl, autofocus: true,
                decoration: const InputDecoration(hintText: 'Search…', prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder()),
                onChanged: (_) => setS(() {}),
              ),
              const SizedBox(height: 6),
              Row(children: [
                TextButton(onPressed: () => setS(() { for (final e in list) { sel.add(e.key); } }), child: const Text('Select shown')),
                TextButton(onPressed: () => setS(() => sel.clear()), child: const Text('Clear')),
                const Spacer(),
                Text('${sel.length} selected', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ]),
              Expanded(
                child: ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final e = list[i];
                    return CheckboxListTile(
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: sel.contains(e.key),
                      title: Text(e.value, style: const TextStyle(fontSize: 13)),
                      onChanged: (v) => setS(() { if (v == true) { sel.add(e.key); } else { sel.remove(e.key); } }),
                    );
                  },
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.of(dctx).pop(sel), child: const Text('Apply')),
          ],
        );
      }),
    );
  }

  String get _schemeLabel => _schemeIds.isEmpty ? 'All schemes' : (_schemeIds.length == 1 ? '${_schemes.firstWhere((s) => s['id'] == _schemeIds.first, orElse: () => {'name': '1 scheme'})['name']}' : '${_schemeIds.length} schemes');
  String get _custLabel => _custIds.isEmpty ? 'All customers' : (_custIds.length == 1 ? '1 customer' : '${_custIds.length} customers');
  String get _periodLabel => '${DateFormat('d MMM yyyy').format(_range.start)} – ${DateFormat('d MMM yyyy').format(_range.end)}';
  String get _typeLabel => _type == 'ALL' ? 'All vouchers' : '${_typeNames[_type]}s ($_type)';

  Map<String, Map<String, num>> _totals() {
    final t = {for (final k in _typeOrder) k: <String, num>{'n': 0, 'free': 0, 'disc': 0, 'amt': 0}};
    for (final r in _rows) {
      final m = t[r.type]!;
      m['n'] = m['n']! + 1;
      m['free'] = m['free']! + (r.freeQty ?? 0);
      m['disc'] = m['disc']! + (r.discount ?? 0);
      m['amt'] = m['amt']! + (r.amount ?? 0);
    }
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final totals = _totals();
    return Container(
      color: AppTheme.background,
      child: Column(children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.local_offer_outlined, color: AppTheme.primary),
              const SizedBox(width: 10),
              const Text('Scheme Vouchers', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _loaded && _rows.isNotEmpty ? _print : null,
                icon: const Icon(Icons.print_outlined, size: 16),
                label: const Text('Print / PDF'),
              ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _box(DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _type, isDense: true,
                  items: const [
                    DropdownMenuItem(value: 'ALL', child: Text('All vouchers')),
                    DropdownMenuItem(value: 'SO', child: Text('Sales Orders (SO)')),
                    DropdownMenuItem(value: 'DO', child: Text('Delivery Orders (DO)')),
                    DropdownMenuItem(value: 'SI', child: Text('Sales Invoices (SI)')),
                  ],
                  onChanged: (v) { if (v != null) { setState(() => _type = v); _run(); } },
                ),
              ), 'Voucher type'),
              OutlinedButton.icon(
                onPressed: _metaLoading ? null : () async {
                  final r = await _pickMany('Schemes', [for (final s in _schemes) MapEntry(s['id'] as String, '${s['name']}')], _schemeIds);
                  if (r != null) { setState(() => _schemeIds = r); _run(); }
                },
                icon: const Icon(Icons.local_offer_outlined, size: 16),
                label: Text(_schemeLabel, overflow: TextOverflow.ellipsis),
              ),
              OutlinedButton.icon(
                onPressed: _pickRange,
                icon: const Icon(Icons.event, size: 16),
                label: Text(_periodLabel),
              ),
              _box(DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: _group, isDense: true, hint: const Text('All groups'),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('All groups')),
                    for (final g in _groups) DropdownMenuItem<String?>(value: g, child: Text(g)),
                  ],
                  onChanged: (v) { setState(() => _group = v); _run(); },
                ),
              ), 'Customer group'),
              OutlinedButton.icon(
                onPressed: _metaLoading ? null : () async {
                  final r = await _pickMany('Customers', [
                    for (final c in _customers) MapEntry(c['id'] as String, '${c['code'] != null ? '${c['code']} — ' : ''}${c['shop_name'] ?? ''}')
                  ], _custIds);
                  if (r != null) { setState(() => _custIds = r); _run(); }
                },
                icon: const Icon(Icons.people_outline, size: 16),
                label: Text(_custLabel),
              ),
            ]),
          ]),
        ),
        if (_loading || _metaLoading)
          const Expanded(child: Center(child: BrandSpinner()))
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Wrap(spacing: 10, runSpacing: 10, children: [
              for (final k in _typeOrder)
                if (_type == 'ALL' || _type == k) _summary(k, totals[k]!),
            ]),
          ),
          Expanded(child: _table()),
        ],
      ]),
    );
  }

  Widget _box(Widget child, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$label: ', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          child,
        ]),
      );

  Widget _summary(String k, Map<String, num> t) {
    final nf = NumberFormat('#,##0.##');
    final parts = <String>['${t['n']!.toInt()} voucher(s)'];
    if (k == 'SO' && t['free']! > 0) parts.add('${nf.format(t['free'])} free units');
    if (k == 'SI') {
      if (t['disc']! > 0) parts.add('Rs ${nf.format(t['disc'])} discount');
      parts.add('Rs ${nf.format(t['amt'])} invoiced');
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_typeNames[k]}s', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(parts.join('  ·  '), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _table() {
    if (!_loaded) return const Center(child: Text('Set the filters to see the report.', style: TextStyle(color: AppTheme.textSecondary)));
    if (_rows.isEmpty) return const Center(child: Text('No vouchers with a scheme match these filters.', style: TextStyle(color: AppTheme.textSecondary)));
    final nf = NumberFormat('#,##0.##');
    const hdr = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
    Widget cell(String t, int flex, {TextStyle? style, TextAlign align = TextAlign.left}) =>
        Expanded(flex: flex, child: Text(t, textAlign: align, overflow: TextOverflow.ellipsis, style: style ?? const TextStyle(fontSize: 12.5)));
    return LayoutBuilder(builder: (ctx, c) {
      final w = c.maxWidth < 1180 ? 1180.0 : c.maxWidth;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: w,
          child: Column(children: [
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
              child: Row(children: [
                cell('Date', 10, style: hdr), cell('Type', 6, style: hdr), cell('Voucher', 13, style: hdr),
                cell('Customer', 24, style: hdr), cell('Group', 12, style: hdr), cell('Scheme', 18, style: hdr),
                cell('Status', 9, style: hdr), cell('Free qty', 8, style: hdr, align: TextAlign.right),
                cell('Discount', 9, style: hdr, align: TextAlign.right), cell('Invoice amount', 11, style: hdr, align: TextAlign.right),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                itemCount: _rows.length,
                itemBuilder: (_, i) {
                  final r = _rows[i];
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: i.isEven ? Colors.white : const Color(0xFFFAFBFD), border: const Border(bottom: BorderSide(color: AppTheme.border))),
                    child: Row(children: [
                      cell(r.date == null ? '-' : DateFormat('d MMM yyyy').format(r.date!), 10),
                      cell(r.type, 6, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                      cell(r.number, 13, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                      cell(r.customer, 24), cell(r.group.isEmpty ? '-' : r.group, 12), cell(r.scheme, 18),
                      cell(r.status, 9),
                      cell(r.freeQty == null ? '-' : nf.format(r.freeQty), 8, align: TextAlign.right),
                      cell(r.discount == null ? '-' : nf.format(r.discount), 9, align: TextAlign.right),
                      cell(r.amount == null ? '-' : nf.format(r.amount), 11, align: TextAlign.right),
                    ]),
                  );
                },
              ),
            ),
          ]),
        ),
      );
    });
  }

  String _esc(String? v) => (v ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  void _print() {
    final nf = NumberFormat('#,##0.##');
    final totals = _totals();
    final gen = DateFormat(orgTime('d MMM yyyy, h:mm a')).format(DateTime.now());
    final custNames = _custIds.isEmpty
        ? 'All'
        : _customers.where((c) => _custIds.contains(c['id'])).map((c) => '${c['shop_name'] ?? ''}').take(6).join(', ') + (_custIds.length > 6 ? ' +${_custIds.length - 6} more' : '');
    final schemeNames = _schemeIds.isEmpty
        ? 'All'
        : _schemes.where((s) => _schemeIds.contains(s['id'])).map((s) => '${s['name']}').join(', ');
    final body = StringBuffer();
    for (final r in _rows) {
      body.write('<tr><td>${r.date == null ? '-' : DateFormat('d MMM yyyy').format(r.date!)}</td><td class="t">${r.type}</td>'
          '<td class="b">${_esc(r.number)}</td><td>${_esc(r.customer)}</td><td>${_esc(r.group.isEmpty ? '-' : r.group)}</td>'
          '<td>${_esc(r.scheme)}</td><td>${_esc(r.status)}</td>'
          '<td class="n">${r.freeQty == null ? '-' : nf.format(r.freeQty)}</td>'
          '<td class="n">${r.discount == null ? '-' : nf.format(r.discount)}</td>'
          '<td class="n">${r.amount == null ? '-' : nf.format(r.amount)}</td></tr>');
    }
    final tot = StringBuffer();
    for (final k in _typeOrder) {
      if (_type != 'ALL' && _type != k) continue;
      final t = totals[k]!;
      final parts = <String>['${t['n']!.toInt()} voucher(s)'];
      if (k == 'SO' && t['free']! > 0) parts.add('${nf.format(t['free'])} free units');
      if (k == 'SI') {
        if (t['disc']! > 0) parts.add('Rs ${nf.format(t['disc'])} discount');
        parts.add('Rs ${nf.format(t['amt'])} invoiced');
      }
      tot.write('<div class="tot"><b>${_typeNames[k]}s</b> &nbsp; ${_esc(parts.join('  ·  '))}</div>');
    }
    final doc = '''<!doctype html><html><head><meta charset="utf-8"><title>Scheme Vouchers — ${_esc(_periodLabel)}</title>
<style>
@page { size: A4 landscape; margin: 12mm 10mm 14mm; }
* { box-sizing: border-box; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body { font-family: -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; color: #0f172a; margin: 0; font-size: 10.5px; }
h1 { font-size: 20px; margin: 0; color: #1e3a8a; }
.band { display: flex; justify-content: space-between; align-items: flex-end; border-bottom: 3px solid #1e3a8a; padding-bottom: 8px; }
.sub { color: #475569; font-size: 10px; }
.filters { margin: 8px 0 10px; font-size: 10px; color: #475569; display: flex; flex-wrap: wrap; gap: 3px 18px; }
.filters b { color: #0f172a; }
.tots { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 10px; }
.tot { border: 1px solid #e2e8f0; border-radius: 6px; padding: 6px 10px; }
table { width: 100%; border-collapse: collapse; }
th { background: #1e3a8a; color: #fff; text-align: left; padding: 5px 6px; font-size: 9.5px; text-transform: uppercase; letter-spacing: .4px; }
td { padding: 4px 6px; border-bottom: 1px solid #e2e8f0; vertical-align: top; }
tr:nth-child(even) td { background: #f8fafc; }
.n { text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
.t { font-weight: 700; color: #1e3a8a; }
.b { font-weight: 600; white-space: nowrap; }
th.n { text-align: right; }
.foot { margin-top: 10px; font-size: 9px; color: #64748b; }
</style></head><body>
<div class="band"><div><h1>Scheme Vouchers</h1><div class="sub">Vouchers carrying a scheme or offer</div></div><div class="sub">${_esc(_periodLabel)}</div></div>
<div class="filters"><span>Voucher type: <b>${_esc(_typeLabel)}</b></span><span>Scheme: <b>${_esc(schemeNames)}</b></span><span>Customer group: <b>${_esc(_group ?? 'All')}</b></span><span>Customers: <b>${_esc(custNames)}</b></span></div>
<div class="tots">$tot</div>
<table><thead><tr><th>Date</th><th>Type</th><th>Voucher</th><th>Customer</th><th>Group</th><th>Scheme</th><th>Status</th><th class="n">Free qty</th><th class="n">Discount</th><th class="n">Invoice amount</th></tr></thead><tbody>$body</tbody></table>
<div class="foot">Printed $gen. Amounts are totalled per voucher type; an order appears as its SO, its DO(s) and its SI, so types are never added together.</div>
</body></html>''';
    try {
      html.document.getElementById('ops-print-frame')?.remove();
      final frame = html.IFrameElement()
        ..id = 'ops-print-frame'
        ..style.position = 'fixed'
        ..style.left = '-9999px'
        ..style.width = '0'
        ..style.height = '0'
        ..style.border = '0';
      frame.srcdoc = doc.replaceFirst('</body>',
          '<script>window.onload=function(){setTimeout(function(){try{window.focus();window.print();}catch(e){}},350);};</script></body>');
      html.document.body!.append(frame);
    } catch (_) {
      final blob = html.Blob([doc], 'text/html;charset=utf-8');
      html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
    }
  }
}
