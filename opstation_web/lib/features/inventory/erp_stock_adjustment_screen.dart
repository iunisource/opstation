// lib/features/inventory/erp_stock_adjustment_screen.dart
//
// Stock Adjustment Voucher — modeled on the legacy UniSource screen.
//   • No branch selector: branch is inherited from the global header
//     (selectedBranchProvider), same as your other inventory screens.
//   • In Qty / Out Qty columns. Stored as a single signed `quantity`
//     (In => +, Out => -). The DB posting function/trigger handles the GL.
//   • Save = draft (is_locked false). Post = is_locked true => the
//     `adj_autopost` trigger posts Dr/Cr Inventory vs 5150 automatically.
//
// INTEGRATION POINTS (4) are marked with `// >>> WIRE:` — adjust the import
// paths / provider names / table names to match your codebase, then it drops in.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// >>> WIRE 1: point these at your actual providers.
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
  _AdjLine({
    required this.productId,
    required this.productName,
    this.uomId,
    this.uomName = '',
    this.inQty = 0,
    this.outQty = 0,
    this.note,
  });

  // Signed quantity persisted to stock_adjustment_voucher_items.quantity
  double get signedQty => inQty - outQty;
}

class _ErpStockAdjustmentScreenState
    extends ConsumerState<ErpStockAdjustmentScreen> {
  final SupabaseClient _supa = Supabase.instance.client;

  // header
  DateTime _date = DateTime.now();
  final TextEditingController _remarks = TextEditingController();
  String? _voucherId; // set after first save
  String? _voucherNumber;
  bool _isLocked = false;

  // lines
  final List<_AdjLine> _lines = [];

  // product picker
  List<Map<String, dynamic>> _products = [];
  String? _pickProductId;
  final TextEditingController _pickIn = TextEditingController();
  final TextEditingController _pickOut = TextEditingController();

  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // orgId may be null at initState; defer until the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadProducts());
  }

  @override
  void dispose() {
    _remarks.dispose();
    _pickIn.dispose();
    _pickOut.dispose();
    super.dispose();
  }

  String get _orgId => ref.read(currentUserProvider)!.orgId!;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  String get _userId => ref.read(currentUserProvider)!.id;

  Future<void> _loadProducts() async {
    try {
      // >>> WIRE 2: confirm your products table/columns + uom source.
      // Expecting products(id, name, uom_id, is_active, org_id).
      final rows = await _supa
          .from('products')
          .select('id, name, uom_id')
          .eq('org_id', _orgId)
          .eq('is_active', true)
          .order('name');
      _products = List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      if (mounted) _toast('Could not load products: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _addLine() {
    if (_pickProductId == null) {
      _toast('Pick a product first');
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
    final p = _products.firstWhere((e) => e['id'] == _pickProductId);
    setState(() {
      _lines.add(_AdjLine(
        productId: p['id'] as String,
        productName: (p['name'] ?? '') as String,
        uomId: p['uom_id'] as String?,
        uomName: (p['uom_id'] ?? '') as String, // >>> WIRE 2: map to a uom name if you have one
        inQty: inQ,
        outQty: outQ,
      ));
      _pickProductId = null;
      _pickIn.clear();
      _pickOut.clear();
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
      final id = _voucherId ??
          'sav_${DateTime.now().millisecondsSinceEpoch}';

      // >>> WIRE 3: replace with your voucher_sequences service if you have one.
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
            'quantity': l.signedQty, // In => +, Out => -
            'notes': l.note,
          }
      ]);

      setState(() {
        _voucherId = id;
        _voucherNumber = number;
      });

      if (lock) {
        // Flip is_locked false->true. The adj_autopost trigger posts the GL.
        await _supa
            .from('stock_adjustment_vouchers')
            .update({
              'is_locked': true,
              'locked_by': _userId,
              'locked_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', id);

        // Optional: surface what the trigger posted.
        final log = await _supa
            .from('inventory_posting_log')
            .select('status, message')
            .eq('doc_id', id)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();
        setState(() => _isLocked = true);
        _toast(log == null
            ? 'Posted'
            : '${log['status']}: ${log['message']}');
      } else {
        _toast('Saved draft $number');
      }
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // >>> WIRE 3: simple fallback numbering; swap for your voucher_sequences logic.
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
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
          Text('Stock Adjustment Voucher',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),

          // ── header row ──────────────────────────────────────────────
          Wrap(
            spacing: 24,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
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
                  backgroundColor: Color(0xFFDFF5E1),
                ),
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
                  child: DropdownButtonFormField<String>(
                    value: _pickProductId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Product', isDense: true),
                    items: [
                      for (final p in _products)
                        DropdownMenuItem(
                          value: p['id'] as String,
                          child: Text((p['name'] ?? '') as String,
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() => _pickProductId = v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _pickIn,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                    ],
                    decoration:
                        const InputDecoration(labelText: 'In Qty', isDense: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _pickOut,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                    ],
                    decoration: const InputDecoration(
                        labelText: 'Out Qty', isDense: true),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(onPressed: _addLine, child: const Text('Add')),
              ],
            ),
          const SizedBox(height: 16),

          // ── lines table ─────────────────────────────────────────────
          Table(
            border: TableBorder.all(color: Colors.black12),
            columnWidths: const {
              0: FixedColumnWidth(40),
              3: FixedColumnWidth(100),
              4: FixedColumnWidth(100),
              5: FixedColumnWidth(48),
            },
            children: [
              const TableRow(
                decoration: BoxDecoration(color: Color(0xFF111111)),
                children: [
                  _Th('#'),
                  _Th('Product'),
                  _Th('Unit'),
                  _Th('In Qty'),
                  _Th('Out Qty'),
                  _Th(''),
                ],
              ),
              for (var i = 0; i < _lines.length; i++)
                TableRow(children: [
                  _Td('${i + 1}'),
                  _Td(_lines[i].productName),
                  _Td(_lines[i].uomName),
                  _Td(_lines[i].inQty == 0 ? '' : '${_lines[i].inQty}'),
                  _Td(_lines[i].outQty == 0 ? '' : '${_lines[i].outQty}'),
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

  Future<void> _confirmPost() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Post adjustment?'),
        content: const Text(
            'Posting locks the voucher and writes the GL entry (Inventory vs 5150). This cannot be undone from here.'),
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
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600)),
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
                color: Colors.white, fontWeight: FontWeight.bold)),
      );
}

class _Td extends StatelessWidget {
  final String t;
  const _Td(this.t);
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(8), child: Text(t));
}
