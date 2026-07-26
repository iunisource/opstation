import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/permissions/access_control.dart';

class _PComp {
  static int _seq = 0;
  final String id = 'pc_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String? productId; String productLabel = '';
  final TextEditingController qtyCtrl = TextEditingController();
  double unitCostSnap = 0; double lineCostSnap = 0; // populated for posted vouchers
  double get qty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() { qtyCtrl.dispose(); }
}

class _POh {
  static int _seq = 0;
  final String id = 'po_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String costType;
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController amountCtrl = TextEditingController();
  _POh({this.costType = 'overhead'});
  double get amount => double.tryParse(amountCtrl.text) ?? 0;
  void dispose() { descCtrl.dispose(); amountCtrl.dispose(); }
}

class ErpProductionVoucherScreen extends ConsumerStatefulWidget {
  const ErpProductionVoucherScreen({super.key, this.focusId});
  final String? focusId;
  @override
  ConsumerState<ErpProductionVoucherScreen> createState() => _State();
}

class _State extends ConsumerState<ErpProductionVoucherScreen> {
  // products
  List<Map<String, dynamic>> _products = [];
  Map<String, String> _prodLabel = {};
  Map<String, double> _prodCost = {};
  bool _loadingProducts = true;

  // boms
  List<Map<String, dynamic>> _boms = [];

  // voucher list
  List<Map<String, dynamic>> _vouchers = [];
  bool _loadingList = true;
  String _listSearch = '';
  bool _drawerOpen = true;

  // current form
  Map<String, dynamic>? _current;
  DateTime _date = DateTime.now();
  String? _bomId; String _bomLabel = '';
  String? _fgId; String _fgLabel = '';
  double _bomBaseQty = 1;
  final _outputQtyCtrl = TextEditingController(text: '1');
  final _notesCtrl = TextEditingController();
  String _status = 'draft';
  List<_PComp> _components = [];
  List<_POh> _overheads = [];
  List<Map<String, dynamic>> _baseComps = [];
  List<Map<String, dynamic>> _baseOh = [];
  bool _saving = false;
  bool _posting = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  // Costing visibility: admins always; other users need the 'production_cost'
  // grant. Hides the cost summary and the cost/amount columns when absent.
  bool get _canViewCost => ref.read(accessSyncProvider)?.canViewReport('production_cost') ?? false;
  bool get _isDraft => _status != 'posted';
  double get _outQty => double.tryParse(_outputQtyCtrl.text) ?? 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _loadProducts(); _loadBoms(); await _loadVouchers();
      final fid = widget.focusId;
      if (fid != null) {
        try {
          final v = await Supabase.instance.client
              .from('production_vouchers').select().eq('id', fid).maybeSingle();
          if (v != null && mounted) _loadVoucher(Map<String, dynamic>.from(v));
        } catch (_) {}
      }
    });
  }

  @override
  void dispose() {
    _outputQtyCtrl.dispose(); _notesCtrl.dispose();
    for (final l in _components) l.dispose();
    for (final l in _overheads) l.dispose();
    super.dispose();
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }
  static String _trim(double v) { if (v == v.roundToDouble()) return v.toStringAsFixed(0); return v.toString(); }
  static String _money(num v) => NumberFormat('#,##0.00').format(v);

  // ---------- loaders ----------
  Future<void> _loadProducts() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 500)); if (mounted) _loadProducts(); return; }
    try {
      final List<Map<String, dynamic>> all = [];
      int from = 0; const page = 1000;
      while (true) {
        final rows = await Supabase.instance.client.from('products')
            .select('id, name, sku, product_type, cost_price')
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
      }).toList();
      final labelMap = {for (final p in items) p['id'] as String: p['label'] as String};
      final costMap = {for (final p in all) p['id'] as String: (p['cost_price'] as num? ?? 0).toDouble()};
      if (mounted) setState(() { _products = items; _prodLabel = labelMap; _prodCost = costMap; _loadingProducts = false; });
    } catch (e) { if (mounted) { _snack('Products load error: $e'); setState(() => _loadingProducts = false); } }
  }

  List<Map<String, dynamic>> _filterProducts(String q) {
    if (q.isEmpty) return _products.take(50).toList();
    final ql = q.toLowerCase();
    return _products.where((p) => (p['label'] as String).toLowerCase().contains(ql)).take(200).toList();
  }

  Future<void> _loadBoms() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('bom_headers')
          .select().eq('org_id', orgId).eq('status', 'active').order('code').limit(500);
      if (mounted) setState(() => _boms = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  List<Map<String, dynamic>> _filterBoms(String q) {
    final ql = q.toLowerCase();
    final list = _boms.where((b) {
      if (ql.isEmpty) return true;
      final code = (b['code'] as String? ?? '').toLowerCase();
      final name = (b['name'] as String? ?? '').toLowerCase();
      final pn = (_prodLabel[b['product_id']] ?? '').toLowerCase();
      return code.contains(ql) || name.contains(ql) || pn.contains(ql);
    }).take(200).toList();
    return list.map((b) => {
      'id': b['id'],
      'label': "${b['code'] ?? ''} — ${_prodLabel[b['product_id']] ?? (b['name'] ?? '')}",
    }).toList();
  }

  Future<void> _loadVouchers() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loadingList = true);
    try {
      final rows = await Supabase.instance.client.from('production_vouchers')
          .select().eq('org_id', orgId).order('created_at', ascending: false).limit(300);
      if (mounted) setState(() { _vouchers = List<Map<String, dynamic>>.from(rows); _loadingList = false; });
    } catch (e) { if (mounted) setState(() => _loadingList = false); }
  }

  // ---------- form state ----------
  void _newVoucher() {
    for (final l in _components) l.dispose();
    for (final l in _overheads) l.dispose();
    setState(() {
      _current = null; _status = 'draft';
      _date = DateTime.now();
      _bomId = null; _bomLabel = ''; _fgId = null; _fgLabel = ''; _bomBaseQty = 1;
      _outputQtyCtrl.text = '1'; _notesCtrl.clear();
      _components = []; _overheads = []; _baseComps = []; _baseOh = [];
    });
  }

  Future<void> _loadVoucher(Map<String, dynamic> v) async {
    try {
      final client = Supabase.instance.client;
      final comps = await client.from('production_voucher_components').select().eq('voucher_id', v['id'] as String).order('line_order');
      final ohs = await client.from('production_voucher_overheads').select().eq('voucher_id', v['id'] as String).order('line_order');
      for (final l in _components) l.dispose();
      for (final l in _overheads) l.dispose();
      final newComps = (comps as List).map((r) {
        final l = _PComp();
        l.productId = r['product_id'] as String?;
        l.productLabel = _prodLabel[l.productId] ?? (l.productId ?? '');
        final q = (r['quantity'] as num? ?? 0).toDouble();
        if (q != 0) l.qtyCtrl.text = _trim(q);
        l.unitCostSnap = (r['unit_cost'] as num? ?? 0).toDouble();
        l.lineCostSnap = (r['line_cost'] as num? ?? 0).toDouble();
        return l;
      }).toList();
      final newOh = (ohs as List).map((r) {
        final l = _POh(costType: (r['cost_type'] as String?) ?? 'overhead');
        l.descCtrl.text = (r['description'] as String?) ?? '';
        final a = (r['amount'] as num? ?? 0).toDouble();
        if (a != 0) l.amountCtrl.text = _trim(a);
        return l;
      }).toList();
      if (mounted) setState(() {
        _current = v;
        _status = v['status'] as String? ?? 'draft';
        final ds = v['voucher_date'] as String?;
        _date = ds != null ? DateTime.tryParse(ds) ?? DateTime.now() : DateTime.now();
        _bomId = v['bom_id'] as String?;
        _fgId = v['product_id'] as String?;
        _fgLabel = _prodLabel[_fgId] ?? (_fgId ?? '');
        _bomLabel = _bomId != null ? (_boms.firstWhere((b) => b['id'] == _bomId, orElse: () => {})['code'] as String? ?? '') : '';
        _outputQtyCtrl.text = _trim((v['output_qty'] as num? ?? 1).toDouble());
        _notesCtrl.text = v['notes'] as String? ?? '';
        _components = newComps; _overheads = newOh;
      });
      _fetchBase();
    } catch (e) { _snack('Load error: $e'); }
  }

  void _pickBom(String bomId) {
    final bom = _boms.firstWhere((b) => b['id'] == bomId, orElse: () => {});
    if (bom.isEmpty) return;
    setState(() {
      _bomId = bomId;
      _fgId = bom['product_id'] as String?;
      _fgLabel = _prodLabel[_fgId] ?? (_fgId ?? '');
      _bomBaseQty = (bom['output_qty'] as num? ?? 1).toDouble();
      if (_bomBaseQty <= 0) _bomBaseQty = 1;
    });
    _loadBomBase();
  }

  Future<void> _fetchBase() async {
    if (_bomId == null) return;
    try {
      final client = Supabase.instance.client;
      final comps = await client.from('bom_components').select().eq('bom_id', _bomId!).order('line_order');
      final ohs = await client.from('bom_overheads').select().eq('bom_id', _bomId!).order('line_order');
      _baseComps = List<Map<String, dynamic>>.from(comps as List);
      _baseOh = List<Map<String, dynamic>>.from(ohs as List);
    } catch (e) { _snack('BOM load error: $e'); }
  }

  Future<void> _loadBomBase() async { await _fetchBase(); _rescale(); }

  void _rescale() {
    final scale = _bomBaseQty > 0 ? (_outQty / _bomBaseQty) : 1;
    for (final l in _components) l.dispose();
    for (final l in _overheads) l.dispose();
    final nc = _baseComps.map((b) {
      final l = _PComp();
      l.productId = b['product_id'] as String?;
      l.productLabel = _prodLabel[l.productId] ?? (l.productId ?? '');
      final q = (b['quantity'] as num? ?? 0).toDouble() * scale;
      if (q != 0) l.qtyCtrl.text = _trim(double.parse(q.toStringAsFixed(4)));
      return l;
    }).toList();
    final no = _baseOh.map((b) {
      final l = _POh(costType: (b['cost_type'] as String?) ?? 'overhead');
      l.descCtrl.text = (b['description'] as String?) ?? '';
      final a = (b['amount'] as num? ?? 0).toDouble() * scale;
      if (a != 0) l.amountCtrl.text = _trim(double.parse(a.toStringAsFixed(2)));
      return l;
    }).toList();
    if (mounted) setState(() { _components = nc; _overheads = no; });
  }

  // ---------- cost preview ----------
  double get _estCompCost => _components.fold(0.0, (s, l) => s + l.qty * (_prodCost[l.productId] ?? 0));
  double get _ohTotal => _overheads.fold(0.0, (s, l) => s + l.amount);
  double get _estTotal => _estCompCost + _ohTotal;
  double get _estUnit => _outQty > 0 ? _estTotal / _outQty : 0;

  // ---------- save / post / delete ----------
  Future<String?> _save({bool silent = false}) async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return null; }
    if (!_isDraft) { _snack('Posted vouchers cannot be edited'); return _current?['id'] as String?; }
    if (_branchId == null) { _snack('No branch selected — pick one in the sidebar'); return null; }
    if (_fgId == null) { _snack('Pick a BOM (sets the finished product)'); return null; }
    if (_outQty <= 0) { _snack('Output quantity must be greater than 0'); return null; }
    final comps = _components.where((l) => l.productId != null && l.qty > 0).toList();
    final ohs = _overheads.where((l) => l.amount != 0 || l.descCtrl.text.trim().isNotEmpty).toList();
    if (comps.isEmpty && ohs.isEmpty) { _snack('Add at least one component or overhead line'); return null; }
    final userId = ref.read(currentUserProvider)?.id ?? '';
    setState(() => _saving = true);
    String? resultId;
    try {
      final client = Supabase.instance.client;
      String vId, num;
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      if (_current == null) {
        final cnt = await client.from('production_vouchers').select('id').eq('org_id', orgId);
        num = 'PRD-${_date.year}-' + ((cnt as List).length + 1).toString().padLeft(4, '0');
        vId = 'prd_' + DateTime.now().millisecondsSinceEpoch.toString();
        await client.from('production_vouchers').insert({
          'id': vId, 'org_id': orgId, 'branch_id': _branchId, 'voucher_number': num,
          'voucher_date': dateStr, 'bom_id': _bomId, 'product_id': _fgId, 'output_qty': _outQty,
          'status': 'draft', 'is_locked': false, 'notes': _notesCtrl.text.trim(),
          'created_by': userId, 'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });
      } else {
        vId = _current!['id'] as String; num = _current!['voucher_number'] as String? ?? '';
        await client.from('production_vouchers').update({
          'branch_id': _branchId, 'voucher_date': dateStr, 'bom_id': _bomId, 'product_id': _fgId,
          'output_qty': _outQty, 'notes': _notesCtrl.text.trim(), 'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', vId);
      }
      await client.from('production_voucher_components').delete().eq('voucher_id', vId);
      for (var i = 0; i < comps.length; i++) {
        await client.from('production_voucher_components').insert({
          'id': vId + '_c' + i.toString(), 'voucher_id': vId,
          'product_id': comps[i].productId, 'quantity': comps[i].qty, 'line_order': i,
        });
      }
      await client.from('production_voucher_overheads').delete().eq('voucher_id', vId);
      for (var i = 0; i < ohs.length; i++) {
        await client.from('production_voucher_overheads').insert({
          'id': vId + '_o' + i.toString(), 'voucher_id': vId,
          'cost_type': ohs[i].costType, 'description': ohs[i].descCtrl.text.trim(),
          'amount': ohs[i].amount, 'line_order': i,
        });
      }
      resultId = vId;
      final updated = await client.from('production_vouchers').select().eq('id', vId).single();
      if (mounted) setState(() => _current = updated);
      if (!silent) _snack('Production voucher $num saved (draft)');
      await _loadVouchers();
    } catch (e) { _snack('Save failed: ' + e.toString()); }
    if (mounted) setState(() => _saving = false);
    return resultId;
  }

  Future<void> _post() async {
    if (!_isDraft) return;
    final id = await _save(silent: true);
    if (id == null) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Post production?'),
      content: const Text('Components will be consumed from stock (FIFO) and the finished good added to inventory at full absorbed cost. This posts to the General Ledger and cannot be edited afterward (use a Production Inverse to reverse).'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Post')),
      ],
    ));
    if (ok != true) return;
    setState(() => _posting = true);
    try {
      final client = Supabase.instance.client;
      await client.from('production_vouchers').update({'is_locked': true}).eq('id', id);
      final res = await client.rpc('post_production_voucher', params: {'p_id': id});
      _snack(res?.toString() ?? 'Posted');
      final updated = await client.from('production_vouchers').select().eq('id', id).single();
      if (mounted) setState(() { _current = updated; _status = updated['status'] as String? ?? 'posted'; });
      await _loadVouchers();
      await _loadVoucher(updated);
    } catch (e) { _snack('Post failed: ' + e.toString()); }
    if (mounted) setState(() => _posting = false);
  }

  Future<void> _delete() async {
    if (_current == null) return;
    if (!_isDraft) { _snack('Posted vouchers cannot be deleted — use a Production Inverse'); return; }
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete draft?'),
      content: const Text('This draft production voucher will be permanently deleted.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('production_vouchers').delete().eq('id', _current!['id'] as String);
      _snack('Draft deleted');
      _newVoucher();
      await _loadVouchers();
    } catch (e) { _snack('Delete failed: $e'); }
  }


  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final filtered = _listSearch.isEmpty ? _vouchers : _vouchers.where((v) {
      final q = _listSearch.toLowerCase();
      final pn = (_prodLabel[v['product_id']] ?? '').toLowerCase();
      return (v['voucher_number'] as String? ?? '').toLowerCase().contains(q) || pn.contains(q);
    }).toList();

    return Container(color: AppTheme.background, child: Row(children: [
      if (_drawerOpen) Container(width: 300,
        decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
        child: Column(children: [
          Container(padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Column(children: [
              Row(children: [
                const Expanded(child: Text('Production Vouchers', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                ElevatedButton.icon(icon: const Icon(Icons.add, size: 13), label: const Text('New', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero),
                  onPressed: _newVoucher),
              ]),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search...', prefixIcon: Icon(Icons.search, size: 15), isDense: true),
                onChanged: (v) => setState(() => _listSearch = v)),
            ])),
          Expanded(child: _loadingList ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : filtered.isEmpty ? const Center(child: Text('No production vouchers yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
                final v = filtered[i]; final sel = _current?['id'] == v['id'];
                final posted = (v['status'] as String? ?? 'draft') == 'posted';
                return InkWell(onTap: () => _loadVoucher(v), child: Container(
                  color: sel ? AppTheme.primary.withOpacity(0.07) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(v['voucher_number'] as String? ?? '', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : AppTheme.textPrimary))),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(color: (posted ? Colors.green : Colors.orange).withOpacity(0.13), borderRadius: BorderRadius.circular(3)),
                        child: Text(posted ? 'Posted' : 'Draft', style: TextStyle(fontSize: 9, color: posted ? Colors.green.shade700 : Colors.orange.shade800, fontWeight: FontWeight.w700))),
                    ]),
                    const SizedBox(height: 2),
                    Text(_prodLabel[v['product_id']] ?? '', style: TextStyle(fontSize: 11, color: sel ? AppTheme.primary : AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                    Text('${v['voucher_date'] ?? ''}  ·  qty ${_trim((v['output_qty'] as num? ?? 0).toDouble())}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
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
            Expanded(child: Text(_current?['voucher_number'] as String? ?? 'New Production Voucher', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            if (!_isDraft) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.green.withOpacity(0.13), borderRadius: BorderRadius.circular(4)),
              child: Text('Posted', style: TextStyle(fontSize: 11, color: Colors.green.shade700, fontWeight: FontWeight.w700))),
            if (_isDraft && _current != null) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: _delete, tooltip: 'Delete draft'),
            const SizedBox(width: 8),
            if (_isDraft) OutlinedButton.icon(
              icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save draft'),
              onPressed: _saving || _posting ? null : () => _save()),
            const SizedBox(width: 8),
            if (_isDraft) ElevatedButton.icon(
              icon: _posting ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('Post'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
              onPressed: _saving || _posting ? null : _post),
          ])),
        Expanded(child: _loadingProducts
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Loading...', style: TextStyle(color: AppTheme.textSecondary))]))
          : SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // header row
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 220, child: _labeled('Branch', _readonlyBox((ref.watch(selectedBranchProvider)?['name'] as String?) ?? '—'))),
              const SizedBox(width: 16),
              SizedBox(width: 150, child: _labeled('Date', _dateField())),
              const SizedBox(width: 16),
              Expanded(child: _labeled('Bill of Materials *', _isDraft
                ? _ProductField(key: ValueKey('bom_${_current?['id'] ?? 'new'}_$_bomId'), initialLabel: _bomLabel.isEmpty ? '' : (_bomLabel + (_fgLabel.isNotEmpty ? ' — $_fgLabel' : '')), filterFn: _filterBoms, onPick: (b) => _pickBom(b['id'] as String))
                : _readonlyBox(_bomLabel.isEmpty ? '—' : _bomLabel))),
              const SizedBox(width: 16),
              SizedBox(width: 130, child: _labeled('Output Qty *', _outputQtyField())),
            ]),
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _labeled('Finished Product', _readonlyBox(_fgLabel.isEmpty ? 'Select a BOM' : _fgLabel, maxLines: 3))),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: _labeled('Notes', TextField(controller: _notesCtrl, enabled: _isDraft,
                decoration: const InputDecoration(hintText: 'Optional', isDense: true, border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12))))),
            ]),
            if (_canViewCost) ...[
              const SizedBox(height: 20),
              _summaryCard(),
            ],
            const SizedBox(height: 20),
            _compSection(),
            const SizedBox(height: 20),
            _ohSection(),
            const SizedBox(height: 30),
          ]))),
      ])),
    ]));
  }

  Widget _labeled(String label, Widget child) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
    const SizedBox(height: 4), child,
  ]);

  Widget _readonlyBox(String text, {int maxLines = 1}) => Container(width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFE0E0E0))),
    child: Text(text, style: const TextStyle(fontSize: 12), softWrap: true, maxLines: maxLines, overflow: TextOverflow.ellipsis));

  Widget _dateField() => InkWell(
    onTap: _isDraft ? () async {
      final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
      if (d != null) setState(() => _date = d);
    } : null,
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFE0E0E0))),
      child: Row(children: [
        Expanded(child: Text(DateFormat('yyyy-MM-dd').format(_date), style: const TextStyle(fontSize: 12))),
        const Icon(Icons.calendar_today_outlined, size: 13, color: AppTheme.textSecondary),
      ])));

  Widget _outputQtyField() => TextField(controller: _outputQtyCtrl, enabled: _isDraft,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
    onChanged: (_) => _rescale());

  Widget _summaryCard() {
    final posted = !_isDraft;
    final compCost = posted ? (_current?['total_component_cost'] as num? ?? 0).toDouble() : _estCompCost;
    final ohCost = posted ? (_current?['total_overhead_cost'] as num? ?? 0).toDouble() : _ohTotal;
    final total = posted ? (_current?['total_cost'] as num? ?? 0).toDouble() : _estTotal;
    final unit = posted ? (_current?['fg_unit_cost'] as num? ?? 0).toDouble() : _estUnit;
    return Container(padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(posted ? 'Cost (posted, actual FIFO)' : 'Cost (estimate — actual FIFO computed at posting)',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: posted ? Colors.green.shade700 : AppTheme.textSecondary)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _costCell('Components', compCost, AppTheme.primary),
          _costCell('Labor & Overhead', ohCost, Colors.teal),
          _costCell('Total absorbed', total, AppTheme.textPrimary, bold: true),
          _costCell('Unit cost', unit, Colors.deepPurple, bold: true, decimals: 4),
        ]),
      ]));
  }

  Widget _costCell(String label, double v, Color c, {bool bold = false, int decimals = 2}) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
    const SizedBox(height: 3),
    Text(decimals == 4 ? NumberFormat('#,##0.0000').format(v) : _money(v), style: TextStyle(fontSize: bold ? 16 : 14, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: c)),
  ]));

  Widget _compSection() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          child: Row(children: [
            Container(width: 6, height: 14, decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            const Text('Components (consumed)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            const Expanded(child: Text('Derived from the BOM, scaled to Output Qty. Locked to the recipe.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
          ])),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            const SizedBox(width: 26, child: Text('#', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            const Expanded(child: Text('Product', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            const SizedBox(width: 12),
            const SizedBox(width: 110, child: Text('Quantity', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            if (_canViewCost) ...[
              const SizedBox(width: 12),
              const SizedBox(width: 120, child: Text('Cost', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            ],
            const SizedBox(width: 30),
          ])),
        for (var i = 0; i < _components.length; i++)
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 26, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))),
              Expanded(child: Padding(padding: const EdgeInsets.only(top: 8), child: Text(_components[i].productLabel, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
              const SizedBox(width: 12),
              SizedBox(width: 110, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text(_trim(_components[i].qty), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)))),
              if (_canViewCost) ...[
                const SizedBox(width: 12),
                SizedBox(width: 120, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text(
                  _isDraft ? _money(_components[i].qty * (_prodCost[_components[i].productId] ?? 0)) : _money(_components[i].lineCostSnap),
                  textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)))),
              ],
              const SizedBox(width: 30),
            ])),
      ]),
    );
  }

  Widget _ohSection() {
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
            Expanded(child: Text(_canViewCost ? 'Total ${_money(_ohTotal)} — added to finished-goods cost.' : 'Added to finished-goods cost at production.', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
          ])),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            const SizedBox(width: 26, child: Text('#', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            const SizedBox(width: 130, child: Text('Type', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            const SizedBox(width: 12),
            const Expanded(child: Text('Description', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            if (_canViewCost) ...[
              const SizedBox(width: 12),
              const SizedBox(width: 130, child: Text('Amount', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            ],
            const SizedBox(width: 30),
          ])),
        for (var i = 0; i < _overheads.length; i++)
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              SizedBox(width: 26, child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
              SizedBox(width: 130, child: Text(_overheads[i].costType == 'labor' ? 'Labor' : 'Overhead', style: const TextStyle(fontSize: 12))),
              const SizedBox(width: 12),
              Expanded(child: Text(_overheads[i].descCtrl.text, style: const TextStyle(fontSize: 12))),
              if (_canViewCost) ...[
                const SizedBox(width: 12),
                SizedBox(width: 130, child: Text(_money(_overheads[i].amount), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
              ],
              const SizedBox(width: 30),
            ])),
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
        decoration: InputDecoration(hintText: 'Search...', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
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
