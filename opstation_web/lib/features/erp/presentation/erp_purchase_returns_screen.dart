import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/layout/collapsible_list_pane.dart';
import '../../auth/auth_controller.dart';
import '../services/voucher_pdf.dart';
import '../services/voucher_meta.dart';

/// Purchase Return Notes (SRN) — open-ended return documents.
///
/// Acts like an SO for returns: pick a customer (or walk-in), then add ANY
/// products at ANY qty/price/discount. No stock movement at this stage —
/// that happens on the future "Sales Return Invoice" which consumes an SRN.
class ErpPurchaseReturnsScreen extends ConsumerStatefulWidget {
  const ErpPurchaseReturnsScreen({super.key});
  @override
  ConsumerState<ErpPurchaseReturnsScreen> createState() => _ErpPurchaseReturnsScreenState();
}

class _ErpPurchaseReturnsScreenState extends ConsumerState<ErpPurchaseReturnsScreen> {
  List<Map<String, dynamic>> _returns = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _uoms = [];
  List<Map<String, dynamic>> _suppliers = [];

  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _items = [];
  VoucherMeta _meta = VoucherMeta();

  bool _listLoading = true;
  bool _detailLoading = false;
  String _search = '';
  String _filter = 'all';
  int _addRowKey = 0;

  // inline add row state
  String? _addProductId;
  String? _addUomId;
  final _addQtyCtrl  = TextEditingController(text: '1');

  @override
  void initState() { super.initState(); _loadList(); _loadLookups(); }

  @override
  void dispose() {
    _addQtyCtrl.dispose();
    super.dispose();
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _canDelete {
    final role = ref.read(currentUserProvider)?.role;
    return role == WebUserRole.masterAdmin || role == WebUserRole.admin;
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _loadLookups() async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final p = await client.from('products')
          .select('id, name, sku, base_uom_id, cost_price')
          .eq('org_id', orgId).eq('is_active', true).order('name').limit(10000);
      final u = await client.from('uoms').select().eq('org_id', orgId).order('name');
      // Paginated customer fetch
      final List<Map<String, dynamic>> c = [];
      const pageSize = 1000;
      var offset = 0;
      while (true) {
        final page = await client.from('suppliers').select('id, name')
            .eq('org_id', orgId).eq('is_active', true).order('name')
            .range(offset, offset + pageSize - 1);
        c.addAll(List<Map<String, dynamic>>.from(page));
        if (page.length < pageSize) break;
        offset += pageSize;
      }
      setState(() {
        _products = List<Map<String, dynamic>>.from(p);
        _uoms = List<Map<String, dynamic>>.from(u);
        _suppliers = c;
      });
    } catch (e) {
      // ignore: avoid_print
      print('[PRN] loadLookups error: $e');
    }
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null) return;
    setState(() => _listLoading = true);
    try {
      var q = Supabase.instance.client.from('purchase_returns')
          .select('id, voucher_number, voucher_date, grand_total, status, supplier_id, suppliers(name)')
          .eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final returns = await q
          .order('voucher_date', ascending: false)
          .order('voucher_number', ascending: false)
          .limit(2000);
      setState(() {
        _returns = List<Map<String, dynamic>>.from(returns);
        _listLoading = false;
      });
    } catch (e) {
      // ignore: avoid_print
      print('[PRN] loadList error: $e');
      _showSnack('Failed to load list: $e');
      setState(() => _listLoading = false);
    }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final ret = await client.from('purchase_returns')
          .select('*, suppliers(*), branches(name)')
          .eq('id', id).single();
      final items = await client.from('purchase_return_items')
          .select('*, products(name, sku), uoms(abbreviation)')
          .eq('return_id', id);
      final meta = await VoucherMeta.fetch(
        orgId: _orgId ?? '',
        customerId: ret['supplier_id'] as String?,
        createdById: ret['created_by'] as String?,
      );
      setState(() {
        _detail = Map<String, dynamic>.from(ret);
        _items = List<Map<String, dynamic>>.from(items);
        _meta = meta;
        _detailLoading = false;
      });
    } catch (e) {
      // ignore: avoid_print
      print('[PRN] loadDetail error: $e');
      _showSnack('Failed to load detail: $e');
      setState(() => _detailLoading = false);
    }
  }

  Future<void> _logAudit(String id, String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': _orgId,
        'voucher_id': id, 'voucher_type': 'PRN',
        'action': action, 'details': details,
        'performed_by': ref.read(currentUserProvider)?.id,
      });
    } catch (_) {}
  }

  bool get _isLocked => _detail['is_locked'] as bool? ?? false;
  bool get _isDraft  => (_detail['status'] as String? ?? 'draft') == 'draft';
  bool get _canEdit  => !_isLocked;

  // ── Create new SRN (open-ended) ────────────────────────────────────────────
  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }

    // Pick customer (or walk-in)
    final picked = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (_) => _SupplierSelectDialog(suppliers: _suppliers),
    );
    if (picked == null) return;  // cancelled

    setState(() => _detailLoading = true);
    try {
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number',
          params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'PRN', 'p_year': year});
      final voucherNum = 'PRN-$year-${nextNum.toString().padLeft(4, '0')}';
      final retId = 'pr_${DateTime.now().millisecondsSinceEpoch}';
      final userId = ref.read(currentUserProvider)?.id;

      await Supabase.instance.client.from('purchase_returns').insert({
        'id': retId,
        'org_id': orgId,
        'branch_id': branchId,
        'voucher_number': voucherNum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'supplier_id': picked['id'],   // null for walk-in
        'subtotal': 0, 'discount_total': 0, 'grand_total': 0,
        'status': 'draft',
        'is_locked': false,
        'created_by': userId,
      });
      await _logAudit(retId, 'created', 'Voucher $voucherNum created');

      _showSnack('$voucherNum created — add items below');
      await _loadList();
      _loadDetail(retId);
    } catch (e) {
      setState(() => _detailLoading = false);
      _showSnack('Failed: $e');
    }
  }

  // ── Inline item add ────────────────────────────────────────────────────────
  Future<void> _addItem() async {
    if (_addProductId == null || _addUomId == null) { _showSnack('Select product and UOM'); return; }
    if (_items.any((i) => i['product_id'] == _addProductId)) {
      _showSnack('Already added — delete the existing row to change qty');
      return;
    }
    final qty = double.tryParse(_addQtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) { _showSnack('Qty must be > 0'); return; }

    final prod = _products.firstWhere((p) => p['id'] == _addProductId, orElse: () => {});
    final uom  = _uoms.firstWhere((u) => u['id'] == _addUomId, orElse: () => {});
    final itemId = 'pri_${DateTime.now().microsecondsSinceEpoch}';
    final cost = (prod['cost_price'] as num?)?.toDouble() ?? 0;
    final lineTotal = qty * cost;

    try {
      await Supabase.instance.client.from('purchase_return_items').insert({
        'id': itemId,
        'return_id': _detail['id'],
        'product_id': _addProductId,
        'uom_id': _addUomId,
        'quantity': qty,
        'unit_price': cost,
        'discount': 0,
        'line_total': lineTotal,
      });
      setState(() {
        _items.add({
          'id': itemId,
          'return_id': _detail['id'],
          'product_id': _addProductId,
          'uom_id': _addUomId,
          'quantity': qty,
          'unit_price': cost,
          'discount': 0,
          'line_total': lineTotal,
          'products': {'name': prod['name'], 'sku': prod['sku']},
          'uoms': {'abbreviation': uom['abbreviation']},
        });
        _addProductId = null; _addUomId = null;
        _addQtyCtrl.text = '1';
        _addRowKey++; // reset the searchable picker field
      });
      await _recalcTotals();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _deleteItem(String itemId) async {
    try {
      await Supabase.instance.client.from('purchase_return_items').delete().eq('id', itemId);
      setState(() => _items.removeWhere((i) => i['id'] == itemId));
      await _recalcTotals();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _recalcTotals() async {
    double subtotal = 0, discount = 0;
    for (final it in _items) {
      final qty   = (it['quantity'] as num?)?.toDouble() ?? 0;
      final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
      final disc  = (it['discount'] as num?)?.toDouble() ?? 0;
      subtotal += qty * price;
      discount += qty * price * (disc / 100);
    }
    final grand = subtotal - discount;
    try {
      await Supabase.instance.client.from('purchase_returns').update({
        'subtotal': subtotal, 'discount_total': discount, 'grand_total': grand,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      setState(() {
        _detail['subtotal'] = subtotal;
        _detail['discount_total'] = discount;
        _detail['grand_total'] = grand;
      });
      // Refresh the list-side total quickly without a full reload
      final idx = _returns.indexWhere((r) => r['id'] == _detail['id']);
      if (idx >= 0) setState(() => _returns[idx]['grand_total'] = grand);
    } catch (_) {}
  }

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('purchase_returns').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, newLocked ? 'locked' : 'unlocked', null);
      _showSnack(newLocked ? 'Locked' : 'Unlocked');
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _saveNote() async {
    if (_items.isEmpty) { _showSnack('Add at least one item before saving'); return; }
    try {
      await Supabase.instance.client.from('purchase_returns').update({
        'status': 'saved',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'saved', null);
      _showSnack('Saved');
      _loadDetail(_detail['id'] as String);
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _generateInvoice() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    if (_items.isEmpty) { _showSnack('No items to invoice'); return; }

    // Check if a PRI already exists for this PRN
    try {
      final existing = await Supabase.instance.client.from('purchase_return_vouchers')
          .select('id, voucher_number').eq('prn_id', _detail['id'] as String);
      if ((existing as List).isNotEmpty) {
        _showSnack('Invoice ${existing.first['voucher_number']} already exists — open it in Purchase Return Invoices');
        return;
      }
    } catch (_) {}

    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Generate Purchase Return Invoice?'),
      content: const Text('A draft invoice will be created. You can set prices and then Issue it to move stock.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Generate')),
      ],
    ));
    if (confirm != true) return;

    final prnId = _detail['id'] as String;
    final userId = ref.read(currentUserProvider)?.id;
    try {
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number',
          params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'PRI', 'p_year': year});
      final voucherNum = 'PRI-$year-${nextNum.toString().padLeft(4, '0')}';
      final invId = 'prv_${DateTime.now().millisecondsSinceEpoch}';

      await Supabase.instance.client.from('purchase_return_vouchers').insert({
        'id': invId,
        'org_id': orgId,
        'branch_id': branchId,
        'voucher_number': voucherNum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'prn_id': prnId,
        'supplier_id': _detail['supplier_id'],
        'subtotal': 0, 'discount_total': 0, 'grand_total': 0,
        'status': 'draft',
        'is_locked': false,
        'created_by': userId,
      });

      for (final si in _items) {
        final pid = si['product_id'] as String;
        await Supabase.instance.client.from('purchase_return_voucher_items').insert({
          'id': 'prvi_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'voucher_id': invId,
          'prn_item_id': si['id'],
          'product_id': pid,
          'uom_id': si['uom_id'],
          'quantity': si['quantity'],
          'unit_price': 0,
          'discount': 0,
          'line_total': 0,
        });
      }

      await _logAudit(prnId, 'invoiced', 'Draft invoice $voucherNum created');
      _showSnack('$voucherNum created as draft — set prices in Purchase Return Invoices tab');
      _loadDetail(prnId);
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _delete() async {
    if (!_canDelete) return;
    // Cascade check: no PRV should reference this PRN
    try {
      final vchs = await Supabase.instance.client.from('purchase_return_vouchers')
          .select('id, voucher_number').eq('prn_id', _detail['id']);
      if ((vchs as List).isNotEmpty) {
        _showSnack('Cannot delete: voucher ${vchs.first['voucher_number']} exists. Delete the voucher first.');
        return;
      }
    } catch (e) { _showSnack('Failed to check: $e'); return; }

    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete Purchase Return Note?'),
      content: Text('Permanently delete ${_detail['voucher_number']}? This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete')),
      ],
    ));
    if (confirm != true) return;
    try {
      final vNum = _detail['voucher_number'] as String? ?? '';
      await _logAudit(_detail['id'] as String, 'deleted', 'Voucher $vNum deleted by admin');
      await Supabase.instance.client.from('purchase_return_items').delete().eq('return_id', _detail['id']);
      await Supabase.instance.client.from('purchase_returns').delete().eq('id', _detail['id']);
      _showSnack('Deleted');
      setState(() { _selectedId = null; _detail = {}; _items = []; });
      await _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    // PRN is a qty-only note — prices/totals are set at the PRI stage.
    final lines = _items.map((it) => VoucherLine(
      product: it['products']?['name'] as String? ?? '-',
      sku: it['products']?['sku'] as String?,
      uom: it['uoms']?['abbreviation'] as String?,
      qty: (it['quantity'] as num?)?.toDouble() ?? 0,
      // unitPrice / lineTotal intentionally null → PDF hides price columns & totals
    )).toList();
    final date = _detail['voucher_date'] != null
        ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null;
    final createdAt = _detail['created_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal()) : null;
    final sup = _detail['suppliers'] as Map?;
    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Purchase Return Note',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: date,
      customerOrSupplier: sup?['name'] as String? ?? 'Cash Supplier',
      customerAddress: sup?['address'] as String?,
      customerContact: sup?['contact_person'] as String?,
      customerPhone: (sup?['contact_number'] ?? sup?['phone']) as String?,
      salespersonName: _meta.salespersonName,
      lines: lines,
      // No financial totals for PRN (qty-only note)
      preparedBy: _meta.preparedBy,
      createdAt: createdAt,
      footerNote: _meta.footerNote,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) {
      _selectedId = null; _detail = {}; _items = []; _loadList();
    });
    return Container(
      color: AppTheme.background,
      child: CollapsibleListPane(
        paneWidth: 360,
        listChild: _buildList(),
        detailChild: _selectedId == null
            ? const Center(child: Text('Select or create a Purchase Return Note',
                style: TextStyle(fontSize: 16, color: AppTheme.textSecondary)))
            : _buildDetail(),
      ),
    );
  }

  Widget _buildList() {
    final q = _search.toLowerCase().trim();
    final filtered = _returns.where((r) {
      final matchSearch = q.isEmpty ||
          (r['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
          ((r['suppliers']?['name'] as String?) ?? '').toLowerCase().contains(q);
      final st = r['status'] as String? ?? 'draft';
      final matchStatus = _filter == 'all' || st == _filter;
      return matchSearch && matchStatus;
    }).toList();
    return Container(
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppTheme.border))),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Row(children: [
            const Expanded(child: Text('Purchase Return Notes', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
            IconButton(
              icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 32),
              onPressed: _createNew,
              tooltip: 'New PRN',
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search PRN / supplier…',
              prefixIcon: Icon(Icons.search, size: 18),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            _PrnFilterTab(label: 'All', value: 'all', current: _filter, onTap: (v) => setState(() => _filter = v)),
            _PrnFilterTab(label: 'Draft', value: 'draft', current: _filter, onTap: (v) => setState(() => _filter = v)),
            _PrnFilterTab(label: 'Saved', value: 'saved', current: _filter, onTap: (v) => setState(() => _filter = v)),
            _PrnFilterTab(label: 'Invoiced', value: 'invoiced', current: _filter, onTap: (v) => setState(() => _filter = v)),
          ]),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _listLoading
              ? const Center(child: CircularProgressIndicator())
              : filtered.isEmpty
                  ? const Center(child: Text('No PRNs yet.', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final r = filtered[i];
                        final selected = r['id'] == _selectedId;
                        return ListTile(
                          dense: true,
                          selected: selected,
                          selectedTileColor: AppTheme.primary.withOpacity(0.06),
                          title: Text(r['voucher_number'] as String? ?? '-',
                              style: TextStyle(fontWeight: FontWeight.w700, color: selected ? AppTheme.primary : null)),
                          subtitle: Text(r['suppliers']?['name'] as String? ?? 'Cash Supplier',
                              style: const TextStyle(fontSize: 11)),
                          trailing: Text(
                            ((r['grand_total'] as num?)?.toStringAsFixed(2)) ?? '0',
                            style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primary),
                          ),
                          onTap: () => _loadDetail(r['id'] as String),
                        );
                      },
                    ),
        ),
      ]),
    );
  }

  Widget _buildDetail() {
    if (_detailLoading) return const Center(child: CircularProgressIndicator());
    final sup = _detail['suppliers'] as Map?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header
      Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_detail['voucher_number'] as String? ?? '-',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Text('Purchase Return Note',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, letterSpacing: 1.2)),
          ])),
          if (_isDraft && !_isLocked) ...[
            ElevatedButton.icon(
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Save'),
              onPressed: _saveNote,
            ),
            const SizedBox(width: 8),
          ],
          if (!_isDraft && (_detail['status'] as String? ?? '') == 'saved') ...[
            ElevatedButton.icon(
              icon: const Icon(Icons.description, size: 16),
              label: const Text('Generate Return Invoice'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
              onPressed: _generateInvoice,
            ),
            const SizedBox(width: 8),
          ],
          IconButton(
            icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline,
                color: _isLocked ? Colors.orange : AppTheme.textSecondary),
            tooltip: _isLocked ? 'Unlock' : 'Lock',
            onPressed: _toggleLock,
          ),
          IconButton(icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary), tooltip: 'Print / PDF', onPressed: _print),
          if (_canDelete)
            IconButton(icon: const Icon(Icons.delete_outline, color: AppTheme.danger), tooltip: 'Delete', onPressed: _delete),
        ]),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Supplier chip + dates
            Wrap(spacing: 12, runSpacing: 8, children: [
              _Chip(label: 'Supplier', value: sup?['name'] as String? ?? 'Cash Supplier'),
              _Chip(label: 'Date', value: _detail['voucher_date'] != null
                  ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-'),
              _Chip(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-'),
              _Chip(label: 'Status', value: (_detail['status'] as String? ?? 'draft')),
            ]),
            if (sup != null) _SupplierStrip(
              address: sup['address'] as String?,
              contact: sup['contact_person'] as String?,
              phone: (sup['contact_number'] ?? sup['phone']) as String?,
              preparedBy: _meta.preparedBy,
              createdAt: _detail['created_at'] != null
                  ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal())
                  : null,
            ),

            const SizedBox(height: 20),

            // Items table
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
                  child: const Row(children: [
                    Expanded(flex: 5, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                    SizedBox(width: 44),
                  ]),
                ),
                const Divider(height: 1),

                // Existing rows
                if (_items.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text('No items yet — add below.', style: TextStyle(color: AppTheme.textSecondary))),
                ..._items.map((it) {
                  final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(children: [
                      Expanded(flex: 5, child: Text(it['products']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 2, child: Text(it['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text(qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
                      SizedBox(width: 44, child: _canEdit
                          ? IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                              tooltip: 'Remove',
                              onPressed: () => _deleteItem(it['id'] as String),
                            )
                          : null),
                    ]),
                  );
                }),

                // Inline add row
                if (_canEdit) ...[
                  const Divider(height: 1),
                  Container(
                    color: AppTheme.background,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(children: [
                      Expanded(flex: 5, child: Autocomplete<Map<String, dynamic>>(
                        key: ValueKey('prn_prodpick_$_addRowKey'),
                        displayStringForOption: (p) => '${p['name']}${p['sku'] != null ? " · ${p['sku']}" : ""}',
                        optionsBuilder: (TextEditingValue tev) {
                          final query = tev.text.toLowerCase().trim();
                          if (query.isEmpty) return _products.take(50);
                          return _products.where((p) =>
                            (p['name'] as String? ?? '').toLowerCase().contains(query) ||
                            (p['sku'] as String? ?? '').toLowerCase().contains(query)).take(50);
                        },
                        onSelected: (p) => setState(() {
                          _addProductId = p['id'] as String?;
                          _addUomId = p['base_uom_id'] as String?;
                        }),
                        fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                          return TextField(
                            controller: controller,
                            focusNode: focusNode,
                            style: const TextStyle(fontSize: 12),
                            decoration: const InputDecoration(hintText: 'Search product…', prefixIcon: Icon(Icons.search, size: 16), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                            onSubmitted: (_) => onFieldSubmitted(),
                          );
                        },
                      )),
                      Expanded(flex: 2, child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: DropdownButtonFormField<String>(
                          value: _addUomId,
                          isDense: true,
                          isExpanded: true,
                          decoration: const InputDecoration(hintText: 'UOM', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
                          items: _uoms.map((u) => DropdownMenuItem<String>(
                            value: u['id'] as String,
                            child: Text(u['abbreviation'] as String? ?? '', style: const TextStyle(fontSize: 12)),
                          )).toList(),
                          onChanged: (v) => setState(() => _addUomId = v),
                        ),
                      )),
                      Expanded(flex: 2, child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: TextField(controller: _addQtyCtrl,
                            decoration: const InputDecoration(hintText: 'Qty', isDense: true),
                            textAlign: TextAlign.right,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _addItem()),
                      )),
                      SizedBox(width: 44, child: IconButton(
                        icon: const Icon(Icons.add_circle, color: AppTheme.primary),
                        tooltip: 'Add item',
                        onPressed: _addItem,
                      )),
                    ]),
                  ),
                ],
              ]),
            ),

            // Prices are set in the Purchase Return Invoice (PRI) — no totals at note stage.

            const SizedBox(height: 16),
            _AuditTrailWidget(voucherId: _selectedId ?? '', voucherType: 'PRN'),
          ]),
        ),
      ),
    ]);
  }

  Widget _totalRow(String label, double v, {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: TextStyle(color: color ?? AppTheme.textSecondary, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, fontSize: bold ? 14 : 12)),
        Text(v.toStringAsFixed(2), style: TextStyle(color: color ?? (bold ? AppTheme.primary : null), fontWeight: bold ? FontWeight.w700 : FontWeight.w600, fontSize: bold ? 15 : 13)),
      ]),
    );
  }
}

// ─── Supplier Select Dialog ───────────────────────────────────────────────────
class _SupplierSelectDialog extends StatefulWidget {
  final List<Map<String, dynamic>> suppliers;
  const _SupplierSelectDialog({required this.suppliers});
  @override
  State<_SupplierSelectDialog> createState() => _SupplierSelectDialogState();
}

class _SupplierSelectDialogState extends State<_SupplierSelectDialog> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase().trim();
    final filtered = widget.suppliers.where((c) {
      if (q.isEmpty) return true;
      return (c['name'] as String? ?? '').toLowerCase().contains(q) ||
             (c['code'] as String? ?? '').toLowerCase().contains(q);
    }).toList();
    return AlertDialog(
      title: Text('Select Supplier  ·  ${widget.suppliers.length} total'),
      content: SizedBox(width: 480, height: 460, child: Column(children: [
        TextField(
          decoration: const InputDecoration(hintText: 'Search name / code', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
          onChanged: (v) => setState(() => _q = v),
          autofocus: true,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No customers match.', style: TextStyle(color: AppTheme.textSecondary)))
              : ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final c = filtered[i];
                    return ListTile(
                      dense: true,
                      title: Text(c['name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: c['code'] != null ? Text(c['code'] as String, style: const TextStyle(fontSize: 11)) : null,
                      onTap: () => Navigator.pop(context, c),
                    );
                  },
                ),
        ),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel'))],
    );
  }
}

// ─── Supplier/Supplier Info Strip ────────────────────────────────────────────
class _SupplierStrip extends StatelessWidget {
  final String? address;
  final String? contact;
  final String? phone;
  final String? preparedBy;
  final String? createdAt;
  const _SupplierStrip({this.address, this.contact, this.phone, this.preparedBy, this.createdAt});
  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[];
    if (address != null && address!.trim().isNotEmpty) tiles.add(_tile(Icons.location_on_outlined, 'Address', address!));
    if (contact != null && contact!.isNotEmpty)        tiles.add(_tile(Icons.account_circle_outlined, 'Contact Person', contact!));
    if (phone != null && phone!.isNotEmpty)            tiles.add(_tile(Icons.phone_outlined, 'Phone', phone!));
    if (tiles.isEmpty && (preparedBy == null || preparedBy!.isEmpty)) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppTheme.background, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (tiles.isNotEmpty) Wrap(spacing: 24, runSpacing: 8, children: tiles),
        if (preparedBy != null && preparedBy!.isNotEmpty) ...[
          if (tiles.isNotEmpty) const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.draw_outlined, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text('Prepared by: ${preparedBy!}${createdAt != null ? "  ·  $createdAt" : ""}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontStyle: FontStyle.italic)),
          ]),
        ],
      ]),
    );
  }
  Widget _tile(IconData icon, String label, String value) {
    return ConstrainedBox(constraints: const BoxConstraints(maxWidth: 320),
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: 6),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, letterSpacing: 0.5)),
          Text(value, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
        ]),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String value;
  const _Chip({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
      ]),
    );
  }
}

class _PrnFilterTab extends StatelessWidget {
  final String label, value, current;
  final ValueChanged<String> onTap;
  const _PrnFilterTab({required this.label, required this.value, required this.current, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final active = value == current;
    return GestureDetector(
      onTap: () => onTap(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: active ? AppTheme.primary : AppTheme.background, borderRadius: BorderRadius.circular(12), border: Border.all(color: active ? AppTheme.primary : AppTheme.border)),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: active ? Colors.white : AppTheme.textSecondary)),
      ),
    );
  }
}

// ─── Audit Trail Widget (inline — mirrors PRI) ────────────────────────────────
class _AuditTrailWidget extends StatelessWidget {
  final String voucherId, voucherType;
  const _AuditTrailWidget({required this.voucherId, required this.voucherType});
  @override
  Widget build(BuildContext context) {
    if (voucherId.isEmpty) return const SizedBox.shrink();
    return FutureBuilder<List<dynamic>>(
      future: Supabase.instance.client.from('voucher_audit_log')
          .select('*, users(name)')
          .eq('voucher_id', voucherId).eq('voucher_type', voucherType)
          .order('created_at', ascending: false).limit(20),
      builder: (ctx, snap) {
        if (snap.hasError) return const SizedBox.shrink();
        if (!snap.hasData || (snap.data as List).isEmpty) return Padding(padding: const EdgeInsets.only(top: 4), child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Color(0xFFE5E7EB))), child: const Row(children: [Icon(Icons.history, size: 14, color: Color(0xFF9CA3AF)), SizedBox(width: 8), Text('No activity logged yet', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)))])));
        final entries = List<Map<String, dynamic>>.from(snap.data!);
        return Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Audit Trail', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary, letterSpacing: 0.6)),
            const SizedBox(height: 8),
            ...entries.map((e) {
              final action  = e['action'] as String? ?? '-';
              final details = e['details'] as String? ?? '';
              final by = e['users']?['name'] as String? ?? '—';
              final ts      = e['created_at'] != null
                  ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(e['created_at'] as String).toLocal()) : '';
              Color color;
              switch (action) {
                case 'created': case 'saved':   color = AppTheme.primary; break;
                case 'invoiced':                color = AppTheme.success; break;
                case 'locked':                  color = Colors.orange; break;
                case 'deleted': case 'cancelled': color = AppTheme.danger; break;
                default:                        color = AppTheme.textSecondary;
              }
              return Padding(padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.history, size: 14, color: color),
                  const SizedBox(width: 8),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(action, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: color)),
                      const SizedBox(width: 8),
                      Text('by $by', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      const Spacer(),
                      Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ]),
                    if (details.isNotEmpty) Text(details, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ])),
                ]));
            }),
          ]),
        );
      },
    );
  }
}
