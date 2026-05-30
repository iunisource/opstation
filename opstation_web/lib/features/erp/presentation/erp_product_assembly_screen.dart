import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
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

class ErpProductAssemblyScreen extends ConsumerStatefulWidget {
  const ErpProductAssemblyScreen({super.key});
  @override
  ConsumerState<ErpProductAssemblyScreen> createState() => _State();
}

class _State extends ConsumerState<ErpProductAssemblyScreen> {
  List<Map<String, dynamic>> _products = [];
  Map<String, String> _prodLabel = {};   // id -> label
  bool _loadingProducts = true;

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
  bool _saving = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _isActive => _status == 'active';

  @override
  void initState() {
    super.initState();
    _components = [_BomLine()];
    WidgetsBinding.instance.addPostFrameCallback((_) { _loadProducts(); _loadBoms(); });
  }
  @override
  void dispose() {
    _outputQtyCtrl.dispose(); _nameCtrl.dispose();
    for (final l in _components) l.dispose();
    for (final l in _waste) l.dispose();
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

  List<Map<String, dynamic>> _filterProducts(String q) {
    if (q.isEmpty) return _products.take(50).toList();
    final ql = q.toLowerCase();
    return _products.where((p) => (p['label'] as String).toLowerCase().contains(ql)).take(200).toList();
  }

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
    setState(() {
      _current = null; _fgId = null; _fgLabel = ''; _status = 'active';
      _outputQtyCtrl.text = '1'; _nameCtrl.clear();
      _components = [_BomLine()]; _waste = [];
    });
  }

  Future<void> _loadBom(Map<String, dynamic> b) async {
    try {
      final client = Supabase.instance.client;
      final comps = await client.from('bom_components').select().eq('bom_id', b['id'] as String).order('line_order');
      final wastes = await client.from('bom_waste').select().eq('bom_id', b['id'] as String).order('line_order');
      for (final l in _components) l.dispose();
      for (final l in _waste) l.dispose();
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
      if (mounted) setState(() {
        _current = b;
        _fgId = b['product_id'] as String?;
        _fgLabel = _prodLabel[_fgId] ?? (_fgId ?? '');
        _status = b['status'] as String? ?? 'active';
        _outputQtyCtrl.text = _trim((b['output_qty'] as num? ?? 1).toDouble());
        _nameCtrl.text = b['name'] as String? ?? '';
        _components = newComps.isEmpty ? [_BomLine()] : newComps;
        _waste = newWaste;
      });
    } catch (e) { _snack('Load error: $e'); }
  }

  static String _trim(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  Future<void> _save() async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return; }
    if (_fgId == null) { _snack('Select the finished product'); return; }
    final outQty = double.tryParse(_outputQtyCtrl.text) ?? 0;
    if (outQty <= 0) { _snack('Output quantity must be greater than 0'); return; }
    final comps = _components.where((l) => l.productId != null && l.qty > 0).toList();
    if (comps.isEmpty) { _snack('Add at least one component'); return; }
    final wastes = _waste.where((l) => l.productId != null && l.qty > 0).toList();
    final userId = ref.read(currentUserProvider)?.id ?? '';
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      String bomId, code;
      if (_current == null) {
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
      await c.from('bom_headers').delete().eq('id', id);
      _snack('Deleted'); _newBom(); await _loadBoms();
    } catch (e) { _snack('Delete failed: ' + e.toString()); }
  }

  void _addComp() => setState(() => _components.add(_BomLine()));
  void _removeComp(int i) { setState(() { _components[i].dispose(); _components.removeAt(i); }); if (_components.isEmpty) _addComp(); }
  void _addWaste() => setState(() => _waste.add(_BomLine()));
  void _removeWaste(int i) => setState(() { _waste[i].dispose(); _waste.removeAt(i); });

  @override
  Widget build(BuildContext context) {
    final filtered = _listSearch.isEmpty ? _boms : _boms.where((b) {
      final q = _listSearch.toLowerCase();
      final pname = (_prodLabel[b['product_id']] ?? '').toLowerCase();
      return (b['code'] as String? ?? '').toLowerCase().contains(q) ||
             (b['name'] as String? ?? '').toLowerCase().contains(q) || pname.contains(q);
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
                  onPick: (p) => setState(() { _fgId = p['id'] as String?; _fgLabel = p['label'] as String? ?? ''; })),
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
