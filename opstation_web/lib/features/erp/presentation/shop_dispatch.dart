// ignore_for_file: deprecated_member_use
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/pdf/pdf_output.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/scan_bar.dart';

/// Sales → Fulfillment → Handover: when the courier comes (once a day), every
/// box is scanned as it is handed over — its packing slip or courier label.
/// Shows what is expected, what is scanned, what is missing, and stops a box
/// that isn't ready or belongs to another courier. Completing it saves the
/// handover and prints a manifest for the courier to sign.
class ShopDispatch extends StatefulWidget {
  final String orgId;
  final String? userId;
  final String userName;
  final List<Map<String, dynamic>> stores;
  final VoidCallback? onDone;
  const ShopDispatch({super.key, required this.orgId, required this.userId, required this.userName,
      required this.stores, this.onDone});
  @override
  State<ShopDispatch> createState() => _ShopDispatchState();
}

class _ShopDispatchState extends State<ShopDispatch> {
  List<Map<String, dynamic>> _ready = []; // packed / fulfilled, not handed over yet
  List<Map<String, dynamic>> _history = [];
  final List<String> _scanned = [];
  String _courier = 'all';
  bool _loading = true;
  bool _saving = false;
  String? _error;
  final _money = NumberFormat('#,##0.##');

  @override
  void initState() {
    super.initState();
    _load();
  }

  double _n(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
  String _no(Object? s) => '${s ?? ''}'.replaceAll('#', '').trim().toLowerCase();
  String _courierOf(Map<String, dynamic> o) {
    final c = '${o['tracking_company'] ?? ((o['ship_info'] as Map?) ?? const {})['company'] ?? ''}'.trim();
    return c.isEmpty ? 'No courier' : c;
  }
  String _tracking(Map<String, dynamic> o) =>
      '${o['tracking_number'] ?? ((o['ship_info'] as Map?) ?? const {})['number'] ?? ''}'.trim();
  String _city(Map<String, dynamic> o) => '${((o['ship_to'] as Map?) ?? const {})['city'] ?? ''}'.trim();
  double _collect(Map<String, dynamic> o) {
    final paid = '${o['financial_status'] ?? ''}'.toUpperCase() == 'PAID';
    final base = o['outstanding'] != null ? _n(o['outstanding']) : (paid ? 0.0 : _n(o['total']));
    if (base <= 0) return 0;
    var removed = 0.0;
    for (final l in (o['lines'] as List? ?? const [])) {
      final m = l as Map;
      removed += _n(m['cancelled']) * (_n(m['price']) - _n(m['disc_each']));
    }
    return base - removed < 0 ? 0.0 : base - removed;
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final since = DateTime.now().subtract(const Duration(days: 14)).toUtc().toIso8601String();
      final r = await Supabase.instance.client.from('shop_orders').select()
          .eq('org_id', widget.orgId).inFilter('status', ['packed', 'fulfilled'])
          .isFilter('handed_over_at', null).gte('packed_at', since)
          .order('packed_at').limit(1000);
      final h = await Supabase.instance.client.from('shop_dispatches').select()
          .eq('org_id', widget.orgId).order('created_at', ascending: false).limit(10);
      if (!mounted) return;
      setState(() {
        _ready = List<Map<String, dynamic>>.from(r as List);
        _history = List<Map<String, dynamic>>.from(h as List);
        _scanned.removeWhere((id) => !_ready.any((o) => o['id'] == id));
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Handover isn\'t set up yet — please contact Opstation support.'; });
    }
  }

  List<Map<String, dynamic>> get _expected =>
      _ready.where((o) => _courier == 'all' || _courierOf(o) == _courier).toList();

  Future<ScanOutcome> _onScan(String code, double _) async {
    final c = _no(code);
    if (c.isEmpty) return const ScanOutcome(false, 'Empty scan');
    Map<String, dynamic>? hit;
    for (final o in _ready) {
      if (_no(o['order_no']) == c || (_tracking(o).isNotEmpty && _tracking(o).toLowerCase() == code.trim().toLowerCase())) {
        hit = o;
        break;
      }
    }
    if (hit == null) {
      // Not in the handover list — say why if it's one of our orders.
      try {
        final r = await Supabase.instance.client.from('shop_orders').select('order_no, status, handed_over_at')
            .eq('org_id', widget.orgId).or('order_no.eq.$c,order_no.eq.#$c,tracking_number.eq.${code.trim()}').limit(1);
        final l = r as List;
        if (l.isNotEmpty) {
          final o = l.first as Map;
          if (o['handed_over_at'] != null) return ScanOutcome(false, '${o['order_no']} was already handed over');
          return ScanOutcome(false, '${o['order_no']} is not packed yet (${o['status']}) — keep it back');
        }
      } catch (_) {}
      return ScanOutcome(false, 'Not a box on the handover list: $code');
    }
    if (_courier != 'all' && _courierOf(hit) != _courier) {
      return ScanOutcome(false, '${hit['order_no']} is for ${_courierOf(hit)}, not $_courier — keep it back');
    }
    if (hit['status'] != 'fulfilled') {
      return ScanOutcome(false, '${hit['order_no']} is packed but not fulfilled yet — fulfil it first');
    }
    if (_scanned.contains(hit['id'])) return ScanOutcome(false, '${hit['order_no']} was already scanned');
    setState(() => _scanned.add(hit!['id'] as String));
    final exp = _expected;
    final done = exp.where((o) => _scanned.contains(o['id'])).length;
    return ScanOutcome(true, '${hit['order_no']} · ${hit['customer_name'] ?? ''}   ✓ $done of ${exp.length}');
  }

  Future<void> _complete() async {
    final exp = _expected;
    final boxes = exp.where((o) => _scanned.contains(o['id'])).toList();
    final missing = exp.where((o) => !_scanned.contains(o['id'])).toList();
    if (boxes.isEmpty) return;
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      title: Text('Hand over ${boxes.length} box${boxes.length == 1 ? '' : 'es'}?'),
      content: Text(missing.isEmpty
          ? 'All expected boxes were scanned.'
          : '${missing.length} expected box${missing.length == 1 ? ' was' : 'es were'} NOT scanned: '
            '${missing.take(6).map((o) => o['order_no']).join(', ')}${missing.length > 6 ? '…' : ''}.\n'
            'They stay on the list for the next pickup.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(false), child: const Text('Back')),
        FilledButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(true), child: const Text('Complete & print')),
      ],
    ));
    if (ok != true) return;
    setState(() => _saving = true);
    final client = Supabase.instance.client;
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      final ins = await client.from('shop_dispatches').insert({
        'org_id': widget.orgId,
        'courier': _courier == 'all' ? null : _courier,
        'created_by': widget.userId,
        'created_by_name': widget.userName,
        'expected': exp.length,
        'handed_over': boxes.length,
        'order_ids': [for (final o in boxes) o['id']],
        'missing_ids': [for (final o in missing) o['id']],
      }).select('id').single();
      final id = ins['id'] as String;
      await client.from('shop_orders').update({
        'handed_over_at': now, 'handed_over_by_name': widget.userName, 'dispatch_id': id,
      }).inFilter('id', [for (final o in boxes) o['id']]);
      await _printManifest(boxes, missing, _courier == 'all' ? null : _courier, DateTime.now());
      if (!mounted) return;
      setState(() { _scanned.clear(); _saving = false; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(behavior: SnackBarBehavior.floating,
          content: Text('Handover saved — ${boxes.length} box${boxes.length == 1 ? '' : 'es'}')));
      widget.onDone?.call();
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  static String _t(Object? v) {
    final s = '${v ?? ''}'.replaceAll('—', '-').replaceAll('–', '-').replaceAll('×', 'x');
    return String.fromCharCodes(s.runes.map((c) => c < 256 ? c : 0x3F));
  }

  Future<void> _printManifest(List<Map<String, dynamic>> boxes, List<Map<String, dynamic>> missing,
      String? courier, DateTime at) async {
    const grey = PdfColor.fromInt(0xFF6B7280);
    const line = PdfColor.fromInt(0xFFD1D5DB);
    final cod = boxes.fold<double>(0, (a, o) => a + _collect(o));
    pw.Widget c(String s, {bool b = false, pw.TextAlign a = pw.TextAlign.left}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 4),
        child: pw.Text(_t(s), textAlign: a, style: pw.TextStyle(fontSize: 9, fontWeight: b ? pw.FontWeight.bold : null)));
    final doc = pw.Document(title: 'Courier handover');
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      footer: (ctx) => pw.Align(alignment: pw.Alignment.centerRight,
          child: pw.Text('Page ${ctx.pageNumber}/${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: grey))),
      build: (_) => [
        pw.Text('Courier handover${courier == null ? '' : ' - ${_t(courier)}'}',
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.Text(_t('${DateFormat('d MMM yyyy, HH:mm').format(at)}  |  Handed over by ${widget.userName}'),
            style: const pw.TextStyle(fontSize: 9, color: grey)),
        pw.SizedBox(height: 8),
        pw.Text(_t('${boxes.length} boxes  |  COD to collect: ${_money.format(cod)}'),
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 8),
        pw.Table(
          border: pw.TableBorder(horizontalInside: const pw.BorderSide(color: line, width: 0.5),
              bottom: const pw.BorderSide(color: line, width: 0.5)),
          columnWidths: {
            0: const pw.FixedColumnWidth(20), 1: const pw.FixedColumnWidth(54), 2: const pw.FlexColumnWidth(),
            3: const pw.FixedColumnWidth(70), 4: const pw.FixedColumnWidth(96), 5: const pw.FixedColumnWidth(60),
          },
          children: [
            pw.TableRow(decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F4F6)), children: [
              c('#', b: true), c('Order', b: true), c('Customer', b: true), c('City', b: true),
              c('Courier / tracking', b: true), c('COD', b: true, a: pw.TextAlign.right),
            ]),
            for (var i = 0; i < boxes.length; i++)
              pw.TableRow(children: [
                c('${i + 1}'),
                c('${boxes[i]['order_no'] ?? ''}', b: true),
                c('${boxes[i]['customer_name'] ?? ''}${'${boxes[i]['phone'] ?? ''}'.isNotEmpty ? '\n${boxes[i]['phone']}' : ''}'),
                c(_city(boxes[i])),
                c('${_courierOf(boxes[i])}\n${_tracking(boxes[i])}'),
                c(_collect(boxes[i]) > 0 ? _money.format(_collect(boxes[i])) : 'Paid', a: pw.TextAlign.right),
              ]),
          ],
        ),
        if (missing.isNotEmpty) ...[
          pw.SizedBox(height: 10),
          pw.Text(_t('Not handed over (kept back): ${missing.map((o) => o['order_no']).join(', ')}'),
              style: const pw.TextStyle(fontSize: 9, color: grey)),
        ],
        pw.SizedBox(height: 40),
        pw.Row(children: [
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Container(height: 0.7, color: PdfColors.black),
            pw.SizedBox(height: 3),
            pw.Text('Handed over by (name & signature)', style: const pw.TextStyle(fontSize: 8.5, color: grey)),
          ])),
          pw.SizedBox(width: 40),
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Container(height: 0.7, color: PdfColors.black),
            pw.SizedBox(height: 3),
            pw.Text('Received by courier (name & signature)', style: const pw.TextStyle(fontSize: 8.5, color: grey)),
          ])),
        ]),
      ],
    ));
    final Uint8List bytes = await doc.save();
    await showPdf(bytes, 'Courier handover ${DateFormat('d MMM yyyy').format(at)}');
  }

  Future<void> _reprint(Map<String, dynamic> d) async {
    try {
      final ids = [for (final x in (d['order_ids'] as List? ?? const [])) '$x'];
      final mids = [for (final x in (d['missing_ids'] as List? ?? const [])) '$x'];
      final r = ids.isEmpty ? const [] : await Supabase.instance.client.from('shop_orders').select().inFilter('id', ids);
      final m = mids.isEmpty ? const [] : await Supabase.instance.client.from('shop_orders').select('id, order_no').inFilter('id', mids);
      await _printManifest(List<Map<String, dynamic>>.from(r as List), List<Map<String, dynamic>>.from(m as List),
          d['courier'] as String?, DateTime.parse('${d['created_at']}').toLocal());
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not print: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: AppTheme.textSecondary)));
    final counts = <String, int>{};
    for (final o in _ready) { counts[_courierOf(o)] = (counts[_courierOf(o)] ?? 0) + 1; }
    final exp = _expected;
    final done = exp.where((o) => _scanned.contains(o['id'])).toList();
    final missing = exp.where((o) => !_scanned.contains(o['id'])).toList();
    final narrow = MediaQuery.of(context).size.width < 900;
    Widget orderTile(Map<String, dynamic> o, bool ok) => ListTile(
          dense: true,
          leading: Icon(ok ? Icons.check_circle : Icons.inventory_2_outlined,
              color: ok ? Colors.green : (o['status'] == 'fulfilled' ? AppTheme.textSecondary : Colors.orange)),
          title: Text('${o['order_no'] ?? ''} · ${o['customer_name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text([
            _courierOf(o), if (_tracking(o).isNotEmpty) _tracking(o), if (_city(o).isNotEmpty) _city(o),
            if (o['status'] != 'fulfilled') 'not fulfilled yet',
          ].join(' · '), style: TextStyle(fontSize: 11.5, color: o['status'] != 'fulfilled' ? Colors.orange.shade800 : null)),
          trailing: Text(_collect(o) > 0 ? _money.format(_collect(o)) : 'Paid',
              style: const TextStyle(fontWeight: FontWeight.w700)),
        );
    final lists = [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.all(8),
            child: Text('Still to scan (${missing.length})', style: const TextStyle(fontWeight: FontWeight.w800))),
        Expanded(child: missing.isEmpty
            ? const Center(child: Text('All boxes scanned', style: TextStyle(color: Colors.green, fontWeight: FontWeight.w700)))
            : ListView(children: [for (final o in missing) orderTile(o, false)])),
      ])),
      const SizedBox(width: 12, height: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.all(8),
            child: Text('Scanned (${done.length})', style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.green))),
        Expanded(child: ListView(children: [for (final o in done.reversed) orderTile(o, true)])),
      ])),
    ];
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Courier handover', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
          if (_history.isNotEmpty)
            PopupMenuButton<Map<String, dynamic>>(
              tooltip: 'Past handovers',
              onSelected: _reprint,
              itemBuilder: (_) => [
                for (final d in _history)
                  PopupMenuItem(value: d, child: Text(
                      '${DateFormat('d MMM, HH:mm').format(DateTime.parse('${d['created_at']}').toLocal())} · '
                      '${d['courier'] ?? 'All couriers'} · ${d['handed_over']} boxes')),
              ],
              child: const Padding(padding: EdgeInsets.all(6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.history, size: 18), SizedBox(width: 4), Text('Past')])),
            ),
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load),
        ]),
        const Text('Scan each box as the courier takes it — its packing slip or courier label.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 10),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          ChoiceChip(label: Text('All couriers (${_ready.length})'), selected: _courier == 'all',
              onSelected: (_) => setState(() => _courier = 'all')),
          for (final e in counts.entries) ...[
            const SizedBox(width: 6),
            ChoiceChip(label: Text('${e.key} (${e.value})'), selected: _courier == e.key,
                onSelected: (_) => setState(() => _courier = e.key)),
          ],
        ])),
        const SizedBox(height: 10),
        ScanBar(onScan: _onScan, hint: 'Scan the box (slip or courier label)', strongFeedback: true,
            camera: true, showQty: false, autofocus: !narrow),
        const SizedBox(height: 10),
        Row(children: [
          Text('${done.length} of ${exp.length} scanned', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(width: 10),
          Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(
            value: exp.isEmpty ? 0.0 : done.length / exp.length, minHeight: 6,
            backgroundColor: AppTheme.border.withOpacity(0.6),
            valueColor: const AlwaysStoppedAnimation(Colors.green),
          ))),
          const SizedBox(width: 10),
          FilledButton.icon(
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.local_shipping_outlined, size: 18),
            label: Text('Complete handover (${done.length})'),
            onPressed: done.isEmpty || _saving ? null : _complete,
          ),
        ]),
        const Divider(height: 18),
        Expanded(child: exp.isEmpty
            ? const Center(child: Text('Nothing waiting for the courier.', style: TextStyle(color: AppTheme.textSecondary)))
            : narrow ? Column(children: lists) : Row(crossAxisAlignment: CrossAxisAlignment.start, children: lists)),
      ]),
    );
  }
}
