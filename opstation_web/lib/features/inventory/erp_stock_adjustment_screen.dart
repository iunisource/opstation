// lib/features/inventory/erp_stock_adjustment_screen.dart
//
// Stock Adjustment Voucher — modeled on the legacy UniSource screen.
//   • No branch selector: branch is inherited from the global header
//     (selectedBranchProvider), same as your other inventory screens.
//   • In Qty / Out Qty columns. Stored as a single signed `quantity`
//     (In => +, Out => -). The DB posting trigger handles the GL.
//   • Save = draft (is_locked false). Post = is_locked true => the DB
//     trigger posts the GL automatically.
//   • Side drawer lists all saved vouchers; click to load. New starts a
//     blank one. Drafts can be deleted; posted vouchers are locked
//     (reverse via Void once that path is wired to trg_void_on_flag).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/layout/main_layout.dart'; // exposes selectedBranchProvider
import '../auth/auth_controller.dart';        // exposes currentUserProvider (WebUser: id, orgId)

class ErpStockAdjustmentScreen extends ConsumerStatefulWidget {
  const ErpStockAdjustmentScreen({super.key});

  @override
  ConsumerState<ErpStockAdjustmentScreen> createState() =>
      _ErpStockAdjustmentScreenState();
}

class _AdjLine {
  final String productId;
  final String productName;
  final String? uomId;
  final String uomName;
  double inQty;
  double outQty;
  String? note;
  String lineType;      // 'quantity' | 'revaluation'
  double? newUnitCost;  // for revaluation lines
  _AdjLine({
    required this.productId,
    required this.productName,
    this.uomId,
    this.uomName = '',
    this.inQty = 0,
    this.outQty = 0,
    this.note,
    this.lineType = 'quantity',
    this.newUnitCost,
  });

  // Signed quantity persisted to stock_adjustment_voucher_items.quantity.
  // Revaluation lines carry 0 (quantity is not meaningful for them).
  double get signedQty => lineType == 'revaluation' ? 0 : (inQty - outQty);
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
  final TextEditingController _pickIn = TextEditingController();
  final TextEditingController _pickOut = TextEditingController();
  final TextEditingController _pickNewCost = TextEditingController();
  String _pickType = 'quantity';   // 'quantity' | 'revaluation'
  double? _pickCurCost;            // current unit cost of picked product (revalue mode)
  double? _pickOnHand;            // current on-hand qty of picked product
  bool _pickCostLoading = false;

  // saved-voucher list (side drawer)
  List<Map<String, dynamic>> _vouchers = [];
  bool _loadingList = true;
  String _listSearch = '';
  bool _drawerOpen = true;

  bool _loading = true; // products loading
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // orgId may be null at initState; defer until the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadProducts();
      _loadVouchers();
    });
  }

  @override
  void dispose() {
    _remarks.dispose();
    _pickIn.dispose();
    _pickOut.dispose();
    _pickNewCost.dispose();
    super.dispose();
  }

  String get _orgId => ref.read(currentUserProvider)!.orgId!;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  String get _userId => ref.read(currentUserProvider)!.id;
  bool get _isDraft => !_isLocked && _status != 'posted';
  bool get _canVoid => _isLocked && !_isVoided;

  Future<void> _loadProducts() async {
    try {
      // products(id, name, base_uom_id, is_active, org_id)
      final rows = await _supa
          .from('products')
          .select('id, name, sku, base_uom_id')
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

  void _newVoucher() {
    setState(() {
      _voucherId = null;
      _voucherNumber = null;
      _status = 'draft';
      _isLocked = false;
      _isVoided = false;
      _date = DateTime.now();
      _remarks.clear();
      _lines.clear();
      _pickProductId = null;
      _pickIn.clear();
      _pickOut.clear();
    });
  }

  Future<void> _loadVoucher(Map<String, dynamic> v) async {
    try {
      final items = await _supa
          .from('stock_adjustment_voucher_items')
          .select()
          .eq('voucher_id', v['id'] as String)
          .order('id');
      final newLines = <_AdjLine>[];
      for (final r in (items as List)) {
        final pid = r['product_id'] as String?;
        if (pid == null) continue;
        final prod = _prodById[pid];
        final qty = (r['quantity'] as num? ?? 0).toDouble();
        final lt = (r['line_type'] as String?) ?? 'quantity';
        newLines.add(_AdjLine(
          productId: pid,
          productName: (prod?['name'] ?? pid) as String,
          uomId: (r['uom_id'] ?? prod?['base_uom_id']) as String?,
          uomName: ((r['uom_id'] ?? prod?['base_uom_id']) ?? '') as String,
          inQty: qty > 0 ? qty : 0,
          outQty: qty < 0 ? -qty : 0,
          note: r['notes'] as String?,
          lineType: lt,
          newUnitCost: (r['new_unit_cost'] as num?)?.toDouble(),
        ));
      }
      final ds = v['voucher_date'] as String?;
      final locked = (v['is_locked'] == true) || (v['status'] == 'posted');
      if (mounted) {
        setState(() {
          _voucherId = v['id'] as String?;
          _voucherNumber = v['voucher_number'] as String?;
          _status = v['status'] as String? ?? 'draft';
          _isLocked = locked;
          _isVoided = v['is_voided'] == true;
          _date = ds != null ? (DateTime.tryParse(ds) ?? DateTime.now()) : DateTime.now();
          _remarks.text = v['remarks'] as String? ?? '';
          _lines
            ..clear()
            ..addAll(newLines);
          _pickProductId = null;
          _pickIn.clear();
          _pickOut.clear();
        });
      }
    } catch (e) {
      _toast('Load failed: $e');
    }
  }

  // Fetch current unit cost + on-hand for the picked product (revalue preview).
  Future<void> _loadPickCost(String productId) async {
    setState(() { _pickCostLoading = true; _pickCurCost = null; _pickOnHand = null; });
    try {
      // on-hand from positive cost layers
      final layers = await _supa
          .from('inventory_cost_layers')
          .select('qty_remaining, unit_cost')
          .eq('org_id', _orgId)
          .eq('product_id', productId)
          .gt('qty_remaining', 0);
      double onHand = 0, valSum = 0;
      for (final l in (layers as List)) {
        final q = (l['qty_remaining'] as num?)?.toDouble() ?? 0;
        final c = (l['unit_cost'] as num?)?.toDouble() ?? 0;
        onHand += q; valSum += q * c;
      }
      final curCost = onHand > 0 ? valSum / onHand : null;
      if (!mounted) return;
      setState(() { _pickOnHand = onHand; _pickCurCost = curCost; _pickCostLoading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() { _pickCostLoading = false; });
    }
  }


  void _addLine() {
    if (_pickProductId == null) {
      _toast('Pick a product first');
      return;
    }
    final p = _products.firstWhere((e) => e['id'] == _pickProductId);
    if (_pickType == 'revaluation') {
      final nc = double.tryParse(_pickNewCost.text.trim()) ?? 0;
      if (nc <= 0) {
        _toast('Enter the new unit cost (greater than 0)');
        return;
      }
      setState(() {
        _lines.add(_AdjLine(
          productId: p['id'] as String,
          productName: (p['name'] ?? '') as String,
          uomId: p['base_uom_id'] as String?,
          uomName: (p['base_uom_id'] ?? '') as String,
          lineType: 'revaluation',
          newUnitCost: nc,
        ));
        _pickProductId = null;
        _pickProductCtrl?.clear();
        _pickIn.clear();
        _pickOut.clear();
        _pickNewCost.clear();
      });
      return;
    }
    final inQ = double.tryParse(_pickIn.text.trim()) ?? 0;
    final outQ = double.tryParse(_pickOut.text.trim()) ?? 0;
    if (inQ == 0 && outQ == 0) {
      _toast('Enter an In or Out quantity');
      return;
    }
    if (inQ > 0 && outQ > 0) {
      _toast('A line is either In or Out, not both');
      return;
    }
    setState(() {
      _lines.add(_AdjLine(
        productId: p['id'] as String,
        productName: (p['name'] ?? '') as String,
        uomId: p['base_uom_id'] as String?,
        uomName: (p['base_uom_id'] ?? '') as String,
        inQty: inQ,
        outQty: outQ,
      ));
      _pickProductId = null;
      _pickProductCtrl?.clear();
      _pickIn.clear();
      _pickOut.clear();
      _pickNewCost.clear();
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
    setState(() => _saving = true);
    try {
      final id = _voucherId ?? 'sav_${DateTime.now().millisecondsSinceEpoch}';
      final number = _voucherNumber ?? await _nextVoucherNumber();

      // upsert header
      await _supa.from('stock_adjustment_vouchers').upsert({
        'id': id,
        'org_id': _orgId,
        'branch_id': _branchId,
        'voucher_number': number,
        'voucher_date': _dateStr(_date),
        'remarks': _remarks.text.trim().isEmpty ? null : _remarks.text.trim(),
        'status': lock ? 'posted' : 'draft',
        'is_locked': false, // flip separately below so the trigger fires on the transition
        'created_by': _userId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      // replace lines
      await _supa
          .from('stock_adjustment_voucher_items')
          .delete()
          .eq('voucher_id', id);
      await _supa.from('stock_adjustment_voucher_items').insert([
        for (final l in _lines)
          {
            'id': 'savi_${DateTime.now().microsecondsSinceEpoch}_${l.productId}',
            'voucher_id': id,
            'org_id': _orgId,
            'product_id': l.productId,
            'uom_id': l.uomId,
            'quantity': l.signedQty, // In => +, Out => -; revaluation => 0
            'line_type': l.lineType,
            'new_unit_cost': l.lineType == 'revaluation' ? l.newUnitCost : null,
            'notes': l.note,
          }
      ]);

      setState(() {
        _voucherId = id;
        _voucherNumber = number;
        _status = lock ? 'posted' : 'draft';
      });

      if (lock) {
        // Flip is_locked false->true. The DB trigger posts the GL.
        await _supa.from('stock_adjustment_vouchers').update({
          'is_locked': true,
          'locked_by': _userId,
          'locked_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', id);

        // The lock flip alone does NOT post — there is no trigger that calls the
        // poster (the only trigger fires on is_voided). So invoke the poster
        // explicitly, the same way the other voucher screens do.
        final res = await _supa
            .rpc('post_stock_adjustment_voucher', params: {'p_id': id});
        setState(() => _isLocked = true);
        _toast(res?.toString() ?? 'Posted');
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
      _toast('Posted vouchers cannot be deleted — reverse via Void');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete draft?'),
        content: const Text(
            'This draft adjustment voucher and its lines will be permanently deleted. (Drafts have not posted, so nothing in the GL is affected.)'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
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
      await _supa.from('stock_adjustment_voucher_items').delete().eq('voucher_id', id);
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
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
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

  // simple fallback numbering
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
    final filtered = _listSearch.isEmpty
        ? _vouchers
        : _vouchers.where((v) {
            final q = _listSearch.toLowerCase();
            return (v['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
                (v['remarks'] as String? ?? '').toLowerCase().contains(q);
          }).toList();

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
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text('New', style: TextStyle(fontSize: 11)),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                            style: TextStyle(fontSize: 12, color: Colors.black54)))
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final v = filtered[i];
                          final sel = _voucherId == v['id'];
                          final voided = v['is_voided'] == true;
                          final posted = !voided &&
                              ((v['status'] as String? ?? 'draft') == 'posted' ||
                                  v['is_locked'] == true);
                          final badgeText = voided ? 'Voided' : (posted ? 'Posted' : 'Draft');
                          final badgeColor = voided
                              ? Colors.red
                              : (posted ? Colors.green : Colors.orange);
                          return InkWell(
                            onTap: () => _loadVoucher(v),
                            child: Container(
                              color: sel ? const Color(0x113366FF) : null,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(v['voucher_number'] as String? ?? '(draft)',
                                            style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: sel ? const Color(0xFF3366FF) : Colors.black87)),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: badgeColor.withOpacity(0.13),
                                          borderRadius: BorderRadius.circular(3),
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
                                          color: sel ? const Color(0xFF3366FF) : Colors.black54)),
                                  Text('${v['voucher_date'] ?? ''}',
                                      style: const TextStyle(fontSize: 10, color: Colors.black45)),
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final totalIn = _lines.fold<double>(0, (s, l) => s + l.inQty);
    final totalOut = _lines.fold<double>(0, (s, l) => s + l.outQty);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── top bar ──────────────────────────────────────────────
          Row(
            children: [
              IconButton(
                icon: Icon(_drawerOpen ? Icons.chevron_left : Icons.chevron_right, size: 20),
                onPressed: () => setState(() => _drawerOpen = !_drawerOpen),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tooltip: _drawerOpen ? 'Hide list' : 'Show list',
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_voucherNumber == null ? 'Stock Adjustment Voucher' : 'Adjustment $_voucherNumber',
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
              if (_isVoided)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Chip(label: Text('VOIDED'), backgroundColor: Color(0xFFFDE2E1)),
                ),
              if (_canVoid)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.undo, size: 16, color: Colors.red),
                    label: const Text('Void', style: TextStyle(color: Colors.red)),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
                    onPressed: _saving ? null : _void,
                  ),
                ),
              if (_isDraft && _voucherId != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red, size: 22),
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
                    (ref.watch(selectedBranchProvider)?['name'] as String?) ?? '—',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
              _field(
                'Voucher No.',
                SizedBox(
                  width: 140,
                  child: Text(_voucherNumber ?? '(auto)', style: const TextStyle(fontSize: 16)),
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
                    decoration: const InputDecoration(hintText: 'Remarks', isDense: true),
                  ),
                ),
              ),
              if (_isLocked)
                const Chip(label: Text('POSTED'), backgroundColor: Color(0xFFDFF5E1)),
            ],
          ),
          const Divider(height: 32),

          // ── line entry ──────────────────────────────────────────────
          if (!_isLocked)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  flex: 4,
                  child: Autocomplete<Map<String, dynamic>>(
                    displayStringForOption: (p) => (p['name'] ?? '') as String,
                    optionsBuilder: (TextEditingValue tev) {
                      final q = tev.text.trim().toLowerCase();
                      if (q.isEmpty) return _products;
                      return _products.where((p) =>
                          ((p['name'] ?? '') as String).toLowerCase().contains(q) ||
                          ((p['sku'] ?? '') as String).toLowerCase().contains(q));
                    },
                    onSelected: (p) {
                      setState(() => _pickProductId = p['id'] as String);
                      if (_pickType == 'revaluation') _loadPickCost(p['id'] as String);
                    },
                    fieldViewBuilder: (context, ctrl, focus, onSubmit) {
                      _pickProductCtrl = ctrl;
                      return TextField(
                        controller: ctrl,
                        focusNode: focus,
                        decoration: const InputDecoration(
                          labelText: 'Product', isDense: true,
                          hintText: 'Search name or SKU…',
                          prefixIcon: Icon(Icons.search, size: 18),
                        ),
                        onChanged: (_) { if (_pickProductId != null) setState(() => _pickProductId = null); },
                      );
                    },
                    optionsViewBuilder: (context, onSelected, options) {
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 320, maxWidth: 420),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: options.length,
                              itemBuilder: (_, i) {
                                final p = options.elementAt(i);
                                return ListTile(
                                  dense: true,
                                  title: Text((p['name'] ?? '') as String, style: const TextStyle(fontSize: 13)),
                                  subtitle: ((p['sku'] ?? '') as String).isEmpty ? null : Text(p['sku'] as String, style: const TextStyle(fontSize: 11)),
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
                SizedBox(
                  width: 130,
                  child: DropdownButtonFormField<String>(
                    value: _pickType,
                    isDense: true,
                    decoration: const InputDecoration(labelText: 'Type', isDense: true),
                    items: const [
                      DropdownMenuItem(value: 'quantity', child: Text('Adjust Qty')),
                      DropdownMenuItem(value: 'revaluation', child: Text('Revalue')),
                    ],
                    onChanged: (v) => setState(() {
                      _pickType = v ?? 'quantity';
                      _pickIn.clear(); _pickOut.clear(); _pickNewCost.clear();
                      _pickCurCost = null; _pickOnHand = null;
                      if (_pickType == 'revaluation' && _pickProductId != null) {
                        _loadPickCost(_pickProductId!);
                      }
                    }),
                  ),
                ),
                const SizedBox(width: 12),
                if (_pickType == 'revaluation')
                  Expanded(
                    child: TextField(
                      controller: _pickNewCost,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'New Unit Cost', isDense: true,
                        hintText: 'Correct cost/unit'),
                    ),
                  )
                else ...[
                  Expanded(
                    child: TextField(
                      controller: _pickIn,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: const InputDecoration(labelText: 'In Qty', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _pickOut,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: const InputDecoration(labelText: 'Out Qty', isDense: true),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                FilledButton(onPressed: _addLine, child: const Text('Add')),
              ],
            ),
          // Revaluation preview: current cost/on-hand + resulting value delta.
          if (!_isLocked && _pickType == 'revaluation' && _pickProductId != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Builder(builder: (_) {
                if (_pickCostLoading) {
                  return const Text('Loading current cost…', style: TextStyle(fontSize: 12, color: Colors.black54));
                }
                final onHand = _pickOnHand ?? 0;
                if (onHand <= 0) {
                  return const Text('No on-hand stock for this product — nothing to revalue. Use a recount/quantity adjustment instead.',
                      style: TextStyle(fontSize: 12, color: Colors.orange));
                }
                final cur = _pickCurCost ?? 0;
                final nc = double.tryParse(_pickNewCost.text.trim()) ?? 0;
                final delta = (nc - cur) * onHand;
                final deltaStr = (delta >= 0 ? '+' : '') + delta.toStringAsFixed(2);
                final onHandStr = onHand.toStringAsFixed(onHand % 1 == 0 ? 0 : 2);
                final curValStr = (cur * onHand).toStringAsFixed(2);
                final newValStr = (nc * onHand).toStringAsFixed(2);
                final tail = nc > 0
                    ? '   \u2192   New value: $newValStr   (GL impact $deltaStr)'
                    : '';
                final line1 = 'On hand: $onHandStr   \u2022   Current cost: ${cur.toStringAsFixed(2)}   \u2022   Current value: $curValStr';
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: const Color(0xFFF2F6FF), borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    line1 + tail,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1A3D7C)),
                  ),
                );
              }),
            ),
          const SizedBox(height: 16),

          // ── lines table ─────────────────────────────────────────────
          Table(
            border: TableBorder.all(color: Colors.black12),
            columnWidths: const {
              0: FixedColumnWidth(40),
              3: FixedColumnWidth(90),
              4: FixedColumnWidth(100),
              5: FixedColumnWidth(100),
              6: FixedColumnWidth(48),
            },
            children: [
              const TableRow(
                decoration: BoxDecoration(color: Color(0xFF111111)),
                children: [
                  _Th('#'),
                  _Th('Product'),
                  _Th('Unit'),
                  _Th('Type'),
                  _Th('In Qty'),
                  _Th('Out Qty / New Cost'),
                  _Th(''),
                ],
              ),
              for (var i = 0; i < _lines.length; i++)
                TableRow(children: [
                  _Td('${i + 1}'),
                  _Td(_lines[i].productName),
                  _Td(_lines[i].uomName),
                  _Td(_lines[i].lineType == 'revaluation' ? 'Revalue' : 'Qty'),
                  _Td(_lines[i].lineType == 'revaluation'
                      ? '—'
                      : (_lines[i].inQty == 0 ? '' : '${_lines[i].inQty}')),
                  _Td(_lines[i].lineType == 'revaluation'
                      ? '@ ${_lines[i].newUnitCost?.toStringAsFixed(2) ?? '-'}'
                      : (_lines[i].outQty == 0 ? '' : '${_lines[i].outQty}')),
                  _isLocked
                      ? const _Td('')
                      : IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => setState(() => _lines.removeAt(i)),
                        ),
                ]),
              TableRow(
                decoration: const BoxDecoration(color: Color(0xFFF2F2F2)),
                children: [
                  const _Td(''),
                  const _Td('Total'),
                  const _Td(''),
                  const _Td(''),
                  _Td('$totalIn'),
                  _Td('$totalOut'),
                  const _Td(''),
                ],
              ),
            ],
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
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Post (lock)'),
              ),
            ]),
        ],
      ),
    );
  }

  Future<void> _confirmPost() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Post adjustment?'),
        content: const Text(
            'Posting locks the voucher and writes the GL entry (Inventory vs 5150). This cannot be undone from here.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Post')),
        ],
      ),
    );
    if (ok == true) _save(lock: true);
  }

  Widget _field(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
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
        child: Text(t, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      );
}

class _Td extends StatelessWidget {
  final String t;
  const _Td(this.t);
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(8), child: Text(t));
}
