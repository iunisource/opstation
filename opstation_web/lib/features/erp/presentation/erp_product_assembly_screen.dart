// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class _BomLine {
  static int _seq = 0;
  final String id = 'bl_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String? productId; String productLabel = '';
  final TextEditingController qtyCtrl = TextEditingController();
  double get qty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() { qtyCtrl.dispose(); }
}

// A labor/overhead line now references a MASTER rate (labor_types /
// overhead_types) and carries a quantity. The money amount is derived as
// quantity x master.rate, so changing the master propagates everywhere.
class _CostLine {
  static int _seq = 0;
  final String id = 'ol_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String costType;           // 'labor' | 'overhead' — picks which master table
  String? rateId;            // FK to labor_types / overhead_types
  final TextEditingController qtyCtrl = TextEditingController(text: '1');
  _CostLine({this.costType = 'overhead', this.rateId});
  double get qty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() { qtyCtrl.dispose(); }
}

class ErpProductAssemblyScreen extends ConsumerStatefulWidget {
  const ErpProductAssemblyScreen({super.key});
  @override
  ConsumerState<ErpProductAssemblyScreen> createState() => _State();
}

class _State extends ConsumerState<ErpProductAssemblyScreen> {
  List<Map<String, dynamic>> _products = [];
  Map<String, String> _prodLabel = {};   // id -> label
  bool _loadingProducts = true;

  // master rates
  List<Map<String, dynamic>> _laborTypes = [];
  List<Map<String, dynamic>> _overheadTypes = [];
  Map<String, double> _rateById = {};
  Map<String, String> _nameById = {};

  List<Map<String, dynamic>> _boms = [];
  bool _loadingList = true;
  String _listSearch = '';
  bool _drawerOpen = true;

  Map<String, dynamic>? _current;
  String? _fgId; String _fgLabel = '';
  final _outputQtyCtrl = TextEditingController(text: '1');
  final _nameCtrl = TextEditingController();
  String _status = 'active';
  List<_BomLine> _components = [];
  List<_BomLine> _waste = [];
  List<_CostLine> _overheads = [];
  bool _saving = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _isActive => _status == 'active';

  @override
  void initState() {
    super.initState();
    _components = [_BomLine()];
    WidgetsBinding.instance.addPostFrameCallback((_) { _loadProducts(); _loadRates(); _loadBoms(); });
  }
  @override
  void dispose() {
    _outputQtyCtrl.dispose(); _nameCtrl.dispose();
    for (final l in _components) l.dispose();
    for (final l in _waste) l.dispose();
    for (final l in _overheads) l.dispose();
    super.dispose();
  }
  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadProducts() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 500)); if (mounted) _loadProducts(); return; }
    try {
      final List<Map<String, dynamic>> all = [];
      int from = 0; const page = 1000;
      while (true) {
        final rows = await Supabase.instance.client.from('products')
            .select('id, name, sku, product_type')
            .eq('org_id', orgId).eq('is_active', true)
            .order('name').range(from, from + page - 1);
        final list = List<Map<String, dynamic>>.from(rows);
        all.addAll(list);
        if (list.length < page) break;
        from += page; if (from > 100000) break;
      }
      final items = all.map((p) => {
        'id': p['id'],
        'label': "${p['sku'] != null && (p['sku'] as String).isNotEmpty ? '${p['sku']} — ' : ''}${p['name'] ?? ''}",
        'type': p['product_type'],
      }).toList();
      final labelMap = {for (final p in items) p['id'] as String: p['label'] as String};
      if (mounted) setState(() { _products = items; _prodLabel = labelMap; _loadingProducts = false; });
    } catch (e) { if (mounted) { _snack('Products load error: $e'); setState(() => _loadingProducts = false); } }
  }

  Future<void> _loadRates() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 500)); if (mounted) _loadRates(); return; }
    try {
      final client = Supabase.instance.client;
      final lt = await client.from('labor_types').select().eq('org_id', orgId).order('name');
      final ot = await client.from('overhead_types').select().eq('org_id', orgId).order('name');
      final labor = List<Map<String, dynamic>>.from(lt as List);
      final over  = List<Map<String, dynamic>>.from(ot as List);
      final rateMap = <String, double>{};
      final nameMap = <String, String>{};
      for (final r in labor) { rateMap[r['id'] as String] = (r['rate'] as num? ?? 0).toDouble(); nameMap[r['id'] as String] = r['name'] as String? ?? ''; }
      for (final r in over)  { rateMap[r['id'] as String] = (r['rate'] as num? ?? 0).toDouble(); nameMap[r['id'] as String] = r['name'] as String? ?? ''; }
      if (mounted) setState(() { _laborTypes = labor; _overheadTypes = over; _rateById = rateMap; _nameById = nameMap; });
    } catch (e) { if (mounted) _snack('Rates load error: $e'); }
  }

  List<Map<String, dynamic>> _filterProducts(String q) {
    if (q.isEmpty) return _products.take(50).toList();
    return _products.where((p) => matchesQuery('${p['label'] ?? ''}', q)).take(200).toList();
  }

  List<Map<String, dynamic>> _typesFor(String costType) => costType == 'labor' ? _laborTypes : _overheadTypes;
  double _rateOf(_CostLine l) => l.rateId == null ? 0 : (_rateById[l.rateId!] ?? 0);
  double _amountOf(_CostLine l) => l.qty * _rateOf(l);

  Future<void> _loadBoms() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loadingList = true);
    try {
      final rows = await Supabase.instance.client.from('bom_headers')
          .select().eq('org_id', orgId).order('created_at', ascending: false).limit(300);
      if (mounted) setState(() { _boms = List<Map<String, dynamic>>.from(rows); _loadingList = false; });
    } catch (e) { if (mounted) setState(() => _loadingList = false); }
  }

  void _newBom() {
    for (final l in _components) l.dispose();
    for (final l in _waste) l.dispose();
    for (final l in _overheads) l.dispose();
    setState(() {
      _current = null; _fgId = null; _fgLabel = ''; _status = 'active';
      _outputQtyCtrl.text = '1'; _nameCtrl.clear();
      _components = [_BomLine()]; _waste = []; _overheads = [];
    });
  }

  // One item = one BOM. When picking the finished product for a NEW BOM, if
  // that item already has a BOM, offer to open it rather than create a duplicate.
  Future<void> _onPickFinished(Map<String, dynamic> p) async {
    final pid = p['id'] as String?;
    setState(() { _fgId = pid; _fgLabel = p['label'] as String? ?? ''; });
    if (_current != null || pid == null) return;
    final existing = _boms.where((b) => b['product_id'] == pid).toList();
    if (existing.isEmpty) return;
    final go = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('This item already has a BOM'),
      content: Text('${_prodLabel[pid] ?? 'This item'} already has a BOM (${existing.first['code'] ?? ''}). Each item can have only one BOM — open it to edit instead?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open existing BOM')),
      ],
    ));
    if (go == true) {
      await _loadBom(existing.first);
    } else {
      setState(() { _fgId = null; _fgLabel = ''; });
    }
  }

  Future<void> _loadBom(Map<String, dynamic> b) async {
    try {
      final client = Supabase.instance.client;
      final comps = await client.from('bom_components').select().eq('bom_id', b['id'] as String).order('line_order');
      final wastes = await client.from('bom_waste').select().eq('bom_id', b['id'] as String).order('line_order');
      final ohs = await client.from('bom_overheads').select().eq('bom_id', b['id'] as String).order('line_order');
      for (final l in _components) l.dispose();
      for (final l in _waste) l.dispose();
      for (final l in _overheads) l.dispose();
      List<_BomLine> mk(List rows) => rows.map((r) {
        final l = _BomLine();
        l.productId = r['product_id'] as String?;
        l.productLabel = _prodLabel[l.productId] ?? (l.productId ?? '');
        final q = (r['quantity'] as num? ?? 0).toDouble();
        if (q != 0) l.qtyCtrl.text = _trim(q);
        return l;
      }).toList();
      final newComps = mk(comps as List);
      final newWaste = mk(wastes as List);
      final newOh = (ohs as List).map((r) {
        final l = _CostLine(costType: (r['cost_type'] as String?) ?? 'overhead', rateId: r['rate_id'] as String?);
        final q = (r['quantity'] as num? ?? 1).toDouble();
        l.qtyCtrl.text = _trim(q == 0 ? 1 : q);
        return l;
      }).toList();
      if (mounted) setState(() {
        _current = b;
        _fgId = b['product_id'] as String?;
        _fgLabel = _prodLabel[_fgId] ?? (_fgId ?? '');
        _status = b['status'] as String? ?? 'active';
        _outputQtyCtrl.text = _trim((b['output_qty'] as num? ?? 1).toDouble());
        _nameCtrl.text = b['name'] as String? ?? '';
        _components = newComps.isEmpty ? [_BomLine()] : newComps;
        _waste = newWaste;
        _overheads = newOh;
      });
    } catch (e) { _snack('Load error: $e'); }
  }

  static String _trim(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }
  static String _money(num v) => money(v);

  Future<void> _save() async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return; }
    if (_fgId == null) { _snack('Select the finished product'); return; }
    final outQty = double.tryParse(_outputQtyCtrl.text) ?? 0;
    if (outQty <= 0) { _snack('Output quantity must be greater than 0'); return; }
    final comps = _components.where((l) => l.productId != null && l.qty > 0).toList();
    if (comps.isEmpty) { _snack('Add at least one component'); return; }
    final wastes = _waste.where((l) => l.productId != null && l.qty > 0).toList();
    final ohs = _overheads.where((l) => l.rateId != null && l.qty != 0).toList();
    final userId = ref.read(currentUserProvider)?.id ?? '';
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      String bomId, code;
      if (_current == null) {
        // Enforce one-BOM-per-item at save (guards against a stale list).
        final dup = await client.from('bom_headers').select('id, code').eq('org_id', orgId).eq('product_id', _fgId as Object).limit(1);
        if ((dup as List).isNotEmpty) {
          _snack('This item already has a BOM (${dup.first['code'] ?? ''}). Open it from the list to edit.');
          setState(() => _saving = false);
          return;
        }
        final cnt = await client.from('bom_headers').select('id').eq('org_id', orgId);
        code = 'BOM-' + ((cnt as List).length + 1).toString().padLeft(4, '0');
        bomId = 'bom_' + DateTime.now().millisecondsSinceEpoch.toString();
        await client.from('bom_headers').insert({
          'id': bomId, 'org_id': orgId, 'code': code,
          'name': _nameCtrl.text.trim().isEmpty ? (_prodLabel[_fgId] ?? code) : _nameCtrl.text.trim(),
          'product_id': _fgId, 'output_qty': outQty, 'status': _status,
          'created_by': userId, 'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });
      } else {
        bomId = _current!['id'] as String; code = _current!['code'] as String? ?? '';
        await client.from('bom_headers').update({
          'name': _nameCtrl.text.trim().isEmpty ? (_prodLabel[_fgId] ?? code) : _nameCtrl.text.trim(),
          'product_id': _fgId, 'output_qty': outQty, 'status': _status,
          'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', bomId);
      }
      await client.from('bom_components').delete().eq('bom_id', bomId);
      for (var i = 0; i < comps.length; i++) {
        await client.from('bom_components').insert({
          'id': bomId + '_c' + i.toString(), 'bom_id': bomId,
          'product_id': comps[i].productId, 'quantity': comps[i].qty, 'line_order': i,
        });
      }
      await client.from('bom_waste').delete().eq('bom_id', bomId);
      for (var i = 0; i < wastes.length; i++) {
        await client.from('bom_waste').insert({
          'id': bomId + '_w' + i.toString(), 'bom_id': bomId,
          'product_id': wastes[i].productId, 'quantity': wastes[i].qty, 'line_order': i,
        });
      }
      await client.from('bom_overheads').delete().eq('bom_id', bomId);
      for (var i = 0; i < ohs.length; i++) {
        final l = ohs[i];
        // amount + description are recomputed by the DB trigger from the master;
        // we also send them so the row is correct even without the trigger.
        await client.from('bom_overheads').insert({
          'id': bomId + '_o' + i.toString(), 'bom_id': bomId,
          'cost_type': l.costType, 'rate_id': l.rateId, 'quantity': l.qty,
          'description': _nameById[l.rateId] ?? '',
          'amount': l.qty * (_rateById[l.rateId] ?? 0), 'line_order': i,
        });
      }
      final updated = await client.from('bom_headers').select().eq('id', bomId).single();
      if (mounted) setState(() => _current = updated);
      _snack('BOM ' + code + ' saved');
      await _loadBoms();
    } catch (e) { _snack('Save failed: ' + e.toString()); }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _delete() async {
    if (_current == null) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete BOM?'),
      content: const Text('This removes the recipe and its lines. It does not affect any past production.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete'))],
    ));
    if (ok != true) return;
    try {
      final id = _current!['id'] as String;
      final c = Supabase.instance.client;
      await c.from('bom_components').delete().eq('bom_id', id);
      await c.from('bom_waste').delete().eq('bom_id', id);
      await c.from('bom_overheads').delete().eq('bom_id', id);
      await c.from('bom_headers').delete().eq('id', id);
      _snack('Deleted'); _newBom(); await _loadBoms();
    } catch (e) { _snack('Delete failed: ' + e.toString()); }
  }

  void _addComp() => setState(() => _components.add(_BomLine()));
  void _removeComp(int i) { setState(() { _components[i].dispose(); _components.removeAt(i); }); if (_components.isEmpty) _addComp(); }
  void _addWaste() => setState(() => _waste.add(_BomLine()));
  void _removeWaste(int i) => setState(() { _waste[i].dispose(); _waste.removeAt(i); });
  void _addOverhead() => setState(() => _overheads.add(_CostLine()));
  void _removeOverhead(int i) => setState(() { _overheads[i].dispose(); _overheads.removeAt(i); });

  Future<void> _openManageRates() async {
    final orgId = _orgId; if (orgId == null) return;
    await showDialog(context: context, builder: (_) => _ManageRatesDialog(
      orgId: orgId, labor: _laborTypes, overhead: _overheadTypes));
    await _loadRates();
    if (mounted) setState(() {}); // refresh amounts using new rates
  }

  // ── Print / PDF of the current BOM (a recipe / costing sheet) ─────────────
  // Prints via a hidden iframe srcdoc (Safari renders blob: URLs as blank).
  void _printBom() {
    final code = (_current?['code'] as String?) ?? 'New BOM';
    final fgLabel = _fgLabel.isNotEmpty ? _fgLabel : (_prodLabel[_fgId] ?? '');
    final nm = _nameCtrl.text.trim();
    final outQty = _outputQtyCtrl.text.trim().isEmpty ? '1' : _outputQtyCtrl.text.trim();
    final statusLabel = _isActive ? 'Active' : 'Inactive';

    String esc(String s) =>
        s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

    final comps = _components.where((l) => l.productId != null && l.qty > 0).toList();
    final wastes = _waste.where((l) => l.productId != null && l.qty > 0).toList();
    final ohs = _overheads.where((l) => l.rateId != null && l.qty != 0).toList();
    final ohTotal = ohs.fold<double>(0, (s, l) => s + _amountOf(l));

    String lineRows(List<_BomLine> lines) {
      final b = StringBuffer();
      var i = 0;
      for (final l in lines) {
        i++;
        final label = l.productLabel.isNotEmpty
            ? l.productLabel
            : (_prodLabel[l.productId] ?? (l.productId ?? ''));
        b.write('<tr><td>$i</td><td>${esc(label)}</td><td class="num">${_trim(l.qty)}</td></tr>');
      }
      return b.toString();
    }

    final compSection = comps.isEmpty
        ? ''
        : '<h2>Components (consumed)</h2>'
            '<table><thead><tr><th style="width:6%">#</th><th>Product</th>'
            '<th class="num" style="width:22%">Quantity</th></tr></thead>'
            '<tbody>${lineRows(comps)}</tbody></table>';

    final wasteSection = wastes.isEmpty
        ? ''
        : '<h2>Waste Outputs (produced)</h2>'
            '<table><thead><tr><th style="width:6%">#</th><th>Product</th>'
            '<th class="num" style="width:22%">Quantity</th></tr></thead>'
            '<tbody>${lineRows(wastes)}</tbody></table>';

    final ohBuf = StringBuffer();
    var oi = 0;
    for (final l in ohs) {
      oi++;
      final typeLabel = l.costType == 'labor' ? 'Labor' : 'Overhead';
      final rname = _nameById[l.rateId] ?? '';
      ohBuf.write('<tr><td>$oi</td><td>${esc(typeLabel)}</td><td>${esc(rname)}</td>'
          '<td class="num">${_trim(l.qty)}</td>'
          '<td class="num">${_money(_rateOf(l))}</td>'
          '<td class="num">${_money(_amountOf(l))}</td></tr>');
    }
    final ohSection = ohs.isEmpty
        ? ''
        : '<h2>Labor &amp; Overhead (absorbed)</h2>'
            '<table><thead><tr><th style="width:6%">#</th><th style="width:16%">Type</th><th>Rate</th>'
            '<th class="num" style="width:12%">Qty</th><th class="num" style="width:16%">Rate</th>'
            '<th class="num" style="width:16%">Amount</th></tr></thead>'
            '<tbody>$ohBuf'
            '<tr class="tot"><td colspan="5">Total labor &amp; overhead</td>'
            '<td class="num">${_money(ohTotal)}</td></tr></tbody></table>';

    final nameLine =
        nm.isEmpty ? '' : '<div class="info"><b>Name / Notes:</b> ${esc(nm)}</div>';
    final genTime = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());

    final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>BOM ${esc(code)}</title>'
        '<style>'
        '@page { size: A4; margin: 1cm; } '
        '* { -webkit-print-color-adjust: exact; print-color-adjust: exact; } '
        'body { font-family: Arial, sans-serif; color: #000; font-size: 12px; } '
        'h1 { font-size: 18px; margin: 0 0 4px 0; } '
        'h2 { font-size: 13px; margin: 18px 0 6px 0; color: #1e2a78; } '
        '.info { font-size: 11px; color: #333; margin: 2px 0; } '
        'table { width: 100%; border-collapse: collapse; margin-top: 4px; } '
        'th, td { padding: 5px 8px; border: 1px solid #999; text-align: left; font-size: 11px; } '
        'th { background: #f0f4ff; font-weight: 700; } '
        '.num { text-align: right; } '
        '.tot td { background: #f3f6ff; font-weight: 700; } '
        '</style></head><body>'
        '<h1>Bill of Materials — ${esc(code)}</h1>'
        '<div class="info"><b>Finished Product:</b> ${esc(fgLabel)}</div>'
        '$nameLine'
        '<div class="info"><b>Output Qty:</b> ${esc(outQty)} &nbsp;|&nbsp; <b>Status:</b> $statusLabel</div>'
        '<div class="info">Generated: $genTime</div>'
        '$compSection$wasteSection$ohSection'
        '<script>window.onload=function(){setTimeout(function(){window.focus();window.print();},350);};</script>'
        '</body></html>';

    final iframe = html.IFrameElement()
      ..style.position = 'fixed'
      ..style.right = '0'
      ..style.bottom = '0'
      ..style.width = '0'
      ..style.height = '0'
      ..style.border = '0';
    html.document.body!.append(iframe);
    iframe.srcdoc = doc;
    Future.delayed(const Duration(minutes: 2), () {
      try {
        iframe.remove();
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _listSearch.isEmpty ? _boms : _boms.where((b) {
      return matchesQuery('${b['code'] ?? ''} ${b['name'] ?? ''} ${_prodLabel[b['product_id']] ?? ''}', _listSearch);
    }).toList();

    return Container(color: AppTheme.background, child: Row(children: [
      if (_drawerOpen) Container(width: 300,
        decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
        child: Column(children: [
          Container(padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Column(children: [
              Row(children: [
                const Expanded(child: Text('Bills of Material', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                ElevatedButton.icon(icon: const Icon(Icons.add, size: 13), label: const Text('New', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero),
                  onPressed: _newBom),
              ]),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search BOMs...', prefixIcon: Icon(Icons.search, size: 15), isDense: true),
                onChanged: (v) => setState(() => _listSearch = v)),
            ])),
          Expanded(child: _loadingList ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : filtered.isEmpty ? const Center(child: Text('No BOMs yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
                final b = filtered[i]; final sel = _current?['id'] == b['id'];
                final active = (b['status'] as String? ?? 'active') == 'active';
                return InkWell(onTap: () => _loadBom(b), child: Container(
                  color: sel ? AppTheme.primary.withOpacity(0.07) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(b['code'] as String? ?? '', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : AppTheme.textPrimary))),
                      if (!active) Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(color: Colors.grey.withOpacity(0.15), borderRadius: BorderRadius.circular(3)),
                        child: const Text('Inactive', style: TextStyle(fontSize: 9, color: Colors.grey, fontWeight: FontWeight.w700))),
                    ]),
                    Text(_prodLabel[b['product_id']] ?? (b['name'] as String? ?? ''),
                      style: TextStyle(fontSize: 11, color: sel ? AppTheme.primary : AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                  ]),
                ));
              })),
        ])),

      Expanded(child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            IconButton(icon: Icon(_drawerOpen ? Icons.chevron_left : Icons.chevron_right, size: 18), onPressed: () => setState(() => _drawerOpen = !_drawerOpen), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            const SizedBox(width: 8),
            Expanded(child: Text(_current?['code'] as String? ?? 'New Bill of Materials', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            Row(children: [
              const Text('Active', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              Switch(value: _isActive, onChanged: (v) => setState(() => _status = v ? 'active' : 'inactive')),
            ]),
            if (_current != null) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: _delete, tooltip: 'Delete'),
            if (_fgId != null) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.print_outlined, size: 16),
                label: const Text('Print / PDF'),
                onPressed: _printBom,
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
              ),
            ],
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
              onPressed: _saving ? null : _save),
          ])),
        Expanded(child: _loadingProducts
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Loading products...', style: TextStyle(color: AppTheme.textSecondary))]))
          : SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Finished Product *', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                _ProductField(key: ValueKey('fg_${_current?['id'] ?? 'new'}_$_fgId'),
                  initialLabel: _fgLabel, filterFn: _filterProducts,
                  onPick: _onPickFinished),
              ])),
              const SizedBox(width: 16),
              SizedBox(width: 140, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Output Qty *', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                TextField(controller: _outputQtyCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12))),
              ])),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Name / Notes', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                TextField(controller: _nameCtrl,
                  decoration: const InputDecoration(hintText: 'Optional', isDense: true, border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12))),
              ])),
            ]),
            const SizedBox(height: 22),
            _lineSection(
              title: 'Components (consumed)', accent: AppTheme.primary, lines: _components,
              onAdd: _addComp, onRemove: _removeComp,
              hint: 'Quantities are per the Output Qty above.'),
            const SizedBox(height: 22),
            _lineSection(
              title: 'Waste Outputs (produced)', accent: Colors.orange, lines: _waste,
              onAdd: _addWaste, onRemove: _removeWaste,
              hint: 'Waste collected from a production run; each becomes waste inventory.'),
            const SizedBox(height: 22),
            _overheadSection(),
            const SizedBox(height: 30),
          ]))),
      ])),
    ]));
  }

  Widget _lineSection({required String title, required Color accent, required List<_BomLine> lines,
      required VoidCallback onAdd, required void Function(int) onRemove, required String hint}) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          child: Row(children: [
            Container(width: 6, height: 14, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Expanded(child: Text(hint, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
          ])),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: const Row(children: [
            SizedBox(width: 26, child: Text('#', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            Expanded(child: Text('Product', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            SizedBox(width: 130, child: Text('Quantity', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 30),
          ])),
        for (var i = 0; i < lines.length; i++)
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 26, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))),
              Expanded(child: _ProductField(key: ValueKey(lines[i].id), initialLabel: lines[i].productLabel, filterFn: _filterProducts,
                onPick: (p) => setState(() { lines[i].productId = p['id'] as String?; lines[i].productLabel = p['label'] as String? ?? ''; }))),
              const SizedBox(width: 12),
              SizedBox(width: 130, child: TextField(controller: lines[i].qtyCtrl, textAlign: TextAlign.right,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: const InputDecoration(hintText: '0', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                  border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
                style: const TextStyle(fontSize: 12), onChanged: (_) => setState(() {}))),
              SizedBox(width: 30, child: IconButton(icon: const Icon(Icons.close, size: 14, color: Colors.red),
                onPressed: () => onRemove(i), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact)),
            ])),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Align(alignment: Alignment.centerLeft,
            child: TextButton.icon(icon: const Icon(Icons.add, size: 14), label: const Text('Add line', style: TextStyle(fontSize: 12)), onPressed: onAdd))),
      ]),
    );
  }

  Widget _overheadSection() {
    final total = _overheads.fold<double>(0, (s, l) => s + _amountOf(l));
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          child: Row(children: [
            Container(width: 6, height: 14, decoration: BoxDecoration(color: Colors.teal, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            const Text('Labor & Overhead (absorbed)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            const Expanded(child: Text('Pick a rate type and a quantity. Amount = quantity × rate. Change a rate once in Manage rates and every BOM updates.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
            TextButton.icon(icon: const Icon(Icons.tune, size: 14), label: const Text('Manage rates', style: TextStyle(fontSize: 11)),
              onPressed: _openManageRates),
            if (total > 0) Text(_money(total), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.teal)),
          ])),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: const Row(children: [
            SizedBox(width: 26, child: Text('#', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 120, child: Text('Type', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            Expanded(child: Text('Rate', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            SizedBox(width: 90, child: Text('Quantity', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            SizedBox(width: 110, child: Text('Amount', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 30),
          ])),
        for (var i = 0; i < _overheads.length; i++)
          _overheadRow(i),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Align(alignment: Alignment.centerLeft,
            child: TextButton.icon(icon: const Icon(Icons.add, size: 14), label: const Text('Add line', style: TextStyle(fontSize: 12)), onPressed: _addOverhead))),
      ]),
    );
  }

  Widget _overheadRow(int i) {
    final l = _overheads[i];
    final types = _typesFor(l.costType);
    final rate = _rateOf(l);
    // Ensure the currently selected id is a valid dropdown value.
    final ids = types.map((t) => t['id'] as String).toSet();
    final selValue = (l.rateId != null && ids.contains(l.rateId)) ? l.rateId : null;
    return Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 26, child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
        SizedBox(width: 120, child: DropdownButtonFormField<String>(
          value: l.costType,
          isDense: true,
          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
          items: const [
            DropdownMenuItem(value: 'labor', child: Text('Labor', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: 'overhead', child: Text('Overhead', style: TextStyle(fontSize: 12))),
          ],
          onChanged: (v) => setState(() {
            l.costType = v ?? 'overhead';
            final newIds = _typesFor(l.costType).map((t) => t['id'] as String).toSet();
            if (!newIds.contains(l.rateId)) l.rateId = null;
          }))),
        const SizedBox(width: 12),
        Expanded(child: DropdownButtonFormField<String>(
          value: selValue,
          isDense: true, isExpanded: true,
          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
          hint: Text(types.isEmpty ? 'No rates — add in Manage rates' : 'Select a rate', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
          items: types.map((t) => DropdownMenuItem(
            value: t['id'] as String,
            child: Text('${t['name']}  ·  ${_money((t['rate'] as num? ?? 0))}${(t['is_active'] == false) ? ' (inactive)' : ''}',
              style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))).toList(),
          onChanged: (v) => setState(() => l.rateId = v))),
        const SizedBox(width: 12),
        SizedBox(width: 90, child: TextField(controller: l.qtyCtrl, textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: const InputDecoration(hintText: '1', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12), onChanged: (_) => setState(() {}))),
        const SizedBox(width: 12),
        SizedBox(width: 110, child: Text(_money(_amountOf(l)), textAlign: TextAlign.right,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: rate == 0 ? AppTheme.textSecondary : AppTheme.textPrimary))),
        SizedBox(width: 30, child: IconButton(icon: const Icon(Icons.close, size: 14, color: Colors.red),
          onPressed: () => _removeOverhead(i), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact)),
      ]));
  }
}

// =====================================================================
// Manage Rates dialog — the ONE place to edit labor & overhead rates.
// Editing a rate here propagates to every BOM via DB trigger.
// =====================================================================
class _ManageRatesDialog extends StatefulWidget {
  final String orgId;
  final List<Map<String, dynamic>> labor;
  final List<Map<String, dynamic>> overhead;
  const _ManageRatesDialog({required this.orgId, required this.labor, required this.overhead});
  @override State<_ManageRatesDialog> createState() => _ManageRatesDialogState();
}

class _RateRow {
  final String? id;              // null = new
  final TextEditingController nameCtrl;
  final TextEditingController rateCtrl;
  bool active;
  _RateRow({this.id, String name = '', double rate = 0, this.active = true})
      : nameCtrl = TextEditingController(text: name),
        rateCtrl = TextEditingController(text: rate == 0 ? '' : _fmt(rate));
  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
  void dispose() { nameCtrl.dispose(); rateCtrl.dispose(); }
}

class _ManageRatesDialogState extends State<_ManageRatesDialog> {
  late List<_RateRow> _labor;
  late List<_RateRow> _overhead;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _labor = widget.labor.map((r) => _RateRow(id: r['id'] as String?, name: r['name'] as String? ?? '',
        rate: (r['rate'] as num? ?? 0).toDouble(), active: r['is_active'] as bool? ?? true)).toList();
    _overhead = widget.overhead.map((r) => _RateRow(id: r['id'] as String?, name: r['name'] as String? ?? '',
        rate: (r['rate'] as num? ?? 0).toDouble(), active: r['is_active'] as bool? ?? true)).toList();
  }

  @override
  void dispose() {
    for (final r in _labor) r.dispose();
    for (final r in _overhead) r.dispose();
    super.dispose();
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final c = Supabase.instance.client;
      Future<void> persist(String table, String prefix, List<_RateRow> rows) async {
        for (final r in rows) {
          final name = r.nameCtrl.text.trim();
          if (name.isEmpty) continue;
          final rate = double.tryParse(r.rateCtrl.text) ?? 0;
          if (r.id == null) {
            await c.from(table).insert({
              'id': prefix + DateTime.now().microsecondsSinceEpoch.toString(),
              'org_id': widget.orgId, 'name': name, 'rate': rate, 'is_active': r.active,
            });
          } else {
            // update fires the DB propagate trigger -> all BOMs refresh
            await c.from(table).update({
              'name': name, 'rate': rate, 'is_active': r.active,
              'updated_at': DateTime.now().toIso8601String(),
            }).eq('id', r.id as String);
          }
        }
      }
      await persist('labor_types', 'lt_', _labor);
      await persist('overhead_types', 'ot_', _overhead);
      if (mounted) Navigator.pop(context);
    } catch (e) { _snack('Save failed: $e'); }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 640),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: Row(children: [
            const Icon(Icons.tune, size: 18, color: AppTheme.primary),
            const SizedBox(width: 8),
            const Expanded(child: Text('Manage labor & overhead rates', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.pop(context)),
          ])),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text('Rates set here apply to every BOM that uses them. Changing a rate updates all recipes automatically; already-posted production stays at its original cost.',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
        const SizedBox(height: 8),
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _group('Labor rates', _labor, () => setState(() => _labor.add(_RateRow()))),
            const SizedBox(height: 18),
            _group('Overhead rates', _overhead, () => setState(() => _overhead.add(_RateRow()))),
            const SizedBox(height: 10),
          ]))),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.all(14), child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined, size: 16),
            label: const Text('Save rates'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: _saving ? null : _save),
        ])),
      ]),
    ));
  }

  Widget _group(String title, List<_RateRow> rows, VoidCallback onAdd) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Row(children: const [
        Expanded(child: Text('Name', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
        SizedBox(width: 10),
        SizedBox(width: 110, child: Text('Rate', textAlign: TextAlign.right, style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
        SizedBox(width: 10),
        SizedBox(width: 60, child: Text('Active', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
      ]),
      const SizedBox(height: 4),
      for (final r in rows)
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
          Expanded(child: TextField(controller: r.nameCtrl,
            decoration: const InputDecoration(hintText: 'e.g. Direct labor', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
              border: OutlineInputBorder(), enabledBorder: OutlineInputBorder()),
            style: const TextStyle(fontSize: 12))),
          const SizedBox(width: 10),
          SizedBox(width: 110, child: TextField(controller: r.rateCtrl, textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(hintText: '0', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
              border: OutlineInputBorder(), enabledBorder: OutlineInputBorder()),
            style: const TextStyle(fontSize: 12))),
          const SizedBox(width: 10),
          SizedBox(width: 60, child: Center(child: Switch(value: r.active, onChanged: (v) => setState(() => r.active = v)))),
        ])),
      Align(alignment: Alignment.centerLeft,
        child: TextButton.icon(icon: const Icon(Icons.add, size: 14), label: const Text('Add rate', style: TextStyle(fontSize: 12)), onPressed: onAdd)),
    ]);
  }
}

class _ProductField extends StatefulWidget {
  final String initialLabel;
  final List<Map<String, dynamic>> Function(String) filterFn;
  final void Function(Map<String, dynamic>) onPick;
  const _ProductField({super.key, required this.initialLabel, required this.filterFn, required this.onPick});
  @override State<_ProductField> createState() => _ProductFieldState();
}

class _ProductFieldState extends State<_ProductField> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _open = false; String _q = ''; bool _picked = false;

  @override void initState() {
    super.initState();
    _ctrl.text = widget.initialLabel;
    _picked = widget.initialLabel.isNotEmpty;
    _focus.addListener(() { if (!_focus.hasFocus) Future.delayed(const Duration(milliseconds: 160), () { if (mounted && !_focus.hasFocus) setState(() => _open = false); }); });
  }
  @override void dispose() { _ctrl.dispose(); _focus.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) {
    final res = widget.filterFn(_q);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(controller: _ctrl, focusNode: _focus,
        decoration: InputDecoration(hintText: 'Search product...', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          border: OutlineInputBorder(borderSide: BorderSide(color: _picked ? Colors.green : const Color(0xFFE0E0E0))),
          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: _picked ? Colors.green : const Color(0xFFE0E0E0))),
          suffixIcon: _picked ? const Icon(Icons.check_circle, size: 14, color: Colors.green) : null),
        style: const TextStyle(fontSize: 12),
        onChanged: (v) => setState(() { _q = v; _open = true; _picked = false; }),
        onTap: () => setState(() { _q = _picked ? '' : _ctrl.text; _open = true; })),
      if (_open && res.isNotEmpty) Container(constraints: const BoxConstraints(maxHeight: 220), margin: const EdgeInsets.only(top: 2),
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)]),
        child: ListView(shrinkWrap: true, children: res.map((p) => InkWell(
          onTap: () { widget.onPick(p); _ctrl.text = p['label'] as String? ?? ''; setState(() { _open = false; _picked = true; _q = ''; }); _focus.unfocus(); },
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Text(p['label'] as String? ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
        )).toList())),
    ]);
  }
}
