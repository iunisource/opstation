// ignore_for_file: deprecated_member_use
import 'dart:typed_data';

import 'package:opstation_web/core/utils/friendly_error.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/pdf/pdf_output.dart';
import '../../../core/theme/app_theme.dart';

/// Sales → Fulfillment → Summary: fulfilled online-store orders with a date
/// range and filters, an item summary (average price across the selected
/// orders — the actual price when an item appears in one order only), PDF /
/// print, and "Copy to Sales Order" for one or many orders.
class ShopFulfilledSummary extends StatefulWidget {
  final String orgId;
  final String? userId;
  final String userName;
  final List<Map<String, dynamic>> stores;
  final Map<String, Map<String, dynamic>> products; // id → product (name, selling_price, base_uom_id)
  final List<Map<String, dynamic>> branches;
  const ShopFulfilledSummary({
    super.key,
    required this.orgId,
    required this.userId,
    required this.userName,
    required this.stores,
    required this.products,
    required this.branches,
  });
  @override
  State<ShopFulfilledSummary> createState() => _ShopFulfilledSummaryState();
}

/// One aggregated item line (product, or an unmatched store item by title).
class _Agg {
  final String key;
  final String? productId;
  final String name;
  double qty = 0;
  double amount = 0;
  final Set<String> orders = {};
  _Agg(this.key, this.productId, this.name);
  double get avg => qty == 0 ? 0.0 : amount / qty;
}

class _ShopFulfilledSummaryState extends State<ShopFulfilledSummary> {
  final _money = NumberFormat('#,##0.##');
  DateTimeRange _range = DateTimeRange(
    start: DateTime(DateTime.now().year, DateTime.now().month, 1),
    end: DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day),
  );
  String _dateBasis = 'fulfilled'; // fulfilled | placed
  String _store = 'all';
  String _courier = 'all';
  String _payment = 'all'; // all | cod | paid
  String _by = 'all';
  String _cityF = 'all';
  String _so = 'all'; // all | copied | not_copied
  String? _productId;
  String _q = '';
  // Spread each order's shipping charge equally over its units, so it is
  // carried in the item prices (PDF, Copy to Sales Order) instead of lost.
  bool _spreadShipping = false;
  List<Map<String, dynamic>> _rows = [];
  final Set<String> _sel = {};
  bool _loading = true;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  double _n(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
  String _qf(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(2);

  DateTime? _when(Map<String, dynamic> o) {
    final f = DateTime.tryParse('${o['fulfilled_at'] ?? ''}');
    final p = DateTime.tryParse('${o['placed_at'] ?? ''}');
    return (_dateBasis == 'placed' ? p : (f ?? p))?.toLocal();
  }

  double _collect(Map<String, dynamic> o) {
    final paid = '${o['financial_status'] ?? ''}'.toUpperCase() == 'PAID';
    final base = o['outstanding'] != null ? _n(o['outstanding']) : (paid ? 0.0 : _n(o['total']));
    if (base <= 0) return 0;
    // Items cancelled while picking were not sent — not collected either.
    final removed = _lines(o).fold<double>(0, (a, l) => a + _n(l['cancelled']) * (_n(l['price']) - _n(l['disc_each'])));
    return base - removed < 0 ? 0.0 : base - removed;
  }

  String _city(Map<String, dynamic> o) => '${((o['ship_to'] as Map?) ?? const {})['city'] ?? ''}'.trim();
  String _courierOf(Map<String, dynamic> o) =>
      '${o['tracking_company'] ?? ((o['ship_info'] as Map?) ?? const {})['company'] ?? ''}'.trim();
  String _storeName(String? id) =>
      '${widget.stores.firstWhere((s) => s['id'] == id, orElse: () => const {'name': 'Store'})['name'] ?? 'Store'}';

  List<Map<String, dynamic>> _lines(Map<String, dynamic> o) =>
      [for (final l in (o['lines'] as List? ?? const [])) Map<String, dynamic>.from(l as Map)];

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      // A little wider than the range, then exact filtering here (an order
      // closed before tracking existed has no fulfilled date → its order date).
      final from = _range.start.subtract(const Duration(days: 1)).toUtc().toIso8601String();
      final to = _range.end.add(const Duration(days: 2)).toUtc().toIso8601String();
      final out = <Map<String, dynamic>>[];
      for (var page = 0; page < 20; page++) {
        final r = await Supabase.instance.client.from('shop_orders').select()
            .eq('org_id', widget.orgId).eq('status', 'fulfilled')
            .or(_dateBasis == 'placed'
                ? 'and(placed_at.gte.$from,placed_at.lt.$to)'
                : 'and(fulfilled_at.gte.$from,fulfilled_at.lt.$to),and(fulfilled_at.is.null,placed_at.gte.$from,placed_at.lt.$to)')
            .order('placed_at', ascending: false)
            .range(page * 1000, page * 1000 + 999);
        final list = List<Map<String, dynamic>>.from(r as List);
        out.addAll(list);
        if (list.length < 1000) break;
      }
      final start = DateTime(_range.start.year, _range.start.month, _range.start.day);
      final end = DateTime(_range.end.year, _range.end.month, _range.end.day).add(const Duration(days: 1));
      if (!mounted) return;
      setState(() {
        _rows = out.where((o) {
          final t = _when(o);
          return t != null && !t.isBefore(start) && t.isBefore(end);
        }).toList();
        _sel.removeWhere((id) => !_rows.any((o) => o['id'] == id));
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  List<Map<String, dynamic>> get _visible {
    final q = _q.trim().toLowerCase();
    return _rows.where((o) {
      if (_store != 'all' && o['store_id'] != _store) return false;
      if (_courier != 'all' && _courierOf(o) != _courier) return false;
      if (_payment == 'cod' && _collect(o) <= 0) return false;
      if (_payment == 'paid' && _collect(o) > 0) return false;
      if (_by != 'all' && '${o['fulfilled_by_name'] ?? ''}' != _by) return false;
      if (_cityF != 'all' && _city(o) != _cityF) return false;
      if (_so == 'copied' && o['so_id'] == null) return false;
      if (_so == 'not_copied' && o['so_id'] != null) return false;
      if (_productId != null && !_lines(o).any((l) =>
          l['product_id'] == _productId ||
          ((l['components'] as List?) ?? const []).any((c) => (c as Map)['product_id'] == _productId))) {
        return false;
      }
      if (q.isEmpty) return true;
      return '${o['order_no']} ${o['customer_name']} ${o['phone']} ${o['tracking_number']} ${_city(o)}'
          .toLowerCase().contains(q);
    }).toList();
  }

  /// Items across [orders]: bundles are split into the products inside them
  /// (the bundle price shared by each product's selling price); the price is
  /// the average over all those orders — the actual price if only one.
  List<_Agg> _aggregate(List<Map<String, dynamic>> orders) {
    final m = <String, _Agg>{};
    for (final o in orders) {
      // Shipping per unit for this order (bundles count their products' units).
      double perUnit = 0;
      if (_spreadShipping) {
        final ship = _n(o['shipping_total']);
        double units = 0;
        for (final l in _lines(o)) {
          final q = _n(l['qty']);
          final comps = (l['components'] as List? ?? const []);
          if (comps.isNotEmpty) {
            for (final c in comps) {
              final cm = Map<String, dynamic>.from(c as Map);
              units += _n(cm['qty']) > 0 ? _n(cm['qty']) : _n(cm['per']) * q;
            }
          } else {
            units += q;
          }
        }
        if (ship > 0 && units > 0) perUnit = ship / units;
      }
      for (final l in _lines(o)) {
        final qty = _n(l['qty']);
        // The price it actually sold for: after its share of any discount code.
        final amount = (_n(l['price']) - _n(l['disc_each'])) * qty;
        final comps = [for (final c in (l['components'] as List? ?? const [])) Map<String, dynamic>.from(c as Map)];
        if (comps.isNotEmpty) {
          final weights = [
            for (final c in comps)
              (_n(c['qty']) > 0 ? _n(c['qty']) : _n(c['per']) * qty) *
                  (_n(widget.products[c['product_id']]?['selling_price']) > 0
                      ? _n(widget.products[c['product_id']]?['selling_price']) : 1),
          ];
          final wsum = weights.fold<double>(0, (a, b) => a + b);
          for (var i = 0; i < comps.length; i++) {
            final pid = '${comps[i]['product_id']}';
            final a = m.putIfAbsent(pid, () => _Agg(pid, pid, '${widget.products[pid]?['name'] ?? 'Product'}'));
            final cq = _n(comps[i]['qty']) > 0 ? _n(comps[i]['qty']) : _n(comps[i]['per']) * qty;
            a.qty += cq;
            a.amount += (wsum == 0 ? 0.0 : amount * weights[i] / wsum) + perUnit * cq;
            a.orders.add('${o['id']}');
          }
        } else if (l['product_id'] != null) {
          final pid = '${l['product_id']}';
          final a = m.putIfAbsent(pid, () => _Agg(pid, pid, '${widget.products[pid]?['name'] ?? l['title'] ?? 'Product'}'));
          a.qty += qty;
          a.amount += amount + perUnit * qty;
          a.orders.add('${o['id']}');
        } else {
          final key = 'title:${l['title']}|${l['variant_title'] ?? ''}';
          final vt = '${l['variant_title'] ?? ''}'.trim();
          final a = m.putIfAbsent(key, () => _Agg(key, null,
              '${l['title'] ?? 'Item'}${vt.isNotEmpty && vt != 'Default Title' ? ' - $vt' : ''} (not matched)'));
          a.qty += qty;
          a.amount += amount + perUnit * qty;
          a.orders.add('${o['id']}');
        }
      }
    }
    final list = m.values.toList()..sort((a, b) => b.amount.compareTo(a.amount));
    return list;
  }

  List<Map<String, dynamic>> get _target {
    final v = _visible;
    return _sel.isEmpty ? v : v.where((o) => _sel.contains(o['id'])).toList();
  }

  String get _filterText => [
        '${_dateBasis == 'placed' ? 'Ordered' : 'Fulfilled'} ${DateFormat('d MMM yyyy').format(_range.start)} - ${DateFormat('d MMM yyyy').format(_range.end)}',
        if (_store != 'all') _storeName(_store),
        if (_courier != 'all') 'Courier: $_courier',
        if (_payment != 'all') _payment == 'cod' ? 'COD only' : 'Paid only',
        if (_by != 'all') 'By: $_by',
        if (_cityF != 'all') 'City: $_cityF',
        if (_so == 'copied') 'Copied to SO',
        if (_so == 'not_copied') 'Not copied to SO',
        if (_productId != null) 'Product: ${widget.products[_productId]?['name'] ?? ''}',
        if (_q.trim().isNotEmpty) 'Search: ${_q.trim()}',
        if (_spreadShipping) 'Shipping included in item prices',
      ].join('  |  ');

  // ── PDF ──────────────────────────────────────────────────────────────────
  static String _t(Object? v) {
    final s = '${v ?? ''}'.replaceAll('—', '-').replaceAll('–', '-').replaceAll('×', 'x').replaceAll('…', '...');
    return String.fromCharCodes(s.runes.map((c) => c < 256 ? c : 0x3F));
  }

  Future<void> _pdf() async {
    final orders = _target;
    if (orders.isEmpty) return;
    final items = _aggregate(orders);
    final single = orders.length == 1;
    final cur = '${orders.first['currency'] ?? ''}';
    final total = orders.fold<double>(0, (a, o) => a + _n(o['total']));
    final cod = orders.fold<double>(0, (a, o) => a + _collect(o));
    final units = items.fold<double>(0, (a, i) => a + i.qty);
    const grey = PdfColor.fromInt(0xFF6B7280);
    const line = PdfColor.fromInt(0xFFD1D5DB);
    pw.Widget c(String s, {bool b = false, pw.TextAlign a = pw.TextAlign.left, double size = 8.5}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
        child: pw.Text(_t(s), textAlign: a, style: pw.TextStyle(fontSize: size, fontWeight: b ? pw.FontWeight.bold : null)));
    final doc = pw.Document(title: 'Fulfilled orders');
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      footer: (ctx) => pw.Align(alignment: pw.Alignment.centerRight,
          child: pw.Text('Printed by ${_t(widget.userName)}, ${DateFormat('d MMM yyyy HH:mm').format(DateTime.now())}   ·   ${ctx.pageNumber}/${ctx.pagesCount}'
              .replaceAll('·', '-'), style: const pw.TextStyle(fontSize: 7.5, color: grey))),
      build: (_) => [
        pw.Text(single ? 'Fulfilled order ${_t(orders.first['order_no'])}' : 'Fulfilled orders summary',
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.Text(_t(_filterText), style: const pw.TextStyle(fontSize: 8.5, color: grey)),
        if (_sel.isNotEmpty && !single) pw.Text('${orders.length} selected orders', style: const pw.TextStyle(fontSize: 8.5, color: grey)),
        pw.SizedBox(height: 10),
        pw.Row(children: [
          for (final k in [
            ('Orders', '${orders.length}'),
            ('Units', _qf(units)),
            ('Order value', '$cur ${_money.format(total)}'),
            ('COD to collect', '$cur ${_money.format(cod)}'),
            if (_spreadShipping) ('Shipping (in prices)', '$cur ${_money.format(orders.fold<double>(0, (a, o) => a + _n(o['shipping_total'])))}'),
          ])
            pw.Expanded(child: pw.Container(
              margin: const pw.EdgeInsets.only(right: 6),
              padding: const pw.EdgeInsets.all(6),
              decoration: pw.BoxDecoration(border: pw.Border.all(color: line)),
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text(k.$1, style: const pw.TextStyle(fontSize: 7.5, color: grey)),
                pw.Text(_t(k.$2), style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
              ]),
            )),
        ]),
        pw.SizedBox(height: 12),
        pw.Text('Items', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        pw.Text(single ? 'Prices as sold (after any discount code).'
            : 'Price = what it sold for (after any discount code), averaged across the selected orders — '
              'the actual price where an item is in one order only. Bundle prices are shared across the products inside them.',
            style: const pw.TextStyle(fontSize: 7.5, color: grey)),
        if (_spreadShipping)
          pw.Text('Shipping charges (${_t(cur)} ${_money.format(orders.fold<double>(0, (a, o) => a + _n(o['shipping_total'])))}) '
              'are included: each order\'s shipping is divided equally over its units and added to their prices.',
              style: pw.TextStyle(fontSize: 7.5, color: grey, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Table(
          border: pw.TableBorder(horizontalInside: const pw.BorderSide(color: line, width: 0.5),
              bottom: const pw.BorderSide(color: line, width: 0.5)),
          columnWidths: {
            0: const pw.FixedColumnWidth(18), 1: const pw.FlexColumnWidth(), 2: const pw.FixedColumnWidth(40),
            3: const pw.FixedColumnWidth(40), 4: const pw.FixedColumnWidth(62), 5: const pw.FixedColumnWidth(70),
          },
          children: [
            pw.TableRow(decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F4F6)), children: [
              c('#', b: true), c('Item', b: true), c('Orders', b: true, a: pw.TextAlign.right), c('Qty', b: true, a: pw.TextAlign.right),
              c(single ? 'Price' : 'Avg price', b: true, a: pw.TextAlign.right), c('Amount', b: true, a: pw.TextAlign.right),
            ]),
            for (var i = 0; i < items.length; i++)
              pw.TableRow(children: [
                c('${i + 1}'), c(items[i].name), c('${items[i].orders.length}', a: pw.TextAlign.right),
                c(_qf(items[i].qty), a: pw.TextAlign.right, b: true),
                c(_money.format(items[i].avg), a: pw.TextAlign.right),
                c(_money.format(items[i].amount), a: pw.TextAlign.right, b: true),
              ]),
          ],
        ),
        pw.SizedBox(height: 14),
        pw.Text('Orders', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Table(
          border: pw.TableBorder(horizontalInside: const pw.BorderSide(color: line, width: 0.5),
              bottom: const pw.BorderSide(color: line, width: 0.5)),
          columnWidths: {
            0: const pw.FixedColumnWidth(48), 1: const pw.FixedColumnWidth(54), 2: const pw.FlexColumnWidth(),
            3: const pw.FixedColumnWidth(58), 4: const pw.FixedColumnWidth(80), 5: const pw.FixedColumnWidth(60), 6: const pw.FixedColumnWidth(36),
          },
          children: [
            pw.TableRow(decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F4F6)), children: [
              c('Order', b: true), c('Date', b: true), c('Customer', b: true), c('City', b: true),
              c('Courier / tracking', b: true), c('Total', b: true, a: pw.TextAlign.right), c('Pay', b: true),
            ]),
            for (final o in orders)
              pw.TableRow(children: [
                c('${o['order_no'] ?? ''}', b: true),
                c(_when(o) == null ? '' : DateFormat('d MMM yy').format(_when(o)!)),
                c('${o['customer_name'] ?? ''}${'${o['phone'] ?? ''}'.isNotEmpty ? '\n${o['phone']}' : ''}'),
                c(_city(o)),
                c([_courierOf(o), '${o['tracking_number'] ?? ''}'].where((x) => x.isNotEmpty).join('\n')),
                c(_money.format(_n(o['total'])), a: pw.TextAlign.right),
                c(_collect(o) > 0 ? 'COD' : 'Paid'),
              ]),
          ],
        ),
      ],
    ));
    final Uint8List bytes = await doc.save();
    await showPdf(bytes, single ? 'Fulfilled ${orders.first['order_no'] ?? ''}' : 'Fulfilled orders');
  }

  // ── Copy to Sales Order ──────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> _customers() async {
    final out = <Map<String, dynamic>>[];
    for (var p = 0; p < 20; p++) {
      final r = await Supabase.instance.client.from('customers').select('id, shop_name, phone')
          .eq('org_id', widget.orgId).order('shop_name').range(p * 1000, p * 1000 + 999);
      final l = List<Map<String, dynamic>>.from(r as List);
      out.addAll(l);
      if (l.length < 1000) break;
    }
    return out;
  }

  Future<void> _copyToSo() async {
    final orders = _target;
    if (orders.isEmpty) return;
    final already = orders.where((o) => o['so_id'] != null).toList();
    final items = _aggregate(orders);
    final unmatched = items.where((i) => i.productId == null).toList();
    final usable = items.where((i) => i.productId != null && i.qty > 0).toList();
    if (usable.isEmpty) { _snack('None of these items are matched to products — match them first.'); return; }

    final store = widget.stores.firstWhere((s) => s['id'] == orders.first['store_id'], orElse: () => const {});
    String? branch = store['branch_id'] as String?;
    if (branch != null && !widget.branches.any((b) => b['id'] == branch)) branch = null;
    branch ??= widget.branches.isNotEmpty ? widget.branches.first['id'] as String : null;
    Map<String, dynamic>? customer;
    var custs = <Map<String, dynamic>>[];
    try {
      custs = await _customers();
    } catch (e) {
      _snack(friendlyError('Could not load customers', e));
      return;
    }
    final remembered = store['so_customer_id'];
    customer = custs.cast<Map<String, dynamic>?>().firstWhere((c) => c!['id'] == remembered, orElse: () => null);
    var search = '';
    if (!mounted) return;
    final go = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, setD) {
      final filtered = custs.where((c) => search.isEmpty ||
          '${c['shop_name']} ${c['phone']}'.toLowerCase().contains(search.toLowerCase())).take(60).toList();
      return AlertDialog(
        title: Text('Copy ${orders.length} order${orders.length == 1 ? '' : 's'} to a Sales Order'),
        content: SizedBox(width: 520, height: 470, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${usable.length} item line${usable.length == 1 ? '' : 's'}, ${_qf(usable.fold<double>(0, (a, i) => a + i.qty))} units. '
              '${orders.length > 1 ? 'Same products are combined at their average price.' : 'Prices as sold.'}',
              style: const TextStyle(fontSize: 12.5)),
          if (already.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(
                '⚠ ${already.length} of these were already copied (${already.map((o) => '${o['order_no']} → ${o['so_number'] ?? 'SO'}').take(4).join(', ')}). '
                'They will be copied again.',
                style: const TextStyle(fontSize: 12, color: Colors.deepOrange, fontWeight: FontWeight.w600))),
          if (unmatched.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(
                '${unmatched.length} item(s) not matched to a product are left out: ${unmatched.map((u) => u.name).take(3).join(', ')}',
                style: const TextStyle(fontSize: 12, color: Colors.deepOrange))),
          const SizedBox(height: 10),
          DropdownButtonFormField<String?>(
            value: branch, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Branch', isDense: true, border: OutlineInputBorder()),
            items: [for (final b in widget.branches) DropdownMenuItem<String?>(value: b['id'] as String, child: Text('${b['name'] ?? ''}'))],
            onChanged: (v) => setD(() => branch = v),
          ),
          const SizedBox(height: 10),
          Text(customer == null ? 'Customer' : 'Customer: ${customer!['shop_name']}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          TextField(
            decoration: const InputDecoration(hintText: 'Search customer…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
            onChanged: (v) => setD(() => search = v),
          ),
          Expanded(child: ListView(children: [
            for (final c in filtered)
              ListTile(
                dense: true,
                selected: customer?['id'] == c['id'],
                selectedTileColor: AppTheme.primary.withOpacity(0.08),
                title: Text('${c['shop_name'] ?? '-'}'),
                subtitle: (c['phone'] as String?)?.isNotEmpty == true ? Text('${c['phone']}') : null,
                onTap: () => setD(() => customer = c),
              ),
          ])),
          const Text('The customer is remembered for this store.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: customer == null || branch == null ? null : () => Navigator.of(d, rootNavigator: true).pop(true),
            child: const Text('Create draft SO'),
          ),
        ],
      );
    }));
    if (go != true || customer == null || branch == null) return;
    setState(() => _working = true);
    final client = Supabase.instance.client;
    try {
      String? vnum;
      try {
        vnum = await client.rpc('next_voucher_number', params: {
          'p_org_id': widget.orgId, 'p_branch_id': branch, 'p_type': 'SO', 'p_year': DateTime.now().year,
        }) as String?;
      } catch (_) { vnum = null; }
      final soId = 'so_${DateTime.now().microsecondsSinceEpoch}';
      final nos = orders.map((o) => '${o['order_no'] ?? ''}').where((x) => x.isNotEmpty).toList();
      final soRow = <String, dynamic>{
        'id': soId,
        'org_id': widget.orgId,
        'customer_id': customer!['id'],
        'branch_id': branch,
        'status': 'draft',
        'is_locked': false,
        'source': 'online_store',
        'voucher_number': vnum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'notes': 'From online orders ${nos.take(30).join(', ')}${nos.length > 30 ? ' +${nos.length - 30} more' : ''}'
            ' (${_storeName(orders.first['store_id'] as String?)})',
        'created_by': widget.userId,
        'ordered_at': DateTime.now().toUtc().toIso8601String(),
      };
      try {
        await client.from('sales_orders').insert(soRow);
      } catch (e) {
        // Older setups only accept their own "source" values — save without it.
        if (!'$e'.toLowerCase().contains('source') && !'$e'.toLowerCase().contains('check')) rethrow;
        await client.from('sales_orders').insert(Map.of(soRow)..remove('source'));
      }
      var i = 0;
      await client.from('sales_order_items').insert([
        for (final it in usable)
          {
            'id': 'soi_${DateTime.now().microsecondsSinceEpoch}_${i++}',
            'sales_order_id': soId,
            'product_id': it.productId,
            'uom_id': widget.products[it.productId]?['base_uom_id'],
            'quantity': it.qty,
            'unit_price': double.parse(it.avg.toStringAsFixed(2)),
            'discount': 0,
            'qty_delivered': 0,
            'is_foc': false,
          },
      ]);
      await client.from('shop_orders').update({'so_id': soId, 'so_number': vnum})
          .inFilter('id', [for (final o in orders) o['id']]);
      try {
        await client.from('shop_stores').update({'so_customer_id': customer!['id']}).eq('id', orders.first['store_id']);
        if (store.isNotEmpty) store['so_customer_id'] = customer!['id'];
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        for (final o in orders) { o['so_id'] = soId; o['so_number'] = vnum; }
        _working = false;
        _sel.clear();
      });
      _snack('Draft SO ${vnum ?? ''} created from ${orders.length} order${orders.length == 1 ? '' : 's'} — open it in Sales Orders');
    } catch (e) {
      if (mounted) setState(() => _working = false);
      _snack(friendlyError('Could not create the SO', e));
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  Widget _dd(String label, String value, List<(String, String)> opts, ValueChanged<String> on, {double width = 160}) => SizedBox(
        width: width,
        child: DropdownButtonFormField<String>(
          value: opts.any((o) => o.$1 == value) ? value : 'all', isExpanded: true,
          decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
          items: [for (final o in opts) DropdownMenuItem(value: o.$1, child: Text(o.$2, overflow: TextOverflow.ellipsis))],
          onChanged: (v) { on(v ?? 'all'); setState(() {}); },
        ),
      );

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context, firstDate: DateTime(2024), lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: _range,
    );
    if (r == null) return;
    setState(() => _range = r);
    _load();
  }

  void _preset(String p) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      _range = switch (p) {
        'today' => DateTimeRange(start: today, end: today),
        'yesterday' => DateTimeRange(start: today.subtract(const Duration(days: 1)), end: today.subtract(const Duration(days: 1))),
        '7' => DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today),
        'month' => DateTimeRange(start: DateTime(now.year, now.month, 1), end: today),
        'last_month' => DateTimeRange(start: DateTime(now.year, now.month - 1, 1), end: DateTime(now.year, now.month, 0)),
        _ => _range,
      };
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    final target = _target;
    final items = _aggregate(target);
    final cur = rows.isNotEmpty ? '${rows.first['currency'] ?? ''}' : '';
    final total = target.fold<double>(0, (a, o) => a + _n(o['total']));
    final cod = target.fold<double>(0, (a, o) => a + _collect(o));
    final units = items.fold<double>(0, (a, i) => a + i.qty);
    final couriers = {for (final o in _rows) _courierOf(o)}..remove('');
    final bys = {for (final o in _rows) '${o['fulfilled_by_name'] ?? ''}'}..remove('');
    final cities = {for (final o in _rows) _city(o)}..remove('');
    final productIds = <String>{};
    for (final o in _rows) {
      for (final l in _lines(o)) {
        if (l['product_id'] != null) productIds.add('${l['product_id']}');
        for (final c in (l['components'] as List? ?? const [])) { productIds.add('${(c as Map)['product_id']}'); }
      }
    }
    final allSel = rows.isNotEmpty && rows.every((o) => _sel.contains(o['id']));
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // filters
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.date_range, size: 18),
              label: Text('${DateFormat('d MMM').format(_range.start)} – ${DateFormat('d MMM yyyy').format(_range.end)}'),
              onPressed: _pickRange,
            ),
            PopupMenuButton<String>(
              tooltip: 'Quick dates',
              onSelected: _preset,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'today', child: Text('Today')),
                PopupMenuItem(value: 'yesterday', child: Text('Yesterday')),
                PopupMenuItem(value: '7', child: Text('Last 7 days')),
                PopupMenuItem(value: 'month', child: Text('This month')),
                PopupMenuItem(value: 'last_month', child: Text('Last month')),
              ],
              child: const Padding(padding: EdgeInsets.all(6), child: Icon(Icons.bolt, size: 20)),
            ),
            _dd('Date by', _dateBasis, const [('fulfilled', 'Fulfilled date'), ('placed', 'Order date')],
                (v) { _dateBasis = v == 'all' ? 'fulfilled' : v; _load(); }, width: 150),
            if (widget.stores.length > 1)
              _dd('Store', _store, [('all', 'All stores'), for (final s in widget.stores) ('${s['id']}', '${s['name'] ?? s['shop_domain']}')],
                  (v) => _store = v),
            _dd('Courier', _courier, [('all', 'All couriers'), for (final c in couriers.toList()..sort()) (c, c)], (v) => _courier = v),
            _dd('Payment', _payment, const [('all', 'COD + paid'), ('cod', 'COD only'), ('paid', 'Paid only')], (v) => _payment = v, width: 130),
            _dd('Fulfilled by', _by, [('all', 'Anyone'), for (final b in bys.toList()..sort()) (b, b)], (v) => _by = v),
            _dd('City', _cityF, [('all', 'All cities'), for (final c in cities.toList()..sort()) (c, c)], (v) => _cityF = v, width: 140),
            _dd('Sales order', _so, const [('all', 'All'), ('not_copied', 'Not copied'), ('copied', 'Copied')], (v) => _so = v, width: 130),
            SizedBox(width: 220, child: DropdownButtonFormField<String?>(
              value: productIds.contains(_productId) ? _productId : null, isExpanded: true,
              decoration: const InputDecoration(labelText: 'Product', isDense: true, border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('All products')),
                for (final id in (productIds.toList()..sort((a, b) => '${widget.products[a]?['name']}'.compareTo('${widget.products[b]?['name']}'))))
                  DropdownMenuItem<String?>(value: id, child: Text('${widget.products[id]?['name'] ?? id}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _productId = v),
            )),
            SizedBox(width: 220, child: TextField(
              decoration: const InputDecoration(hintText: 'Order, customer, phone, tracking…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
              onChanged: (v) => setState(() => _q = v),
            )),
          ]),
        ),
        // totals + actions
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final k in [
              (_sel.isEmpty ? 'Orders' : 'Selected', '${target.length}'),
              ('Units', _qf(units)),
              ('Order value', '$cur ${_money.format(total)}'.trim()),
              ('COD to collect', '$cur ${_money.format(cod)}'.trim()),
            ])
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(k.$1, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  Text(k.$2, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                ]),
              ),
            Tooltip(
              message: 'Each order\'s shipping charge is divided equally over all the units in that order and added to '
                  'their prices — in the item list, the PDF and Copy to Sales Order — so it isn\'t left out.',
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => setState(() => _spreadShipping = !_spreadShipping),
                child: Container(
                  padding: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: _spreadShipping ? AppTheme.primary.withOpacity(0.06) : Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _spreadShipping ? AppTheme.primary : AppTheme.border)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Checkbox(value: _spreadShipping, onChanged: (v) => setState(() => _spreadShipping = v == true)),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      const Text('Add shipping to item prices', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                      Text('Shipping $cur ${_money.format(target.fold<double>(0, (a, o) => a + _n(o['shipping_total'])))}'.trim(),
                          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ]),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
              label: Text(_sel.isEmpty ? 'PDF / Print all' : 'PDF / Print ${_sel.length}'),
              onPressed: target.isEmpty ? null : _pdf,
            ),
            FilledButton.icon(
              icon: _working
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.receipt_long_outlined, size: 18),
              label: Text(_sel.isEmpty ? 'Copy to Sales Order' : 'Copy ${_sel.length} to Sales Order'),
              onPressed: target.isEmpty || _working ? null : _copyToSo,
            ),
          ]),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.danger)))
                  : rows.isEmpty
                      ? const Center(child: Text('No fulfilled orders for these filters.', style: TextStyle(color: AppTheme.textSecondary)))
                      : LayoutBuilder(builder: (context, cons) {
                          final wide = cons.maxWidth > 1100;
                          final orderList = _orderTable(rows, allSel);
                          final itemList = _itemsPanel(items);
                          return wide
                              ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                                  Expanded(flex: 3, child: orderList),
                                  const VerticalDivider(width: 1),
                                  Expanded(flex: 2, child: itemList),
                                ])
                              : DefaultTabController(length: 2, child: Column(children: [
                                  const TabBar(tabs: [Tab(text: 'Orders'), Tab(text: 'Items')]),
                                  Expanded(child: TabBarView(children: [orderList, itemList])),
                                ]));
                        }),
        ),
      ]),
    );
  }

  Widget _orderTable(List<Map<String, dynamic>> rows, bool allSel) => Column(children: [
        Container(
          color: AppTheme.background,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: [
            Checkbox(value: allSel, tristate: false, onChanged: (v) => setState(() {
              if (v == true) { _sel.addAll(rows.map((o) => o['id'] as String)); } else { _sel.clear(); }
            })),
            Text(_sel.isEmpty ? '${rows.length} orders — tick to select' : '${_sel.length} selected',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            const Spacer(),
            if (_sel.isNotEmpty) TextButton(onPressed: () => setState(_sel.clear), child: const Text('Clear')),
          ]),
        ),
        Expanded(child: ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final o = rows[i];
            final t = _when(o);
            final collect = _collect(o);
            final courier = _courierOf(o);
            return InkWell(
              onTap: () => setState(() => _sel.contains(o['id']) ? _sel.remove(o['id']) : _sel.add(o['id'] as String)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(children: [
                  Checkbox(value: _sel.contains(o['id']), onChanged: (v) => setState(() => v == true ? _sel.add(o['id'] as String) : _sel.remove(o['id']))),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text('${o['order_no'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(width: 8),
                      Text(t == null ? '' : DateFormat('d MMM, HH:mm').format(t), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                      if (o['so_id'] != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(color: Colors.indigo.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                          child: Text('SO ${o['so_number'] ?? ''}'.trim(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.indigo)),
                        ),
                      ],
                    ]),
                    Text([
                      '${o['customer_name'] ?? '—'}',
                      if (_city(o).isNotEmpty) _city(o),
                      if (courier.isNotEmpty) '$courier ${o['tracking_number'] ?? ''}'.trim(),
                      if (o['fulfilled_by_name'] != null) 'by ${o['fulfilled_by_name']}',
                    ].join(' · '), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ])),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('${o['currency'] ?? ''} ${_money.format(_n(o['total']))}'.trim(), style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(collect > 0 ? 'COD' : 'Paid', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800,
                        color: collect > 0 ? Colors.orange.shade800 : Colors.green.shade700)),
                  ]),
                  const SizedBox(width: 6),
                ]),
              ),
            );
          },
        )),
      ]);

  Widget _itemsPanel(List<_Agg> items) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          color: AppTheme.background,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Text(
            _sel.length == 1
                ? 'Items in the selected order (actual prices)'
                : 'Items in ${_sel.isEmpty ? 'these' : 'the selected'} orders — average price (actual if in one order)',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
        ),
        Expanded(child: ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final it = items[i];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(it.name, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600,
                      color: it.productId == null ? Colors.deepOrange : null)),
                  Text('in ${it.orders.length} order${it.orders.length == 1 ? '' : 's'} · '
                      '${it.orders.length == 1 ? 'price' : 'avg'} ${_money.format(it.avg)}',
                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ])),
                Text('× ${_qf(it.qty)}', style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(width: 12),
                SizedBox(width: 90, child: Text(_money.format(it.amount), textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w700))),
              ]),
            );
          },
        )),
      ]);
}
