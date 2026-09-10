// lib/features/inventory/erp_stock_adjustment_screen.dart
//
// Stock Adjustment Voucher — unified "correct to target" grid.
//   • One row per item: Cost + Quantity are auto-fetched (current state),
//     New Cost + New Quantity are the correction fields the user edits.
//   • Cost basis = weighted-avg of positive cost layers at this branch;
//     falls back to the product profile cost (products.cost_price) when the
//     item has no layers. Quantity = current on-hand at this branch.
//   • Amount = Cost × Qty, New Amount = New Cost × New Qty,
//     Difference = New Amount − Amount. Column totals + Total Difference show
//     the net inventory/GL impact of the voucher.
//   • On post, each row is translated to the existing posting engine:
//       – a QUANTITY line for (New Qty − Qty), valued at current cost, and
//       – a REVALUATION line to New Cost.
//     The two net to exactly the row Difference, so the GL impact equals the
//     Total Difference shown. Rows with no change are skipped.
//   • Save = draft (is_locked false). Post = lock + post_stock_adjustment_voucher.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/format/money.dart';
import '../../core/search/text_search.dart';
import '../../core/layout/main_layout.dart'; // exposes selectedBranchProvider
import '../auth/auth_controller.dart';        // exposes currentUserProvider (WebUser: id, orgId)

class ErpStockAdjustmentScreen extends ConsumerStatefulWidget {
  const ErpStockAdjustmentScreen({super.key});

  @override
  ConsumerState<ErpStockAdjustmentScreen> createState() =>
      _ErpStockAdjustmentScreenState();
}

String _fmtNum(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

class _CostQty {
  final double cost;
  final double onHand;
  const _CostQty(this.cost, this.onHand);
}

class _AdjLine {
  final String productId;
  final String productName;
  final String? uomId;
  final String uomName;
  final double baseCost; // current unit cost (layer avg, fallback cost_price)
  final double baseQty;  // current on-hand at this branch
  final TextEditingController newCostCtrl;
  final TextEditingController newQtyCtrl;
  String? note;

  _AdjLine({
    required this.productId,
    required this.productName,
    this.uomId,
    this.uomName = '',
    this.baseCost = 0,
    this.baseQty = 0,
    this.note,
    double? newCost,
    double? newQty,
  })  : newCostCtrl =
            TextEditingController(text: _fmtNum(newCost ?? baseCost)),
        newQtyCtrl =
            TextEditingController(text: _fmtNum(newQty ?? baseQty));

  double get newCost => double.tryParse(newCostCtrl.text.trim()) ?? baseCost;
  double get newQty => double.tryParse(newQtyCtrl.text.trim()) ?? baseQty;
  double get amount => baseCost * baseQty;
  double get newAmount => newCost * newQty;
  double get difference => newAmount - amount;

  bool get qtyChanged => (newQty - baseQty).abs() > 1e-6;
  bool get costChanged => (newCost - baseCost).abs() > 1e-6;
  bool get hasChange => qtyChanged || costChanged;

  void dispose() {
    newCostCtrl.dispose();
    newQtyCtrl.dispose();
  }
}

class _ErpStockAdjustmentScreenState
    extends ConsumerState<ErpStockAdjustmentScreen> {
  final SupabaseClient _supa = Supabase.instance.client;

  // header
  DateTime _date = DateTime.now();
  final TextEditingController _remarks = TextEditingController();
  String? _voucherId; // set after first save / on load
  String? _voucherNumber;
  String _status = 'draft';
  bool _isLocked = false;
  bool _isVoided = false;

  // lines
  final List<_AdjLine> _lines = [];

  // product picker
  List<Map<String, dynamic>> _products = [];
  Map<String, Map<String, dynamic>> _prodById = {};
  String? _pickProductId;
  TextEditingController? _pickProductCtrl; // bound by the Autocomplete field
  bool _addingLine = false;

  // saved-voucher list (side drawer)
  List<Map<String, dynamic>> _vouchers = [];
  bool _loadingList = true;
  String _listSearch = '';
  bool _drawerOpen = true;

  bool _loading = true; // products loading
  bool _saving = false;
  bool _openingVoucher = false;
  static const int _maxRenderRows = 400; // cap for huge bulk vouchers

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadProducts();
      _loadVouchers();
    });
  }

  @override
  void dispose() {
    _remarks.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  String get _orgId => ref.read(currentUserProvider)!.orgId!;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  String get _userId => ref.read(currentUserProvider)!.id;
  bool get _isDraft => !_isLocked && _status != 'posted';
  bool get _canVoid => _isLocked && !_isVoided;

  Future<void> _loadProducts() async {
    try {
      final rows = await _supa
          .from('products')
          .select('id, name, sku, base_uom_id, cost_price')
          .eq('org_id', _orgId)
          .eq('is_active', true)
          .order('name');
      _products = List<Map<String, dynamic>>.from(rows);
      _prodById = {for (final p in _products) p['id'] as String: p};
    } catch (e) {
      if (mounted) _toast('Could not load products: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadVouchers() async {
    if (mounted) setState(() => _loadingList = true);
    try {
      final rows = await _supa
          .from('stock_adjustment_vouchers')
          .select()
          .eq('org_id', _orgId)
          .order('created_at', ascending: false)
          .limit(300);
      if (mounted) {
        setState(() {
          _vouchers = List<Map<String, dynamic>>.from(rows);
          _loadingList = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  void _clearLines() {
    for (final l in _lines) {
      l.dispose();
    }
    _lines.clear();
  }

  void _newVoucher() {
    setState(() {
      _voucherId = null;
      _voucherNumber = null;
      _status = 'draft';
      _isLocked = false;
      _isVoided = false;
      _date = DateTime.now();
      _remarks.clear();
      _clearLines();
      _pickProductId = null;
      _pickProductCtrl?.clear();
    });
  }

  // Current unit cost (weighted-avg positive layers, fallback cost_price) and
  // on-hand for a product at the active branch.
  Future<_CostQty> _fetchCostAndQty(String productId) async {
    final branch = _branchId;
    double? layerCost;
    double onHand = 0;
    if (branch != null) {
      try {
        final layers = await _supa
            .from('inventory_cost_layers')
            .select('qty_remaining, unit_cost')
            .eq('org_id', _orgId)
            .eq('product_id', productId)
            .eq('branch_id', branch)
            .gt('qty_remaining', 0);
        double posQty = 0, valSum = 0;
        for (final l in (layers as List)) {
          final q = (l['qty_remaining'] as num?)?.toDouble() ?? 0;
          final c = (l['unit_cost'] as num?)?.toDouble() ?? 0;
          posQty += q;
          valSum += q * c;
        }
        if (posQty > 0) layerCost = valSum / posQty;

        final stk = await _supa
            .from('inventory_stock')
            .select('quantity')
            .eq('org_id', _orgId)
            .eq('product_id', productId)
            .eq('branch_id', branch);
        for (final s in (stk as List)) {
          onHand += (s['quantity'] as num?)?.toDouble() ?? 0;
        }
      } catch (_) {/* best-effort */}
    }
    // Fallback to the product profile cost when there is no positive layer.
    final profileCost =
        (_prodById[productId]?['cost_price'] as num?)?.toDouble() ?? 0;
    return _CostQty(layerCost ?? profileCost, onHand);
  }

  // Current cost + on-hand for MANY products at once (chunked to keep the URL
  // small). Returns one _CostQty per requested product id.
  Future<Map<String, _CostQty>> _fetchCostQtyBatch(List<String> pids) async {
    final result = <String, _CostQty>{};
    final branch = _branchId;
    final layerQty = <String, double>{};
    final layerVal = <String, double>{};
    final onHand = <String, double>{};
    if (branch != null && pids.isNotEmpty) {
      for (var i = 0; i < pids.length; i += 200) {
        final end = (i + 200) < pids.length ? (i + 200) : pids.length;
        final chunk = pids.sublist(i, end);
        try {
          final layers = await _supa
              .from('inventory_cost_layers')
              .select('product_id, qty_remaining, unit_cost')
              .eq('org_id', _orgId)
              .eq('branch_id', branch)
              .inFilter('product_id', chunk)
              .gt('qty_remaining', 0);
          for (final l in (layers as List)) {
            final pid = l['product_id'] as String;
            final q = (l['qty_remaining'] as num?)?.toDouble() ?? 0;
            final c = (l['unit_cost'] as num?)?.toDouble() ?? 0;
            layerQty[pid] = (layerQty[pid] ?? 0) + q;
            layerVal[pid] = (layerVal[pid] ?? 0) + q * c;
          }
          final stk = await _supa
              .from('inventory_stock')
              .select('product_id, quantity')
              .eq('org_id', _orgId)
              .eq('branch_id', branch)
              .inFilter('product_id', chunk);
          for (final s in (stk as List)) {
            final pid = s['product_id'] as String;
            onHand[pid] =
                (onHand[pid] ?? 0) + ((s['quantity'] as num?)?.toDouble() ?? 0);
          }
        } catch (_) {/* best-effort per chunk */}
      }
    }
    for (final pid in pids) {
      final lq = layerQty[pid] ?? 0;
      final cost = lq > 0
          ? (layerVal[pid]! / lq)
          : ((_prodById[pid]?['cost_price'] as num?)?.toDouble() ?? 0);
      result[pid] = _CostQty(cost, onHand[pid] ?? 0);
    }
    return result;
  }

  Future<void> _loadVoucher(Map<String, dynamic> v) async {
    if (_openingVoucher) return;
    setState(() => _openingVoucher = true);
    try {
      final items = await _supa
          .from('stock_adjustment_voucher_items')
          .select()
          .eq('voucher_id', v['id'] as String)
          .order('id');

      // Merge persisted (quantity / revaluation) items back into one row per
      // product: qty delta => New Qty, revaluation => New Cost.
      final byProduct = <String, Map<String, dynamic>>{};
      for (final r in (items as List)) {
        final pid = r['product_id'] as String?;
        if (pid == null) continue;
        final lt = (r['line_type'] as String?) ?? 'quantity';
        final m = byProduct.putIfAbsent(pid, () => {
              'uom_id': r['uom_id'],
              'qty_delta': 0.0,
              'new_cost': null,
              'note': r['notes'],
            });
        if (lt == 'revaluation') {
          m['new_cost'] = (r['new_unit_cost'] as num?)?.toDouble();
        } else {
          m['qty_delta'] =
              (m['qty_delta'] as double) + ((r['quantity'] as num?)?.toDouble() ?? 0);
        }
      }

      final locked = (v['is_locked'] == true) || (v['status'] == 'posted');
      // Batch the cost/on-hand lookup for ALL products in ONE pass (chunked),
      // instead of two queries per line — bulk vouchers have hundreds of items
      // and the per-line version made the voucher take forever to open.
      final costQty = await _fetchCostQtyBatch(byProduct.keys.toList());

      final newLines = <_AdjLine>[];
      for (final entry in byProduct.entries) {
        final pid = entry.key;
        final m = entry.value;
        final prod = _prodById[pid];
        final cq = costQty[pid] ?? const _CostQty(0, 0);
        final qtyDelta = m['qty_delta'] as double;
        // For a POSTED voucher the on-hand already reflects the adjustment, so
        // current = "New Quantity" and the pre value = current − delta. For a
        // DRAFT the adjustment hasn't applied yet, so current = "Quantity".
        final baseQty = locked ? cq.onHand - qtyDelta : cq.onHand;
        final newQty = locked ? cq.onHand : cq.onHand + qtyDelta;
        final newCost = (m['new_cost'] as double?) ?? cq.cost;
        newLines.add(_AdjLine(
          productId: pid,
          productName: (prod?['name'] ?? pid) as String,
          uomId: (m['uom_id'] ?? prod?['base_uom_id']) as String?,
          uomName: ((m['uom_id'] ?? prod?['base_uom_id']) ?? '') as String,
          baseCost: cq.cost,
          baseQty: baseQty,
          newCost: newCost,
          newQty: newQty,
          note: m['note'] as String?,
        ));
      }

      final ds = v['voucher_date'] as String?;
      if (mounted) {
        setState(() {
          _clearLines();
          _voucherId = v['id'] as String?;
          _voucherNumber = v['voucher_number'] as String?;
          _status = v['status'] as String? ?? 'draft';
          _isLocked = locked;
          _isVoided = v['is_voided'] == true;
          _date = ds != null
              ? (DateTime.tryParse(ds) ?? DateTime.now())
              : DateTime.now();
          _remarks.text = v['remarks'] as String? ?? '';
          _lines.addAll(newLines);
          _pickProductId = null;
          _pickProductCtrl?.clear();
        });
      }
    } catch (e) {
      _toast('Load failed: $e');
    } finally {
      if (mounted) setState(() => _openingVoucher = false);
    }
  }

  Future<void> _addLine() async {
    if (_pickProductId == null) {
      _toast('Pick a product first');
      return;
    }
    if (_branchId == null) {
      _toast('Select a branch in the header first');
      return;
    }
    if (_lines.any((l) => l.productId == _pickProductId)) {
      _toast('That item is already in the list');
      return;
    }
    final p = _prodById[_pickProductId!];
    if (p == null) return;
    setState(() => _addingLine = true);
    final cq = await _fetchCostAndQty(_pickProductId!);
    if (!mounted) return;
    setState(() {
      _lines.add(_AdjLine(
        productId: p['id'] as String,
        productName: (p['name'] ?? '') as String,
        uomId: p['base_uom_id'] as String?,
        uomName: (p['base_uom_id'] ?? '') as String,
        baseCost: cq.cost,
        baseQty: cq.onHand,
      ));
      _pickProductId = null;
      _pickProductCtrl?.clear();
      _addingLine = false;
    });
  }

  Future<void> _save({required bool lock}) async {
    if (_isLocked) {
      _toast('This voucher is already posted');
      return;
    }
    if (_lines.isEmpty) {
      _toast('Add at least one line');
      return;
    }
    if (_branchId == null) {
      _toast('Select a branch in the header first');
      return;
    }
    final changed = _lines.where((l) => l.hasChange).toList();
    if (changed.isEmpty) {
      _toast('Nothing to adjust — set a New Qty or New Cost that differs');
      return;
    }
    setState(() => _saving = true);
    try {
      final id = _voucherId ?? 'sav_${DateTime.now().millisecondsSinceEpoch}';
      final number = _voucherNumber ?? await _nextVoucherNumber();

      await _supa.from('stock_adjustment_vouchers').upsert({
        'id': id,
        'org_id': _orgId,
        'branch_id': _branchId,
        'voucher_number': number,
        'voucher_date': _dateStr(_date),
        'remarks': _remarks.text.trim().isEmpty ? null : _remarks.text.trim(),
        'status': 'draft',
        'is_locked': false,
        'created_by': _userId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      await _supa
          .from('stock_adjustment_voucher_items')
          .delete()
          .eq('voucher_id', id);

      // Translate each unified row to the posting engine's items. A row can
      // emit up to two items (quantity + revaluation); emit the quantity line
      // FIRST so the revaluation reprices the post-adjustment on-hand.
      final items = <Map<String, dynamic>>[];
      var seq = 0;
      for (final l in changed) {
        if (l.qtyChanged) {
          items.add({
            'id': 'savi_${id}_${seq++}',
            'voucher_id': id,
            'org_id': _orgId,
            'product_id': l.productId,
            'uom_id': l.uomId,
            'quantity': l.newQty - l.baseQty, // signed delta
            'line_type': 'quantity',
            'new_unit_cost': null,
            'notes': l.note,
          });
        }
        if (l.costChanged) {
          items.add({
            'id': 'savi_${id}_${seq++}',
            'voucher_id': id,
            'org_id': _orgId,
            'product_id': l.productId,
            'uom_id': l.uomId,
            'quantity': 0,
            'line_type': 'revaluation',
            'new_unit_cost': l.newCost,
            'notes': l.note,
          });
        }
      }
      await _supa.from('stock_adjustment_voucher_items').insert(items);

      setState(() {
        _voucherId = id;
        _voucherNumber = number;
        _status = lock ? 'posted' : 'draft';
      });

      if (lock) {
        await _supa.from('stock_adjustment_vouchers').update({
          'is_locked': true,
          'status': 'posted',
          'locked_by': _userId,
          'locked_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', id);

        try {
          final res = await _supa
              .rpc('post_stock_adjustment_voucher', params: {'p_id': id});
          setState(() => _isLocked = true);
          _toast(res?.toString() ?? 'Posted');
        } catch (e) {
          await _supa.from('stock_adjustment_vouchers').update({
            'is_locked': false,
            'status': 'draft',
            'locked_by': null,
            'locked_at': null,
          }).eq('id', id);
          setState(() {
            _isLocked = false;
            _status = 'draft';
          });
          rethrow;
        }
      } else {
        _toast('Saved draft $number');
      }
      await _loadVouchers();
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (_voucherId == null) return;
    if (_isLocked || _status == 'posted') {
      _toast(
          'Posted vouchers cannot be deleted — enter a new adjustment voucher with opposite corrections to reverse the effect');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete draft?'),
        content: const Text(
            'This draft adjustment voucher and its lines will be permanently deleted. (Drafts have not posted, so nothing in the GL is affected.)'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final id = _voucherId!;
      await _supa
          .from('stock_adjustment_voucher_items')
          .delete()
          .eq('voucher_id', id);
      await _supa.from('stock_adjustment_vouchers').delete().eq('id', id);
      _toast('Draft deleted');
      _newVoucher();
      await _loadVouchers();
    } catch (e) {
      _toast('Delete failed: $e');
    }
  }

  Future<void> _void() async {
    if (_voucherId == null || !_canVoid) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Void this posted adjustment?'),
        content: const Text(
            'Voiding reverses the GL entry and the cost layers, and restores on-hand to what it was before this voucher. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Void'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      final res = await _supa.rpc('void_stock_adjustment_voucher',
          params: {'p_id': _voucherId, 'p_user': _userId});
      _toast(res?.toString() ?? 'Voided');
      final updated = await _supa
          .from('stock_adjustment_vouchers')
          .select()
          .eq('id', _voucherId!)
          .single();
      await _loadVoucher(updated);
      await _loadVouchers();
    } catch (e) {
      _toast('Void failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String> _nextVoucherNumber() async {
    final rows = await _supa
        .from('stock_adjustment_vouchers')
        .select('voucher_number')
        .eq('org_id', _orgId);
    var max = 0;
    for (final r in rows) {
      final n = int.tryParse(
          (r['voucher_number'] ?? '').toString().replaceAll(RegExp(r'\D'), ''));
      if (n != null && n > max) max = n;
    }
    return (max + 1).toString();
  }

  String _dateStr(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF7F7F8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_drawerOpen) _buildDrawer(),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  // ── side drawer: saved vouchers ───────────────────────────────────
  Widget _buildDrawer() {
    final filtered = _vouchers.where((v) => matchesQuery(
        '${v['voucher_number'] ?? ''} ${v['remarks'] ?? ''}', _listSearch)).toList();

    return Container(
      width: 300,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFE0E0E0))),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFE0E0E0))),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Adjustment Vouchers',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text('New', style: TextStyle(fontSize: 11)),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                      ),
                      onPressed: _newVoucher,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search...',
                    prefixIcon: Icon(Icons.search, size: 15),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _listSearch = v),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loadingList
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : filtered.isEmpty
                    ? const Center(
                        child: Text('No vouchers yet',
                            style:
                                TextStyle(fontSize: 12, color: Colors.black54)))
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final v = filtered[i];
                          final sel = _voucherId == v['id'];
                          final voided = v['is_voided'] == true;
                          final posted = !voided &&
                              ((v['status'] as String? ?? 'draft') ==
                                      'posted' ||
                                  v['is_locked'] == true);
                          final badgeText = voided
                              ? 'Voided'
                              : (posted ? 'Posted' : 'Draft');
                          final badgeColor = voided
                              ? Colors.red
                              : (posted ? Colors.green : Colors.orange);
                          return InkWell(
                            onTap: () => _loadVoucher(v),
                            child: Container(
                              color: sel ? const Color(0x113366FF) : null,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                            v['voucher_number'] as String? ??
                                                '(draft)',
                                            style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: sel
                                                    ? const Color(0xFF3366FF)
                                                    : Colors.black87)),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: badgeColor.withOpacity(0.13),
                                          borderRadius:
                                              BorderRadius.circular(3),
                                        ),
                                        child: Text(badgeText,
                                            style: TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.w700,
                                                color: badgeColor)),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(v['remarks'] as String? ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: sel
                                              ? const Color(0xFF3366FF)
                                              : Colors.black54)),
                                  Text('${v['voucher_date'] ?? ''}',
                                      style: const TextStyle(
                                          fontSize: 10, color: Colors.black45)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  // ── main content ──────────────────────────────────────────────────
  Widget _buildContent() {
    if (_loading || _openingVoucher) {
      return const Center(child: CircularProgressIndicator());
    }
    final totalAmount = _lines.fold<double>(0, (s, l) => s + l.amount);
    final totalNewAmount = _lines.fold<double>(0, (s, l) => s + l.newAmount);
    final totalDiff = totalNewAmount - totalAmount;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── top bar ──────────────────────────────────────────────
          Row(
            children: [
              IconButton(
                icon: Icon(
                    _drawerOpen ? Icons.chevron_left : Icons.chevron_right,
                    size: 20),
                onPressed: () => setState(() => _drawerOpen = !_drawerOpen),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tooltip: _drawerOpen ? 'Hide list' : 'Show list',
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    _voucherNumber == null
                        ? 'Stock Adjustment Voucher'
                        : 'Adjustment $_voucherNumber',
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
              if (_isVoided)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Chip(
                      label: Text('VOIDED'),
                      backgroundColor: Color(0xFFFDE2E1)),
                ),
              if (_isDraft && _voucherId != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.red, size: 22),
                  tooltip: 'Delete draft',
                  onPressed: _delete,
                ),
            ],
          ),
          const SizedBox(height: 12),

          // ── header row ──────────────────────────────────────────────
          Wrap(
            spacing: 24,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              _field(
                'Branch',
                SizedBox(
                  width: 200,
                  child: Text(
                    (ref.watch(selectedBranchProvider)?['name'] as String?) ??
                        '—',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
              _field(
                'Voucher No.',
                SizedBox(
                  width: 140,
                  child: Text(_voucherNumber ?? '(auto)',
                      style: const TextStyle(fontSize: 16)),
                ),
              ),
              _field(
                'Voucher Date',
                OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(_dateStr(_date)),
                  onPressed: _isLocked
                      ? null
                      : () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _date,
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) setState(() => _date = picked);
                        },
                ),
              ),
              _field(
                'Remarks',
                SizedBox(
                  width: 360,
                  child: TextField(
                    controller: _remarks,
                    enabled: !_isLocked,
                    decoration: const InputDecoration(
                        hintText: 'Remarks', isDense: true),
                  ),
                ),
              ),
              if (_isLocked)
                const Chip(
                    label: Text('POSTED'),
                    backgroundColor: Color(0xFFDFF5E1)),
            ],
          ),
          const Divider(height: 32),

          // ── line entry: pick a product, Add ─────────────────────────
          if (!_isLocked)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Autocomplete<Map<String, dynamic>>(
                    displayStringForOption: (p) => (p['name'] ?? '') as String,
                    optionsBuilder: (TextEditingValue tev) {
                      final q = tev.text.trim().toLowerCase();
                      if (q.isEmpty) return _products;
                      return _products.where((p) =>
                          ((p['name'] ?? '') as String)
                              .toLowerCase()
                              .contains(q) ||
                          ((p['sku'] ?? '') as String)
                              .toLowerCase()
                              .contains(q));
                    },
                    onSelected: (p) =>
                        setState(() => _pickProductId = p['id'] as String),
                    fieldViewBuilder: (context, ctrl, focus, onSubmit) {
                      _pickProductCtrl = ctrl;
                      return TextField(
                        controller: ctrl,
                        focusNode: focus,
                        decoration: const InputDecoration(
                          labelText: 'Add item',
                          isDense: true,
                          hintText: 'Search name or SKU…',
                          prefixIcon: Icon(Icons.search, size: 18),
                        ),
                        onChanged: (_) {
                          if (_pickProductId != null) {
                            setState(() => _pickProductId = null);
                          }
                        },
                      );
                    },
                    optionsViewBuilder: (context, onSelected, options) {
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                                maxHeight: 320, maxWidth: 420),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: options.length,
                              itemBuilder: (_, i) {
                                final p = options.elementAt(i);
                                return ListTile(
                                  dense: true,
                                  title: Text((p['name'] ?? '') as String,
                                      style: const TextStyle(fontSize: 13)),
                                  subtitle:
                                      ((p['sku'] ?? '') as String).isEmpty
                                          ? null
                                          : Text(p['sku'] as String,
                                              style: const TextStyle(
                                                  fontSize: 11)),
                                  onTap: () => onSelected(p),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _addingLine ? null : _addLine,
                  child: _addingLine
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Add'),
                ),
              ],
            ),
          const SizedBox(height: 6),
          if (!_isLocked)
            const Text(
              'Cost and Quantity are the current values. Enter the corrected '
              'New Cost / New Quantity — the Difference is the value change that posts.',
              style: TextStyle(fontSize: 11.5, color: Colors.black54),
            ),
          const SizedBox(height: 16),

          // ── lines table ─────────────────────────────────────────────
          Table(
            border: TableBorder.all(color: Colors.black12),
            columnWidths: const {
              0: FixedColumnWidth(38),
              2: FixedColumnWidth(96),
              3: FixedColumnWidth(110),
              4: FixedColumnWidth(96),
              5: FixedColumnWidth(110),
              6: FixedColumnWidth(110),
              7: FixedColumnWidth(110),
              8: FixedColumnWidth(120),
              9: FixedColumnWidth(44),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              const TableRow(
                decoration: BoxDecoration(color: Color(0xFF111111)),
                children: [
                  _Th('#'),
                  _Th('Item'),
                  _Th('Cost'),
                  _Th('New Cost'),
                  _Th('Quantity'),
                  _Th('New Quantity'),
                  _Th('Amount'),
                  _Th('New Amount'),
                  _Th('Difference'),
                  _Th(''),
                ],
              ),
              for (var i = 0;
                  i < _lines.length && i < _maxRenderRows;
                  i++)
                _lineRow(i),
              if (_lines.length > _maxRenderRows)
                TableRow(
                  decoration: const BoxDecoration(color: Color(0xFFFFF6E5)),
                  children: [
                    const _Td(''),
                    _Td(
                        'Showing first $_maxRenderRows of ${_lines.length} items — totals below cover all items.'),
                    const _Td(''),
                    const _Td(''),
                    const _Td(''),
                    const _Td(''),
                    const _Td(''),
                    const _Td(''),
                    const _Td(''),
                    const _Td(''),
                  ],
                ),
              TableRow(
                decoration: const BoxDecoration(color: Color(0xFFF2F2F2)),
                children: [
                  const _Td(''),
                  const _Td('Total'),
                  const _Td(''),
                  const _Td(''),
                  const _Td(''),
                  const _Td(''),
                  _Td(money(totalAmount), bold: true, right: true),
                  _Td(money(totalNewAmount), bold: true, right: true),
                  _Td(money(totalDiff), bold: true, right: true),
                  const _Td(''),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── total difference callout ────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: totalDiff == 0
                  ? const Color(0xFFF2F2F2)
                  : (totalDiff > 0
                      ? const Color(0xFFE9F7EC)
                      : const Color(0xFFFDECEC)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Text('Total Difference',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(width: 16),
                Text((totalDiff >= 0 ? '+' : '') + money(totalDiff),
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: totalDiff > 0
                            ? const Color(0xFF1B7F3B)
                            : (totalDiff < 0
                                ? const Color(0xFFB3261E)
                                : Colors.black87))),
                const SizedBox(width: 12),
                Text(
                    totalDiff == 0
                        ? 'no net change'
                        : (totalDiff > 0
                            ? 'inventory value increase'
                            : 'inventory value decrease'),
                    style: const TextStyle(
                        fontSize: 12, color: Colors.black54)),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── actions ─────────────────────────────────────────────────
          if (!_isLocked)
            Row(children: [
              OutlinedButton(
                onPressed: _saving ? null : () => _save(lock: false),
                child: const Text('Save Draft'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _saving ? null : () => _confirmPost(),
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Post (lock)'),
              ),
            ]),
        ],
      ),
    );
  }

  TableRow _lineRow(int i) {
    final l = _lines[i];
    return TableRow(children: [
      _Td('${i + 1}'),
      _Td(l.productName),
      _Td(_fmtNum(l.baseCost), right: true),
      _isLocked
          ? _Td(_fmtNum(l.newCost), right: true)
          : _editCell(l.newCostCtrl),
      _Td(_fmtNum(l.baseQty), right: true),
      _isLocked
          ? _Td(_fmtNum(l.newQty), right: true)
          : _editCell(l.newQtyCtrl),
      _Td(money(l.amount), right: true),
      _Td(money(l.newAmount), right: true),
      _Td((l.difference >= 0 ? '+' : '') + money(l.difference),
          right: true,
          color: l.difference > 0
              ? const Color(0xFF1B7F3B)
              : (l.difference < 0 ? const Color(0xFFB3261E) : null)),
      _isLocked
          ? const _Td('')
          : IconButton(
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => setState(() {
                _lines[i].dispose();
                _lines.removeAt(i);
              }),
            ),
    ]);
  }

  Widget _editCell(TextEditingController ctrl) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: TextField(
          controller: ctrl,
          textAlign: TextAlign.right,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]'))
          ],
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            border: OutlineInputBorder(),
          ),
        ),
      );

  Future<void> _confirmPost() async {
    final changed = _lines.where((l) => l.hasChange).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Post adjustment?'),
        content: Text(
            'Posting locks the voucher and writes the GL entry for $changed '
            'corrected item${changed == 1 ? '' : 's'} (Inventory vs 5150). '
            'This cannot be undone from here.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Post')),
        ],
      ),
    );
    if (ok == true) _save(lock: true);
  }

  Widget _field(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          child,
        ],
      );
}

class _Th extends StatelessWidget {
  final String t;
  const _Th(this.t);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(8),
        child: Text(t,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
      );
}

class _Td extends StatelessWidget {
  final String t;
  final bool bold;
  final bool right;
  final Color? color;
  const _Td(this.t, {this.bold = false, this.right = false, this.color});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(8),
        child: Text(t,
            textAlign: right ? TextAlign.right : TextAlign.left,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                color: color)),
      );
}
