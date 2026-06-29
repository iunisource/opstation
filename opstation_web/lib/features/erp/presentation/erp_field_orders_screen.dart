import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'dart:js_util' as js_util;
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

/// Field Orders review queue. Salespeople submit orders from the mobile app;
/// an admin reviews here, may edit qty / remove / add lines, then Approves
/// (-> a draft Sales Order via approve_field_order) or Rejects.
class ErpFieldOrdersScreen extends ConsumerStatefulWidget {
  const ErpFieldOrdersScreen({super.key});
  @override
  ConsumerState<ErpFieldOrdersScreen> createState() => _ErpFieldOrdersScreenState();
}

class _ErpFieldOrdersScreenState extends ConsumerState<ErpFieldOrdersScreen> {
  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _userId => ref.read(currentUserProvider)?.id;
  String? get _currentBranchId => ref.read(selectedBranchProvider)?['id'] as String?;

  String _filter = 'submitted';
  DateTime? _fromDate;                          // review-date range (approved/rejected)
  DateTime? _toDate;
  bool _loading = true, _saving = false;
  List<Map<String, dynamic>> _orders = [];
  final Map<String, String> _custNames = {};
  final Map<String, String> _spNames = {};
  // product catalog: id -> {name, selling_price, base_uom_id}
  final Map<String, Map<String, dynamic>> _products = {};

  Map<String, dynamic>? _selected;          // the order open for review
  List<Map<String, dynamic>> _lines = [];    // editable line list
  RealtimeChannel? _channel;
  int _newWhileAway = 0;                      // submitted arrivals while not on Submitted filter
  List<Map<String, dynamic>> _branches = [];
  String? _approveBranchId;                    // branch chosen for the order under review
  bool _soundOn = true;                        // new-order chime enabled (persisted)
  bool _audioHintShown = false;                // one-time "click to enable sound" nudge

  @override
  void initState() {
    super.initState();
    _installAudio();
    _restoreSoundPref();
    _loadProducts();
    _loadOrders();
    _loadBranches();
    _subscribe();
  }

  Future<void> _loadBranches() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final b = await Supabase.instance.client.from('branches')
          .select('id, name').eq('org_id', orgId).eq('is_active', true).order('name');
      if (mounted) setState(() => _branches = List<Map<String, dynamic>>.from(b));
    } catch (_) {}
  }

  @override
  void dispose() {
    final ch = _channel;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    super.dispose();
  }

  void _subscribe() {
    final orgId = _orgId; if (orgId == null) return;
    _channel = Supabase.instance.client
        .channel('field_orders_$orgId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'field_orders',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'org_id', value: orgId),
          callback: (payload) => _onNewOrder(payload.newRecord),
        )
        .subscribe();
  }

  Future<void> _onNewOrder(Map<String, dynamic> row) async {
    if ((row['status'] as String?) != 'submitted') return;
    _playNewOrderTone();
    _maybeWarnAudioBlocked();
    ref.invalidate(fieldOrderPendingCountProvider); // bump the nav badge live
    if (_filter == 'submitted') {
      // resolve names then prepend silently
      final cid = row['customer_id'] as String?;
      final sid = row['salesperson_id'] as String?;
      try {
        if (cid != null && !_custNames.containsKey(cid)) {
          final c = await Supabase.instance.client.from('customers').select('shop_name').eq('id', cid).maybeSingle();
          if (c != null) _custNames[cid] = (c['shop_name'] as String?) ?? '—';
        }
        if (sid != null && !_spNames.containsKey(sid)) {
          final u = await Supabase.instance.client.from('users').select('name').eq('id', sid).maybeSingle();
          if (u != null) _spNames[sid] = (u['name'] as String?) ?? '—';
        }
      } catch (_) {}
      if (!mounted) return;
      if (!_orders.any((o) => o['id'] == row['id'])) {
        setState(() => _orders = [row, ..._orders]);
      }
    } else {
      // on another filter: just badge the Submitted chip
      if (!mounted) return;
      setState(() => _newWhileAway += 1);
    }
  }

  // ---------------------------------------------------------------------------
  // New-order chime (web).
  //
  // Previous version created a brand-new AudioContext on every tone. Two bugs:
  //   1) A context created without a prior user gesture starts SUSPENDED, so it
  //      stays silent on a passive monitor screen (Chrome autoplay policy).
  //   2) Contexts were never closed; the browser caps them (~6/page), after which
  //      `new AudioContext()` throws and sound dies for the rest of the session.
  //
  // Now: one cached context, resumed on the first user gesture (listeners are
  // installed once by the bootstrap below) and on demand; both ding-dong tones
  // are scheduled on that single context via currentTime offsets (no
  // Future.delayed, which Chrome throttles in background tabs).
  // ---------------------------------------------------------------------------
  static const String _audioBootstrapJs =
      '(function(){'
      'if(window.__foAudio2)return;'
      'var F=window.AudioContext||window.webkitAudioContext;var ctx=null;'
      'function get(){if(!ctx){try{ctx=new F();}catch(e){return null;}}return ctx;}'
      'function unlock(){var c=get();if(c&&c.state==="suspended"){try{c.resume();}catch(e){}}}'
      'function beep(freq,dur,type,when,gain){var c=get();if(!c)return;'
      'if(c.state==="suspended"){try{c.resume();}catch(e){}}'
      'try{var t0=c.currentTime+(when||0);var o=c.createOscillator();var g=c.createGain();'
      'o.connect(g);g.connect(c.destination);o.type=type||"sine";o.frequency.value=freq;'
      'g.gain.setValueAtTime(gain||0.3,t0);g.gain.exponentialRampToValueAtTime(0.001,t0+dur);'
      'o.start(t0);o.stop(t0+dur);}catch(e){}}'
      'function state(){var c=get();return c?c.state:"none";}'
      '["pointerdown","keydown","touchstart","mousedown"].forEach(function(ev){'
      'window.addEventListener(ev,unlock,{passive:true});});'
      'window.__foAudio2={unlock:unlock,beep:beep,state:state};window.__foAudio=window.__foAudio2;'
      '})();';

  void _installAudio() {
    try { js_util.callMethod(js_util.globalThis, 'eval', [_audioBootstrapJs]); } catch (_) {}
  }

  void _unlockAudio() {
    try { js_util.callMethod(js_util.globalThis, 'eval', ['window.__foAudio&&window.__foAudio.unlock()']); } catch (_) {}
  }

  void _restoreSoundPref() {
    try {
      final v = js_util.callMethod(js_util.globalThis, 'eval', ['window.localStorage.getItem("fo_sound")']);
      if (v == 'off') _soundOn = false;
    } catch (_) {}
  }

  void _toggleSound() {
    setState(() => _soundOn = !_soundOn);
    try {
      js_util.callMethod(js_util.globalThis, 'eval',
          ['window.localStorage.setItem("fo_sound","${_soundOn ? 'on' : 'off'}")']);
    } catch (_) {}
    if (_soundOn) {
      _audioHintShown = true;          // arming counts as the gesture; no nudge needed
      _unlockAudio();                  // runs inside the click handler => valid gesture
      // short confirmation blip so the dispatcher hears it's armed
      try { js_util.callMethod(js_util.globalThis, 'eval', ['window.__foAudio&&window.__foAudio.beep(740,0.12,"sine",0)']); } catch (_) {}
    }
  }

  // Distinct two-tone "ding-dong" (different from the POS rising chime),
  // both tones scheduled on the one shared context.
  void _playNewOrderTone() {
    if (!_soundOn) return;
    try {
      js_util.callMethod(js_util.globalThis, 'eval', [
        'if(window.__foAudio){window.__foAudio.beep(659.25,0.55,"triangle",0,0.9);'
        'window.__foAudio.beep(523.25,0.95,"triangle",0.30,0.9);}'
      ]);
    } catch (_) {}
  }

  // If an order lands before the page has ever been interacted with, the audio
  // context is still suspended and the chime can't play. Nudge the user once.
  void _maybeWarnAudioBlocked() {
    if (_audioHintShown || !_soundOn) return;
    try {
      final s = js_util.callMethod(js_util.globalThis, 'eval',
          ['(window.__foAudio&&window.__foAudio.state&&window.__foAudio.state())||"none"']);
      if (s == 'suspended' || s == 'none') {
        _audioHintShown = true;
        if (mounted) _snack('🔔 Click anywhere on the page once to enable the new-order sound.');
      }
    } catch (_) {}
  }

  Future<void> _loadProducts() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final p = await Supabase.instance.client.from('products')
          .select('id, name, sku, base_uom_id, selling_price')
          .eq('org_id', orgId).eq('is_active', true).order('name').limit(10000);
      for (final r in p as List) {
        _products[r['id'] as String] = {
          'name': r['name'], 'sku': r['sku'],
          'selling_price': (r['selling_price'] as num?)?.toDouble() ?? 0,
          'base_uom_id': r['base_uom_id'],
        };
      }
    } catch (_) {}
  }

  Future<void> _loadOrders() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      var q = client.from('field_orders')
          .select('*').eq('org_id', orgId).eq('status', _filter);
      // Approved/Rejected can be narrowed by review-date range.
      if (_filter != 'submitted' && _fromDate != null) {
        q = q.gte('reviewed_at', _fromDate!.toUtc().toIso8601String());
      }
      if (_filter != 'submitted' && _toDate != null) {
        final end = DateTime(_toDate!.year, _toDate!.month, _toDate!.day, 23, 59, 59);
        q = q.lte('reviewed_at', end.toUtc().toIso8601String());
      }
      final orders = List<Map<String, dynamic>>.from(await q.order('submitted_at', ascending: false));
      final custIds = orders.map((o) => o['customer_id'] as String?).whereType<String>().toSet().toList();
      // salespeople + reviewers are both users — resolve all names in one lookup
      final userIds = {
        ...orders.map((o) => o['salesperson_id'] as String?).whereType<String>(),
        ...orders.map((o) => o['reviewed_by'] as String?).whereType<String>(),
      }.toList();
      if (custIds.isNotEmpty) {
        final cs = await client.from('customers').select('id, shop_name').inFilter('id', custIds);
        for (final c in cs as List) { _custNames[c['id'] as String] = (c['shop_name'] as String?) ?? '—'; }
      }
      if (userIds.isNotEmpty) {
        final us = await client.from('users').select('id, name').inFilter('id', userIds);
        for (final u in us as List) { _spNames[u['id'] as String] = (u['name'] as String?) ?? '—'; }
      }
      setState(() { _orders = orders; _loading = false; });
    } catch (e) { _snack('Load error: $e'); setState(() => _loading = false); }
  }

  Future<void> _openOrder(Map<String, dynamic> o) async {
    setState(() { _selected = o; _lines = []; _approveBranchId = (o['branch_id'] as String?) ?? _currentBranchId; });
    try {
      final items = await Supabase.instance.client.from('field_order_items')
          .select('*').eq('field_order_id', o['id'] as String);
      setState(() {
        _lines = (items as List).map((r) {
          final pid = r['product_id'] as String;
          final p = _products[pid] ?? const {};
          return <String, dynamic>{
            'id': r['id'], 'product_id': pid, 'uom_id': r['uom_id'] ?? p['base_uom_id'],
            'quantity': (r['quantity'] as num?)?.toDouble() ?? 0,
            'price_at_submit': (r['price_at_submit'] as num?)?.toDouble(),
            'name': p['name'] ?? pid, 'price': (p['selling_price'] as double?) ?? 0,
          };
        }).toList();
      });
    } catch (e) { _snack('Could not load lines: $e'); }
  }

  double get _total => _lines.fold(0.0, (s, l) => s + ((l['quantity'] as double) * (l['price'] as double)));

  void _addLine() {
    final searchCtrl = TextEditingController();
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
      final q = searchCtrl.text.trim().toLowerCase();
      final matches = _products.entries.where((e) {
        if (q.isEmpty) return true;
        final n = (e.value['name'] as String? ?? '').toLowerCase();
        final s = (e.value['sku'] as String? ?? '').toLowerCase();
        return n.contains(q) || s.contains(q);
      }).take(40).toList();
      return AlertDialog(
        title: const Text('Add Product'),
        content: SizedBox(width: 460, height: 460, child: Column(children: [
          TextField(controller: searchCtrl, autofocus: true, onChanged: (_) => setLocal(() {}),
            decoration: const InputDecoration(hintText: 'Search name or SKU…', prefixIcon: Icon(Icons.search), isDense: true)),
          const SizedBox(height: 8),
          Expanded(child: ListView.builder(itemCount: matches.length, itemBuilder: (_, i) {
            final e = matches[i];
            final price = (e.value['selling_price'] as double?) ?? 0;
            final already = _lines.any((l) => l['product_id'] == e.key);
            return ListTile(dense: true,
              title: Text(e.value['name'] as String? ?? e.key, style: const TextStyle(fontSize: 13)),
              subtitle: Text('${e.value['sku'] ?? ''}  ·  Rs. ${price.toStringAsFixed(2)}', style: const TextStyle(fontSize: 11)),
              trailing: already ? const Icon(Icons.check, size: 16, color: AppTheme.success) : const Icon(Icons.add, size: 18),
              onTap: already ? null : () {
                setState(() => _lines.add({
                  'id': 'foi_${DateTime.now().microsecondsSinceEpoch}',
                  'product_id': e.key, 'uom_id': e.value['base_uom_id'],
                  'quantity': 1.0, 'price_at_submit': price,
                  'name': e.value['name'] ?? e.key, 'price': price,
                }));
                Navigator.pop(ctx);
              });
          })),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      );
    }));
  }

  Future<void> _approve() async {
    final o = _selected; if (o == null) return;
    if (_lines.isEmpty) { _snack('Add at least one line before approving'); return; }
    if (_lines.any((l) => (l['quantity'] as double) <= 0)) { _snack('Every line needs a quantity above zero'); return; }
    if (_approveBranchId == null) { _snack('Select a branch for this order'); return; }
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Approve order?'),
      content: Text('This creates a draft Sales Order for ${_custNames[o['customer_id']] ?? 'this customer'} with ${_lines.length} line(s), priced at current rates. You can finalise and lock it in Sales Orders.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Approve')),
      ]));
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final foId = o['id'] as String;
      // persist the (possibly edited) lines: replace all items for this order
      await client.from('field_order_items').delete().eq('field_order_id', foId);
      await client.from('field_order_items').insert(_lines.map((l) => {
        'id': l['id'], 'field_order_id': foId, 'product_id': l['product_id'],
        'uom_id': l['uom_id'], 'quantity': l['quantity'], 'price_at_submit': l['price_at_submit'],
      }).toList());
      final soId = await client.rpc('approve_field_order', params: {'p_id': foId, 'p_user': _userId, 'p_branch': _approveBranchId});
      final soNum = await client.from('sales_orders').select('voucher_number').eq('id', soId as String).maybeSingle();
      if (!mounted) return;
      setState(() { _saving = false; _selected = null; });
      _snack('Approved — draft ${soNum?['voucher_number'] ?? 'Sales Order'} created');
      ref.invalidate(fieldOrderPendingCountProvider);
      _loadOrders();
    } catch (e) { _snack('Approve failed: $e'); setState(() => _saving = false); }
  }

  Future<void> _reject() async {
    final o = _selected; if (o == null) return;
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Reject order?'),
      content: TextField(controller: reasonCtrl, autofocus: true, maxLines: 3,
        decoration: const InputDecoration(hintText: 'Reason (optional)')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
          onPressed: () => Navigator.pop(ctx, true), child: const Text('Reject')),
      ]));
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('reject_field_order',
          params: {'p_id': o['id'], 'p_user': _userId, 'p_reason': reasonCtrl.text.trim()});
      if (!mounted) return;
      setState(() { _saving = false; _selected = null; });
      _snack('Order rejected');
      ref.invalidate(fieldOrderPendingCountProvider);
      _loadOrders();
    } catch (e) { _snack('Reject failed: $e'); setState(() => _saving = false); }
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 1),
      initialDateRange: (_fromDate != null && _toDate != null)
          ? DateTimeRange(start: _fromDate!, end: _toDate!) : null,
    );
    if (picked != null) {
      setState(() { _fromDate = picked.start; _toDate = picked.end; });
      _loadOrders();
    }
  }

  // Export the orders currently in view (the selected filter + any date range).
  Future<void> _exportPdf() async {
    if (_orders.isEmpty) { _snack('Nothing to export'); return; }
    final status = _filter[0].toUpperCase() + _filter.substring(1);
    final reviewed = _filter != 'submitted';
    final rangeLabel = (_fromDate != null || _toDate != null)
        ? '  (${_fromDate != null ? DateFormat('d MMM yyyy').format(_fromDate!) : '...'} - ${_toDate != null ? DateFormat('d MMM yyyy').format(_toDate!) : '...'})'
        : '';
    // Resolve SO ids -> SO-YYYY-#### voucher numbers for the Approved export.
    final Map<String, String> soNums = {};
    if (_filter == 'approved') {
      final soIds = _orders.map((o) => o['sales_order_id'] as String?).whereType<String>().toSet().toList();
      if (soIds.isNotEmpty) {
        try {
          final rows = await Supabase.instance.client.from('sales_orders')
              .select('id, voucher_number').inFilter('id', soIds);
          for (final r in rows as List) { soNums[r['id'] as String] = (r['voucher_number'] as String?) ?? '-'; }
        } catch (_) {}
      }
    }
    final headers = reviewed
        ? ['Submitted', 'Customer', 'Salesperson', '$status by', 'On', _filter == 'rejected' ? 'Reason' : 'SO #']
        : ['Submitted', 'Customer', 'Salesperson', 'Notes'];
    final rows = _orders.map((o) {
      final sub = o['submitted_at'] != null ? DateFormat('d MMM yyyy, HH:mm').format(DateTime.parse(o['submitted_at'] as String).toLocal()) : '-';
      final cust = _custNames[o['customer_id']] ?? '-';
      final sp = _spNames[o['salesperson_id']] ?? '-';
      if (!reviewed) return [sub, cust, sp, (o['notes'] as String?) ?? ''];
      final by = _spNames[o['reviewed_by']] ?? '-';
      final on = o['reviewed_at'] != null ? DateFormat('d MMM yyyy, HH:mm').format(DateTime.parse(o['reviewed_at'] as String).toLocal()) : '-';
      final last = _filter == 'rejected'
          ? ((o['reject_reason'] as String?) ?? '')
          : (soNums[o['sales_order_id']] ?? '-');
      return [sub, cust, sp, by, on, last];
    }).toList();

    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
      header: (ctx) => ctx.pageNumber == 1 ? pw.SizedBox.shrink() : pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Text('Field Orders - $status', style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600))),
      footer: (ctx) => pw.Padding(padding: const pw.EdgeInsets.only(top: 8),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
          pw.Text('Generated ${DateFormat('d MMM yyyy HH:mm').format(DateTime.now())}', style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
        ])),
      build: (ctx) => [
        pw.Text('Field Orders - $status$rangeLabel', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text('${_orders.length} order(s)', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
        pw.SizedBox(height: 12),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
          columnWidths: reviewed
              ? {0: const pw.FlexColumnWidth(2.2), 1: const pw.FlexColumnWidth(2.4), 2: const pw.FlexColumnWidth(1.8), 3: const pw.FlexColumnWidth(1.8), 4: const pw.FlexColumnWidth(2.2), 5: const pw.FlexColumnWidth(2.6)}
              : {0: const pw.FlexColumnWidth(2.2), 1: const pw.FlexColumnWidth(2.6), 2: const pw.FlexColumnWidth(2), 3: const pw.FlexColumnWidth(3.2)},
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: headers.map((h) => pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: pw.Text(h, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
              )).toList(),
            ),
            for (final r in rows)
              pw.TableRow(children: r.map((c) => pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                child: pw.Text(c, style: const pw.TextStyle(fontSize: 9)),
              )).toList()),
          ],
        ),
      ],
    ));
    await Printing.layoutPdf(onLayout: (PdfPageFormat f) async => doc.save(), name: 'field_orders_$_filter');
  }

  Future<void> _editQty(Map<String, dynamic> line) async {
    final ctrl = TextEditingController(text: (line['quantity'] as double).toStringAsFixed(0));
    final v = await showDialog<double>(context: context, builder: (ctx) => AlertDialog(
      title: Text(line['name'] as String? ?? 'Quantity', style: const TextStyle(fontSize: 15)),
      content: TextField(
        controller: ctrl, autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Quantity'),
        onSubmitted: (_) => Navigator.pop(ctx, double.tryParse(ctrl.text.trim())),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.trim())), child: const Text('Set')),
      ],
    ));
    if (v != null && v > 0) setState(() => line['quantity'] = v);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Field Orders', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      const Text('Orders submitted by salespeople from the field. Review, adjust, then approve into a draft Sales Order.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      const SizedBox(height: 14),
      Row(children: [
        for (final f in const ['submitted', 'approved', 'rejected'])
          Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
            label: Text(() {
              final base = f == 'submitted' ? 'Received' : '${f[0].toUpperCase()}${f.substring(1)}';
              return (f == 'submitted' && _newWhileAway > 0 && _filter != 'submitted')
                  ? '$base ($_newWhileAway new)' : base;
            }()),
            selected: _filter == f,
            onSelected: (_) { setState(() { _filter = f; _selected = null; if (f == 'submitted') _newWhileAway = 0; }); _loadOrders(); })),
        const Spacer(),
        if (_filter != 'submitted') ...[
          OutlinedButton.icon(
            icon: const Icon(Icons.date_range, size: 16),
            label: Text(_fromDate == null && _toDate == null
                ? 'Date range'
                : '${_fromDate != null ? DateFormat('d MMM').format(_fromDate!) : '…'} – ${_toDate != null ? DateFormat('d MMM').format(_toDate!) : '…'}'),
            onPressed: _pickDateRange,
          ),
          if (_fromDate != null || _toDate != null)
            IconButton(icon: const Icon(Icons.clear, size: 18), tooltip: 'Clear range',
              onPressed: () { setState(() { _fromDate = null; _toDate = null; }); _loadOrders(); }),
          const SizedBox(width: 8),
        ],
        OutlinedButton.icon(icon: const Icon(Icons.picture_as_pdf, size: 16), label: const Text('Export PDF'), onPressed: _exportPdf),
        const SizedBox(width: 8),
        IconButton(
          icon: Icon(_soundOn ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
              color: _soundOn ? AppTheme.primary : AppTheme.textSecondary),
          tooltip: _soundOn ? 'New-order sound on (click to mute)' : 'New-order sound off (click to enable)',
          onPressed: _toggleSound,
        ),
        IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _loadOrders),
      ]),
      const SizedBox(height: 12),
      Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 380, child: _queueList()),
        const SizedBox(width: 16),
        Expanded(child: _reviewPanel()),
      ])),
    ]));
  }

  Widget _queueList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_orders.isEmpty) return Center(child: Text('No $_filter orders', style: const TextStyle(color: AppTheme.textSecondary)));
    return ListView.separated(
      itemCount: _orders.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final o = _orders[i];
        final sel = _selected?['id'] == o['id'];
        final when = o['submitted_at'] != null ? DateFormat('d MMM, HH:mm').format(DateTime.parse(o['submitted_at'] as String).toLocal()) : '';
        return InkWell(onTap: () => _openOrder(o), borderRadius: BorderRadius.circular(10), child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: sel ? AppTheme.primary.withOpacity(0.06) : Colors.white,
            borderRadius: BorderRadius.circular(10), border: Border.all(color: sel ? AppTheme.primary.withOpacity(0.4) : AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_custNames[o['customer_id']] ?? 'Customer', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('By ${_spNames[o['salesperson_id']] ?? '—'}  ·  $when', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            if ((o['notes'] as String?)?.isNotEmpty == true) ...[
              const SizedBox(height: 4),
              Text(o['notes'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic, color: AppTheme.textSecondary)),
            ],
          ]),
        ));
      },
    );
  }

  Widget _reviewPanel() {
    final o = _selected;
    if (o == null) {
      return Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
        child: const Center(child: Text('Select an order to review', style: TextStyle(color: AppTheme.textSecondary))));
    }
    final readOnly = _filter != 'submitted';
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_custNames[o['customer_id']] ?? 'Customer', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('Submitted by ${_spNames[o['salesperson_id']] ?? '—'}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            if (readOnly && o['reviewed_at'] != null) Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '${o['status'] == 'approved' ? 'Approved' : 'Rejected'} by '
                '${_spNames[o['reviewed_by']] ?? '—'} · '
                '${DateFormat('d MMM yyyy, HH:mm').format(DateTime.parse(o['reviewed_at'] as String).toLocal())}',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                  color: o['status'] == 'approved' ? AppTheme.success : AppTheme.danger),
              ),
            ),
          ])),
          if (!readOnly && _branches.isNotEmpty) Padding(padding: const EdgeInsets.only(right: 10), child: SizedBox(width: 180, child: DropdownButtonFormField<String>(
            value: _branches.any((b) => b['id'] == _approveBranchId) ? _approveBranchId : null,
            isExpanded: true,
            decoration: const InputDecoration(isDense: true, labelText: 'Branch', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
            items: _branches.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
            onChanged: (v) => setState(() => _approveBranchId = v),
          ))),
          if (!readOnly) OutlinedButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('Add Product'), onPressed: _addLine),
        ])),
        const Divider(height: 1),
        Expanded(child: _lines.isEmpty
          ? const Center(child: Text('No lines', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _lines.length,
              separatorBuilder: (_, __) => const Divider(height: 14),
              itemBuilder: (_, i) {
                final l = _lines[i];
                final qty = l['quantity'] as double;
                final price = l['price'] as double;
                return Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l['name'] as String, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    Text('Rs. ${price.toStringAsFixed(2)} each', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ])),
                  if (readOnly)
                    Text('× ${qty.toStringAsFixed(0)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))
                  else ...[
                    IconButton(icon: const Icon(Icons.remove_circle_outline, size: 20), onPressed: qty <= 1 ? null : () => setState(() => l['quantity'] = qty - 1)),
                    InkWell(
                      onTap: () => _editQty(l),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        width: 52, padding: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6)),
                        child: Text(qty.toStringAsFixed(0), textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.add_circle_outline, size: 20), onPressed: () => setState(() => l['quantity'] = qty + 1)),
                  ],
                  SizedBox(width: 92, child: Text('Rs. ${(qty * price).toStringAsFixed(2)}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                  if (!readOnly) IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger), onPressed: () => setState(() => _lines.removeAt(i))),
                ]);
              },
            )),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          Text('Total (at current prices)', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const Spacer(),
          Text('Rs. ${_total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.primary)),
        ])),
        if (!readOnly) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Row(children: [
          Expanded(child: OutlinedButton.icon(style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger, side: const BorderSide(color: AppTheme.danger)),
            icon: const Icon(Icons.close, size: 18), label: const Text('Reject'), onPressed: _saving ? null : _reject)),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: ElevatedButton.icon(
            icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check, size: 18),
            label: Text(_saving ? 'Working…' : 'Approve → Draft SO'),
            onPressed: _saving ? null : _approve)),
        ])),
        if (readOnly && o['reject_reason'] != null) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Text('Rejected: ${o['reject_reason']}', style: const TextStyle(fontSize: 12, color: AppTheme.danger))),
      ]),
    );
  }
}
