import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/format/money.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/layout/main_layout.dart';

class _RComp {
  static int _seq = 0;
  final String id = 'rc_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String? productId; String productLabel = '';
  final TextEditingController qtyCtrl = TextEditingController();
  double unitCostSnap = 0; double lineCostSnap = 0; // posted snapshot
  double get qty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() { qtyCtrl.dispose(); }
}

class ErpProductionInverseVoucherScreen extends ConsumerStatefulWidget {
  const ErpProductionInverseVoucherScreen({super.key});
  @override
  ConsumerState<ErpProductionInverseVoucherScreen> createState() => _State();
}

class _State extends ConsumerState<ErpProductionInverseVoucherScreen> {
  List<Map<String, dynamic>> _products = [];
  Map<String, String> _prodLabel = {};
  Map<String, double> _prodCost = {};
  bool _loadingProducts = true;

  List<Map<String, dynamic>> _boms = [];

  List<Map<String, dynamic>> _vouchers = [];
  bool _loadingList = true;
  String _listSearch = '';
  bool _drawerOpen = true;

  Map<String, dynamic>? _current;
  DateTime _date = DateTime.now();
  String? _bomId; String _bomLabel = '';
  String? _fgId; String _fgLabel = '';
  double _bomBaseQty = 1;
  final _inputQtyCtrl = TextEditingController(text: '1');
  final _notesCtrl = TextEditingController();
  String _status = 'draft';
  List<_RComp> _components = [];
  List<Map<String, dynamic>> _baseComps = [];
  List<Map<String, dynamic>> _fgLayers = [];
  bool _saving = false;
  bool _posting = false;

  // Source mode: reverse a posted production voucher (recommended, actual
  // costs) or free-pick any BOM (for stock with no voucher on record).
  String _sourceMode = 'voucher'; // 'voucher' | 'free'
  List<Map<String, dynamic>> _prodVouchers = [];
  String? _srcVoucherId; String _srcVoucherLabel = '';
  double _srcOutputQty = 0; // max qty that can be broken (the produced qty)

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isDraft => _status != 'posted';
  double get _inQty => double.tryParse(_inputQtyCtrl.text) ?? 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadProducts(); _loadBoms(); _loadVouchers(); _loadProdVouchers();
    });
  }

  @override
  void dispose() {
    _inputQtyCtrl.dispose(); _notesCtrl.dispose();
    for (final l in _components) l.dispose();
    super.dispose();
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }
  static String _trim(double v) { if (v == v.roundToDouble()) return v.toStringAsFixed(0); return v.toString(); }
  static String _money(num v) => money(v);

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

  // Posted production vouchers available to reverse.
  Future<void> _loadProdVouchers() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('production_vouchers')
          .select('id, voucher_number, voucher_date, bom_id, product_id, output_qty, total_cost, fg_unit_cost')
          .eq('org_id', orgId).eq('status', 'posted')
          .order('voucher_date', ascending: false).limit(500);
      if (mounted) setState(() => _prodVouchers = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  List<Map<String, dynamic>> _filterProdVouchers(String q) {
    final ql = q.toLowerCase();
    final list = _prodVouchers.where((v) {
      if (ql.isEmpty) return true;
      final num = (v['voucher_number'] as String? ?? '').toLowerCase();
      final pn = (_prodLabel[v['product_id']] ?? '').toLowerCase();
      return num.contains(ql) || pn.contains(ql);
    }).take(200).toList();
    return list.map((v) => {
      'id': v['id'],
      'label': "${v['voucher_number'] ?? ''} — ${_prodLabel[v['product_id']] ?? ''}  (made ${_trim((v['output_qty'] as num? ?? 0).toDouble())} · ${v['voucher_date'] ?? ''})",
    }).toList();
  }

  // Pre-fill from a posted production voucher: exact product, BOM, components,
  // their ACTUAL consumed unit costs, and cap the quantity at what was made.
  Future<void> _pickProdVoucher(String vId) async {
    final v = _prodVouchers.firstWhere((x) => x['id'] == vId, orElse: () => {});
    if (v.isEmpty) return;
    try {
      final comps = await Supabase.instance.client.from('production_voucher_components')
          .select().eq('voucher_id', vId).order('line_order');
      final list = List<Map<String, dynamic>>.from(comps as List);
      for (final l in _components) l.dispose();
      final outQty = (v['output_qty'] as num? ?? 1).toDouble();
      final base = list.map((b) => {
        'product_id': b['product_id'],
        'quantity': (b['quantity'] as num? ?? 0).toDouble(),
        'unit_cost': (b['unit_cost'] as num? ?? 0).toDouble(),
      }).toList();
      setState(() {
        _srcVoucherId = vId;
        _srcVoucherLabel = v['voucher_number'] as String? ?? '';
        _srcOutputQty = outQty > 0 ? outQty : 1;
        _bomId = v['bom_id'] as String?;
        _fgId = v['product_id'] as String?;
        _fgLabel = _prodLabel[_fgId] ?? (_fgId ?? '');
        _bomLabel = _bomId != null ? (_boms.firstWhere((b) => b['id'] == _bomId, orElse: () => {})['code'] as String? ?? '') : '';
        _bomBaseQty = _srcOutputQty;
        _inputQtyCtrl.text = _trim(_srcOutputQty);
        _baseComps = base;
      });
      _rescale();
      _loadFgLayers();
    } catch (e) { _snack(friendlyError('Could not load the production voucher', e)); }
  }

  void _setSourceMode(String m) {
    if (m == _sourceMode) return;
    for (final l in _components) l.dispose();
    setState(() {
      _sourceMode = m;
      _srcVoucherId = null; _srcVoucherLabel = ''; _srcOutputQty = 0;
      _bomId = null; _bomLabel = ''; _fgId = null; _fgLabel = ''; _bomBaseQty = 1;
      _inputQtyCtrl.text = '1';
      _components = []; _baseComps = []; _fgLayers = [];
    });
  }

  Future<void> _loadVouchers() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loadingList = true);
    try {
      final rows = await Supabase.instance.client.from('production_inverse_vouchers')
          .select().eq('org_id', orgId).order('created_at', ascending: false).limit(300);
      if (mounted) setState(() { _vouchers = List<Map<String, dynamic>>.from(rows); _loadingList = false; });
    } catch (e) { if (mounted) setState(() => _loadingList = false); }
  }

  // ---------- form state ----------
  void _newVoucher() {
    for (final l in _components) l.dispose();
    setState(() {
      _current = null; _status = 'draft';
      _date = DateTime.now();
      _bomId = null; _bomLabel = ''; _fgId = null; _fgLabel = ''; _bomBaseQty = 1;
      _srcVoucherId = null; _srcVoucherLabel = ''; _srcOutputQty = 0;
      _inputQtyCtrl.text = '1'; _notesCtrl.clear();
      _components = []; _fgLayers = []; _baseComps = [];
    });
  }

  Future<void> _loadVoucher(Map<String, dynamic> v) async {
    try {
      final client = Supabase.instance.client;
      final comps = await client.from('production_inverse_components').select().eq('voucher_id', v['id'] as String).order('line_order');
      for (final l in _components) l.dispose();
      final newComps = (comps as List).map((r) {
        final l = _RComp();
        l.productId = r['product_id'] as String?;
        l.productLabel = _prodLabel[l.productId] ?? (l.productId ?? '');
        final q = (r['quantity'] as num? ?? 0).toDouble();
        if (q != 0) l.qtyCtrl.text = _trim(q);
        l.unitCostSnap = (r['unit_cost'] as num? ?? 0).toDouble();
        l.lineCostSnap = (r['line_cost'] as num? ?? 0).toDouble();
        return l;
      }).toList();
      if (mounted) setState(() {
        _current = v;
        _status = v['status'] as String? ?? 'draft';
        _srcVoucherId = v['source_voucher_id'] as String?;
        _sourceMode = _srcVoucherId != null ? 'voucher' : 'free';
        _srcVoucherLabel = _srcVoucherId != null
            ? (_prodVouchers.firstWhere((x) => x['id'] == _srcVoucherId, orElse: () => {})['voucher_number'] as String? ?? '')
            : '';
        final ds = v['voucher_date'] as String?;
        _date = ds != null ? DateTime.tryParse(ds) ?? DateTime.now() : DateTime.now();
        _bomId = v['bom_id'] as String?;
        _fgId = v['product_id'] as String?;
        _fgLabel = _prodLabel[_fgId] ?? (_fgId ?? '');
        _bomLabel = _bomId != null ? (_boms.firstWhere((b) => b['id'] == _bomId, orElse: () => {})['code'] as String? ?? '') : '';
        _inputQtyCtrl.text = _trim((v['input_qty'] as num? ?? 1).toDouble());
        _notesCtrl.text = v['notes'] as String? ?? '';
        _components = newComps;
      });
      _fetchBase();
      _loadFgLayers();
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
    _loadFgLayers();
  }

  Future<void> _fetchBase() async {
    if (_bomId == null) return;
    try {
      final comps = await Supabase.instance.client.from('bom_components').select().eq('bom_id', _bomId!).order('line_order');
      _baseComps = List<Map<String, dynamic>>.from(comps as List);
    } catch (e) { _snack('BOM load error: $e'); }
  }

  Future<void> _loadBomBase() async { await _fetchBase(); _rescale(); }

  void _rescale() {
    final scale = _bomBaseQty > 0 ? (_inQty / _bomBaseQty) : 1;
    for (final l in _components) l.dispose();
    final nc = _baseComps.map((b) {
      final l = _RComp();
      l.productId = b['product_id'] as String?;
      l.productLabel = _prodLabel[l.productId] ?? (l.productId ?? '');
      final q = (b['quantity'] as num? ?? 0).toDouble() * scale;
      if (q != 0) l.qtyCtrl.text = _trim(double.parse(q.toStringAsFixed(4)));
      // Actual per-unit cost from the source production run (voucher mode).
      l.unitCostSnap = (b['unit_cost'] as num?)?.toDouble() ?? 0;
      return l;
    }).toList();
    if (mounted) setState(() => _components = nc);
  }

  // Value basis per component line: actual run cost in voucher mode (when we
  // captured one), otherwise today's product cost.
  double _unitCostFor(_RComp l) =>
      (_sourceMode == 'voucher' && l.unitCostSnap > 0) ? l.unitCostSnap : (_prodCost[l.productId] ?? 0);

  // ---------- finished-good FIFO cost (for an accurate estimate) ----------
  Future<void> _loadFgLayers() async {
    _fgLayers = [];
    final orgId = _orgId; final fg = _fgId;
    if (orgId == null || fg == null) { if (mounted) setState(() {}); return; }
    try {
      final base = Supabase.instance.client.from('inventory_cost_layers')
          .select('qty_remaining, unit_cost, layer_date, seq')
          .eq('org_id', orgId).eq('product_id', fg).gt('qty_remaining', 0);
      final rows = _branchId != null
          ? await base.eq('branch_id', _branchId!).order('layer_date').order('seq')
          : await base.order('layer_date').order('seq');
      if (mounted) setState(() => _fgLayers = List<Map<String, dynamic>>.from(rows));
    } catch (_) { if (mounted) setState(() {}); }
  }

  double _fifoFgCost(double qty) {
    double need = qty, cost = 0, last = 0;
    for (final l in _fgLayers) {
      if (need <= 0) break;
      final avail = (l['qty_remaining'] as num?)?.toDouble() ?? 0;
      final uc = (l['unit_cost'] as num?)?.toDouble() ?? 0;
      final take = need < avail ? need : avail;
      cost += take * uc; need -= take; last = uc;
    }
    if (need > 0) { cost += need * (last != 0 ? last : (_prodCost[_fgId] ?? 0)); }
    return cost;
  }

  // ---------- cost preview ----------
  double get _estCompVal => _components.fold(0.0, (s, l) => s + l.qty * _unitCostFor(l));
  double get _estFgCost => _fifoFgCost(_inQty);
  double get _estVariance => _estFgCost - _estCompVal;

  // ---------- save / post / delete ----------
  Future<String?> _save({bool silent = false}) async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return null; }
    if (!_isDraft) { _snack('Posted vouchers cannot be edited'); return _current?['id'] as String?; }
    if (_branchId == null) { _snack('No branch selected — pick one in the sidebar'); return null; }
    if (_sourceMode == 'voucher' && _srcVoucherId == null) { _snack('Pick a production voucher to reverse'); return null; }
    if (_fgId == null) { _snack(_sourceMode == 'voucher' ? 'Pick a production voucher (sets the finished product)' : 'Pick a BOM (sets the finished product)'); return null; }
    if (_inQty <= 0) { _snack('Quantity to disassemble must be greater than 0'); return null; }
    if (_sourceMode == 'voucher' && _srcOutputQty > 0 && _inQty > _srcOutputQty) {
      _snack('Quantity to break cannot exceed the produced quantity (${_trim(_srcOutputQty)})'); return null;
    }
    final comps = _components.where((l) => l.productId != null && l.qty > 0).toList();
    if (comps.isEmpty) { _snack('Add at least one recovered component'); return null; }
    final userId = ref.read(currentUserProvider)?.id ?? '';
    setState(() => _saving = true);
    String? resultId;
    try {
      final client = Supabase.instance.client;
      String vId, num;
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      if (_current == null) {
        final cnt = await client.from('production_inverse_vouchers').select('id').eq('org_id', orgId);
        num = 'PRDI-${_date.year}-' + ((cnt as List).length + 1).toString().padLeft(4, '0');
        vId = 'prdi_' + DateTime.now().millisecondsSinceEpoch.toString();
        await client.from('production_inverse_vouchers').insert({
          'id': vId, 'org_id': orgId, 'branch_id': _branchId, 'voucher_number': num,
          'voucher_date': dateStr, 'bom_id': _bomId, 'product_id': _fgId, 'input_qty': _inQty,
          'source_voucher_id': _sourceMode == 'voucher' ? _srcVoucherId : null,
          'status': 'draft', 'is_locked': false, 'notes': _notesCtrl.text.trim(),
          'created_by': userId, 'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });
      } else {
        vId = _current!['id'] as String; num = _current!['voucher_number'] as String? ?? '';
        await client.from('production_inverse_vouchers').update({
          'branch_id': _branchId, 'voucher_date': dateStr, 'bom_id': _bomId, 'product_id': _fgId,
          'source_voucher_id': _sourceMode == 'voucher' ? _srcVoucherId : null,
          'input_qty': _inQty, 'notes': _notesCtrl.text.trim(), 'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', vId);
      }
      await client.from('production_inverse_components').delete().eq('voucher_id', vId);
      for (var i = 0; i < comps.length; i++) {
        final row = <String, dynamic>{
          'id': vId + '_c' + i.toString(), 'voucher_id': vId,
          'product_id': comps[i].productId, 'quantity': comps[i].qty, 'line_order': i,
        };
        // Store actual run cost only in voucher mode; free mode leaves it null
        // so posting falls back to current inventory cost (unchanged behaviour).
        if (_sourceMode == 'voucher' && comps[i].unitCostSnap > 0) row['unit_cost'] = comps[i].unitCostSnap;
        await client.from('production_inverse_components').insert(row);
      }
      resultId = vId;
      final updated = await client.from('production_inverse_vouchers').select().eq('id', vId).single();
      if (mounted) setState(() => _current = updated);
      if (!silent) _snack('Disassembly $num saved (draft)');
      await _loadVouchers();
    } catch (e) { _snack(friendlyError('Could not save the disassembly voucher', e)); }
    if (mounted) setState(() => _saving = false);
    return resultId;
  }

  Future<void> _post() async {
    if (!_isDraft) return;
    final id = await _save(silent: true);
    if (id == null) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Post disassembly?'),
      content: const Text('The finished good will be removed from stock (FIFO) and the recovered components returned to stock at standard cost. Any absorbed labor/overhead that cannot be recovered is written off to Inventory Adjustment. This posts to the General Ledger and cannot be edited afterward.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Post')),
      ],
    ));
    if (ok != true) return;
    setState(() => _posting = true);
    try {
      final client = Supabase.instance.client;
      await client.from('production_inverse_vouchers').update({'is_locked': true}).eq('id', id);
      final res = await client.rpc('post_production_inverse_voucher', params: {'p_id': id});
      _snack(res?.toString() ?? 'Posted');
      final updated = await client.from('production_inverse_vouchers').select().eq('id', id).single();
      if (mounted) setState(() { _current = updated; _status = updated['status'] as String? ?? 'posted'; });
      await _loadVouchers();
      await _loadVoucher(updated);
    } catch (e) { _snack(friendlyError('Could not post the disassembly voucher', e)); }
    if (mounted) setState(() => _posting = false);
  }

  Future<void> _delete() async {
    if (_current == null) return;
    if (!_isDraft) { _snack('Posted vouchers cannot be deleted — reverse via Void'); return; }
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete draft?'),
      content: const Text('This draft disassembly voucher will be permanently deleted.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('production_inverse_vouchers').delete().eq('id', _current!['id'] as String);
      _snack('Draft deleted');
      _newVoucher();
      await _loadVouchers();
    } catch (e) { _snack(friendlyError('Could not delete the draft', e)); }
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
                const Expanded(child: Text('Disassembly Vouchers', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                ElevatedButton.icon(icon: const Icon(Icons.add, size: 13), label: const Text('New', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero),
                  onPressed: _newVoucher),
              ]),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search...', prefixIcon: Icon(Icons.search, size: 15), isDense: true),
                onChanged: (v) => setState(() => _listSearch = v)),
            ])),
          Expanded(child: _loadingList ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : filtered.isEmpty ? const Center(child: Text('No disassembly vouchers yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
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
                    Text('${v['voucher_date'] ?? ''}  ·  qty ${_trim((v['input_qty'] as num? ?? 0).toDouble())}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
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
            Expanded(child: Text(_current?['voucher_number'] as String? ?? 'New Disassembly', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
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
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 220, child: _labeled('Branch', _readonlyBox((ref.watch(selectedBranchProvider)?['name'] as String?) ?? '—'))),
              const SizedBox(width: 16),
              SizedBox(width: 150, child: _labeled('Date', _dateField())),
              const SizedBox(width: 16),
              Expanded(child: _labeled('Source', _sourceToggle())),
            ]),
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_sourceMode == 'voucher')
                Expanded(child: _labeled('Production Voucher to reverse *', _isDraft
                  ? _ProductField(key: ValueKey('pv_${_current?['id'] ?? 'new'}_$_srcVoucherId'), initialLabel: _srcVoucherLabel.isEmpty ? '' : (_srcVoucherLabel + (_fgLabel.isNotEmpty ? ' — $_fgLabel' : '')), filterFn: _filterProdVouchers, onPick: (v) => _pickProdVoucher(v['id'] as String))
                  : _readonlyBox(_srcVoucherLabel.isEmpty ? '—' : (_srcVoucherLabel + (_fgLabel.isNotEmpty ? ' — $_fgLabel' : '')))))
              else
                Expanded(child: _labeled('Bill of Materials *', _isDraft
                  ? _ProductField(key: ValueKey('bom_${_current?['id'] ?? 'new'}_$_bomId'), initialLabel: _bomLabel.isEmpty ? '' : (_bomLabel + (_fgLabel.isNotEmpty ? ' — $_fgLabel' : '')), filterFn: _filterBoms, onPick: (b) => _pickBom(b['id'] as String))
                  : _readonlyBox(_bomLabel.isEmpty ? '—' : _bomLabel))),
              const SizedBox(width: 16),
              SizedBox(width: 150, child: _labeled(_sourceMode == 'voucher' && _srcOutputQty > 0 ? 'Qty to break * (max ${_trim(_srcOutputQty)})' : 'Qty to break *', _inputQtyField())),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _labeled('Finished Product (disassembled)', _readonlyBox(_fgLabel.isEmpty ? (_sourceMode == 'voucher' ? 'Select a production voucher' : 'Select a BOM') : _fgLabel))),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: _labeled('Notes', TextField(controller: _notesCtrl, enabled: _isDraft,
                decoration: const InputDecoration(hintText: 'Optional', isDense: true, border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12))))),
            ]),
            const SizedBox(height: 20),
            _summaryCard(),
            const SizedBox(height: 20),
            _compSection(),
            const SizedBox(height: 30),
          ]))),
      ])),
    ]));
  }

  Widget _sourceToggle() {
    final enabled = _isDraft && _current == null; // lock the mode once a draft exists
    Widget seg(String mode, String label, String sub) {
      final on = _sourceMode == mode;
      return Expanded(child: InkWell(
        onTap: enabled && !on ? () => _setSourceMode(mode) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: on ? AppTheme.primary.withOpacity(0.10) : Colors.white,
            border: Border.all(color: on ? AppTheme.primary : const Color(0xFFE0E0E0)),
            borderRadius: BorderRadius.circular(4)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(on ? Icons.radio_button_checked : Icons.radio_button_off, size: 14, color: on ? AppTheme.primary : AppTheme.textSecondary),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: on ? AppTheme.primary : AppTheme.textPrimary)),
            ]),
            const SizedBox(height: 2),
            Text(sub, style: const TextStyle(fontSize: 9.5, color: AppTheme.textSecondary)),
          ]))));
    }
    return Row(children: [
      seg('voucher', 'From production voucher', 'Actual costs · qty capped to what was made'),
      const SizedBox(width: 8),
      seg('free', 'Free (any BOM)', 'For stock with no voucher on record'),
    ]);
  }

  Widget _labeled(String label, Widget child) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
    const SizedBox(height: 4), child,
  ]);

  Widget _readonlyBox(String text) => Container(width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFE0E0E0))),
    child: Text(text, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis));

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

  Widget _inputQtyField() => TextField(controller: _inputQtyCtrl, enabled: _isDraft,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
    onChanged: (_) => _rescale());

  Widget _summaryCard() {
    final posted = !_isDraft;
    final fgCost = posted ? (_current?['fg_cost'] as num? ?? 0).toDouble() : _estFgCost;
    final compVal = posted ? (_current?['component_value'] as num? ?? 0).toDouble() : _estCompVal;
    final variance = posted ? (_current?['variance'] as num? ?? 0).toDouble() : _estVariance;
    final lossLabel = variance >= 0 ? 'Variance (loss)' : 'Variance (gain)';
    final varColor = variance > 0 ? Colors.red.shade600 : (variance < 0 ? Colors.green.shade700 : AppTheme.textSecondary);
    return Container(padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(posted ? 'Cost (posted, actual FIFO)' : 'Cost (estimate — actual FIFO computed at posting)',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: posted ? Colors.green.shade700 : AppTheme.textSecondary)),
        const SizedBox(height: 10),
        Row(children: [
          _costCell('Finished good (out)', fgCost, AppTheme.primary),
          _costCell('Components recovered (in)', compVal, Colors.teal),
          _costCell(lossLabel, variance.abs(), varColor, bold: true),
        ]),
        const SizedBox(height: 6),
        const Text('Labor/overhead that cannot be recovered is written off to Inventory Adjustment.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      ]));
  }

  Widget _costCell(String label, double v, Color c, {bool bold = false}) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
    const SizedBox(height: 3),
    Text(_money(v), style: TextStyle(fontSize: bold ? 16 : 14, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: c)),
  ]));

  Widget _compSection() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          child: Row(children: [
            Container(width: 6, height: 14, decoration: BoxDecoration(color: Colors.teal, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            const Text('Recovered Components (returned to stock)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Expanded(child: Text(_sourceMode == 'voucher' ? 'From the production run, scaled to quantity, at actual consumed costs.' : 'Derived from the BOM, scaled to quantity. Locked to the recipe.', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
          ])),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: const [
            SizedBox(width: 26, child: Text('#', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            Expanded(child: Text('Product', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            SizedBox(width: 110, child: Text('Quantity', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            SizedBox(width: 120, child: Text('Value', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 30),
          ])),
        for (var i = 0; i < _components.length; i++)
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 26, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))),
              Expanded(child: Padding(padding: const EdgeInsets.only(top: 8), child: Text(_components[i].productLabel, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
              const SizedBox(width: 12),
              SizedBox(width: 110, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text(_trim(_components[i].qty), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)))),
              const SizedBox(width: 12),
              SizedBox(width: 120, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text(
                _isDraft ? _money(_components[i].qty * _unitCostFor(_components[i])) : _money(_components[i].lineCostSnap),
                textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)))),
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
