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

/// Sales Return Notes (SRN) — open-ended return documents.
///
/// Acts like an SO for returns: pick a customer (or walk-in), then add ANY
/// products at ANY qty/price/discount. No stock movement at this stage —
/// that happens on the future "Sales Return Invoice" which consumes an SRN.
class ErpSalesReturnsScreen extends ConsumerStatefulWidget {
  const ErpSalesReturnsScreen({super.key});
  @override
  ConsumerState<ErpSalesReturnsScreen> createState() => _ErpSalesReturnsScreenState();
}

class _ErpSalesReturnsScreenState extends ConsumerState<ErpSalesReturnsScreen> {
  List<Map<String, dynamic>> _returns = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _uoms = [];
  List<Map<String, dynamic>> _customers = [];

  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _items = [];
  VoucherMeta _meta = VoucherMeta();

  bool _listLoading = true;
  bool _detailLoading = false;
  String _search = '';

  // inline add row state
  String? _addProductId;
  String? _addUomId;
  final _addQtyCtrl  = TextEditingController(text: '1');
  final _addPriceCtrl = TextEditingController(text: '0');
  final _addDiscCtrl = TextEditingController(text: '0');

  @override
  void initState() { super.initState(); _loadList(); _loadLookups(); }

  @override
  void dispose() {
    _addQtyCtrl.dispose();
    _addPriceCtrl.dispose();
    _addDiscCtrl.dispose();
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
          .select('id, name, sku, base_uom_id, selling_price')
          .eq('org_id', orgId).eq('is_active', true).order('name').limit(10000);
      final u = await client.from('uoms').select().eq('org_id', orgId).order('name');
      // Paginated customer fetch
      final List<Map<String, dynamic>> c = [];
      const pageSize = 1000;
      var offset = 0;
      while (true) {
        final page = await client.from('customers').select('id, shop_name, code')
            .eq('org_id', orgId).eq('is_active', true).order('shop_name')
            .range(offset, offset + pageSize - 1);
        c.addAll(List<Map<String, dynamic>>.from(page));
        if (page.length < pageSize) break;
        offset += pageSize;
      }
      setState(() {
        _products = List<Map<String, dynamic>>.from(p);
        _uoms = List<Map<String, dynamic>>.from(u);
        _customers = c;
      });
    } catch (e) {
      // ignore: avoid_print
      print('[SRN] loadLookups error: $e');
    }
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null) return;
    setState(() => _listLoading = true);
    try {
      var q = Supabase.instance.client.from('sales_returns')
          .select('id, voucher_number, voucher_date, grand_total, status, customer_id, customers(shop_name, code)')
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
      print('[SRN] loadList error: $e');
      _showSnack('Failed to load list: $e');
      setState(() => _listLoading = false);
    }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final ret = await client.from('sales_returns')
          .select('*, customers(shop_name, code, address, contact_person, phone), branches(name)')
          .eq('id', id).single();
      final items = await client.from('sales_return_items')
          .select('*, products(name, sku), uoms(abbreviation)')
          .eq('return_id', id);
      final meta = await VoucherMeta.fetch(
        orgId: _orgId ?? '',
        customerId: ret['customer_id'] as String?,
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
      print('[SRN] loadDetail error: $e');
      _showSnack('Failed to load detail: $e');
      setState(() => _detailLoading = false);
    }
  }

  Future<void> _logAudit(String id, String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': _orgId,
        'voucher_id': id, 'voucher_type': 'SRN',
        'action': action, 'details': details,
        'user_id': ref.read(currentUserProvider)?.id,
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
      builder: (_) => _CustomerSelectDialog(customers: _customers),
    );
    if (picked == null) return;  // cancelled

    setState(() => _detailLoading = true);
    try {
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number',
          params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'SRN', 'p_year': year});
      final voucherNum = 'SRN-$year-${nextNum.toString().padLeft(4, '0')}';
      final retId = 'sr_${DateTime.now().millisecondsSinceEpoch}';
      final userId = ref.read(currentUserProvider)?.id;

      await Supabase.instance.client.from('sales_returns').insert({
        'id': retId,
        'org_id': orgId,
        'branch_id': branchId,
        'voucher_number': voucherNum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'customer_id': picked['id'],   // null for walk-in
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
    final qty   = double.tryParse(_addQtyCtrl.text.trim()) ?? 0;
    final price = double.tryParse(_addPriceCtrl.text.trim()) ?? 0;
    final disc  = (double.tryParse(_addDiscCtrl.text.trim()) ?? 0).clamp(0.0, 100.0);
    if (qty <= 0) { _showSnack('Qty must be > 0'); return; }

    final prod = _products.firstWhere((p) => p['id'] == _addProductId, orElse: () => {});
    final uom  = _uoms.firstWhere((u) => u['id'] == _addUomId, orElse: () => {});
    final lineTotal = (qty * price) * (1 - disc / 100);
    final itemId = 'sri_${DateTime.now().microsecondsSinceEpoch}';

    try {
      await Supabase.instance.client.from('sales_return_items').insert({
        'id': itemId,
        'return_id': _detail['id'],
        'product_id': _addProductId,
        'uom_id': _addUomId,
        'quantity': qty,
        'unit_price': price,
        'discount': disc,
        'line_total': lineTotal,
      });
      // Optimistic append
      setState(() {
        _items.add({
          'id': itemId,
          'return_id': _detail['id'],
          'product_id': _addProductId,
          'uom_id': _addUomId,
          'quantity': qty,
          'unit_price': price,
          'discount': disc,
          'line_total': lineTotal,
          'products': {'name': prod['name'], 'sku': prod['sku']},
          'uoms': {'abbreviation': uom['abbreviation']},
        });
        _addProductId = null; _addUomId = null;
        _addQtyCtrl.text = '1'; _addPriceCtrl.text = '0'; _addDiscCtrl.text = '0';
      });
      await _recalcTotals();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _deleteItem(String itemId) async {
    try {
      await Supabase.instance.client.from('sales_return_items').delete().eq('id', itemId);
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
      await Supabase.instance.client.from('sales_returns').update({
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
      await Supabase.instance.client.from('sales_returns').update({
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
      await Supabase.instance.client.from('sales_returns').update({
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

    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Generate Sales Return Invoice?'),
      content: const Text('This will create a Sales Return Invoice (SRI), add stock back to inventory, and lock this SRN. Continue?'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Generate')),
      ],
    ));
    if (confirm != true) return;

    final srnId = _detail['id'] as String;
    final userId = ref.read(currentUserProvider)?.id;
    try {
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number',
          params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'SRI', 'p_year': year});
      final voucherNum = 'SRI-$year-${nextNum.toString().padLeft(4, '0')}';
      final invId = 'sri_${DateTime.now().millisecondsSinceEpoch}';

      await Supabase.instance.client.from('sales_return_invoices').insert({
        'id': invId,
        'org_id': orgId,
        'branch_id': branchId,
        'voucher_number': voucherNum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'srn_id': srnId,
        'customer_id': _detail['customer_id'],
        'subtotal': _detail['subtotal'] ?? 0,
        'discount_total': _detail['discount_total'] ?? 0,
        'grand_total': _detail['grand_total'] ?? 0,
        'status': 'issued',
        'is_locked': true,
        'locked_by': userId,
        'locked_at': DateTime.now().toUtc().toIso8601String(),
        'created_by': userId,
      });

      for (final si in _items) {
        final pid = si['product_id'] as String;
        final qty = (si['quantity'] as num?)?.toDouble() ?? 0;
        await Supabase.instance.client.from('sales_return_invoice_items').insert({
          'id': 'srii_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'invoice_id': invId,
          'srn_item_id': si['id'],
          'product_id': pid,
          'uom_id': si['uom_id'],
          'quantity': qty,
          'unit_price': si['unit_price'],
          'discount': si['discount'],
          'line_total': si['line_total'],
        });
        if (qty <= 0) continue;
        final stock = await Supabase.instance.client.from('inventory_stock').select()
            .eq('org_id', orgId).eq('product_id', pid).eq('branch_id', branchId).maybeSingle();
        if (stock == null) {
          await Supabase.instance.client.from('inventory_stock').insert({
            'id': 'is_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
            'org_id': orgId, 'product_id': pid, 'branch_id': branchId, 'quantity': qty,
          });
        } else {
          await Supabase.instance.client.from('inventory_stock').update({
            'quantity': ((stock['quantity'] as num).toDouble()) + qty,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', stock['id']);
        }
        await Supabase.instance.client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'org_id': orgId, 'product_id': pid, 'branch_id': branchId,
          'uom_id': si['uom_id'], 'quantity': qty,
          'movement_type': 'adjustment',
          'reference_id': invId, 'reference_type': 'sales_return_invoice',
          'moved_at': DateTime.now().toUtc().toIso8601String(),
          'created_by': userId,
        });
      }

      // Flip SRN status + auto-lock
      await Supabase.instance.client.from('sales_returns').update({
        'status': 'invoiced',
        'is_locked': true,
        'locked_by': userId,
        'locked_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', srnId);

      await _logAudit(srnId, 'invoiced', 'Converted to invoice $voucherNum');
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': orgId,
        'voucher_id': invId, 'voucher_type': 'SRI',
        'action': 'created', 'details': 'Generated from SRN ${_detail['voucher_number']}',
        'user_id': userId,
      });

      _showSnack('$voucherNum created — stock returned. See "Sales Return Invoices" tab.');
      _loadDetail(srnId);
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _delete() async {
    if (!_canDelete) return;
    // Cascade check: no SRI should reference this SRN
    try {
      final invs = await Supabase.instance.client.from('sales_return_invoices')
          .select('id, voucher_number').eq('srn_id', _detail['id']);
      if ((invs as List).isNotEmpty) {
        _showSnack('Cannot delete: invoice ${invs.first['voucher_number']} exists. Delete the invoice first.');
        return;
      }
    } catch (e) { _showSnack('Failed to check: $e'); return; }

    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete Sales Return Note?'),
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
      await Supabase.instance.client.from('sales_return_items').delete().eq('return_id', _detail['id']);
      await Supabase.instance.client.from('sales_returns').delete().eq('id', _detail['id']);
      _showSnack('Deleted');
      setState(() { _selectedId = null; _detail = {}; _items = []; });
      await _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    final lines = _items.map((it) {
      final qty   = (it['quantity'] as num?)?.toDouble() ?? 0;
      final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
      final disc  = (it['discount'] as num?)?.toDouble() ?? 0;
      final lt    = (it['line_total'] as num?)?.toDouble() ?? qty * price * (1 - disc / 100);
      return VoucherLine(
        product: it['products']?['name'] as String? ?? '-',
        sku: it['products']?['sku'] as String?,
        uom: it['uoms']?['abbreviation'] as String?,
        qty: qty, unitPrice: price, discountPct: disc, lineTotal: lt,
      );
    }).toList();
    final date = _detail['voucher_date'] != null
        ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null;
    final createdAt = _detail['created_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal()) : null;
    final cust = _detail['customers'] as Map?;
    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Sales Return Note',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: date,
      customerOrSupplier: cust?['shop_name'] as String? ?? 'Walk-in',
      customerAddress: cust?['address'] as String?,
      customerContact: cust?['contact_person'] as String?,
      customerPhone: cust?['phone'] as String?,
      salespersonName: _meta.salespersonName,
      lines: lines,
      subtotal: (_detail['subtotal'] as num?)?.toDouble() ?? 0,
      discountTotal: (_detail['discount_total'] as num?)?.toDouble() ?? 0,
      grandTotal: (_detail['grand_total'] as num?)?.toDouble() ?? 0,
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
            ? const Center(child: Text('Select or create a Sales Return Note',
                style: TextStyle(fontSize: 16, color: AppTheme.textSecondary)))
            : _buildDetail(),
      ),
    );
  }

  Widget _buildList() {
    final q = _search.toLowerCase().trim();
    final filtered = _returns.where((r) {
      if (q.isEmpty) return true;
      return (r['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
             ((r['customers']?['shop_name'] as String?) ?? '').toLowerCase().contains(q);
    }).toList();
    return Container(
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppTheme.border))),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Row(children: [
            const Expanded(child: Text('Sales Return Notes', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
            IconButton(
              icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 32),
              onPressed: _createNew,
              tooltip: 'New SRN',
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search SRN / customer…',
              prefixIcon: Icon(Icons.search, size: 18),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _listLoading
              ? const Center(child: CircularProgressIndicator())
              : filtered.isEmpty
                  ? const Center(child: Text('No SRNs yet.', style: TextStyle(color: AppTheme.textSecondary)))
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
                          subtitle: Text(r['customers']?['shop_name'] as String? ?? 'Walk-in',
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
    final cust = _detail['customers'] as Map?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header
      Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_detail['voucher_number'] as String? ?? '-',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Text('Sales Return Note',
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
              icon: const Icon(Icons.receipt_long, size: 16),
              label: const Text('Generate Invoice'),
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
            // Customer chip + dates
            Wrap(spacing: 12, runSpacing: 8, children: [
              _Chip(label: 'Customer', value: cust?['shop_name'] as String? ?? 'Walk-in'),
              _Chip(label: 'Date', value: _detail['voucher_date'] != null
                  ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-'),
              _Chip(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-'),
              _Chip(label: 'Status', value: (_detail['status'] as String? ?? 'draft')),
            ]),
            if (cust != null) _SupplierStrip(
              address: cust['address'] as String?,
              contact: cust['contact_person'] as String?,
              phone: cust['phone'] as String?,
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
                    Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 1, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                    Expanded(flex: 2, child: Text('Price', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                    Expanded(flex: 1, child: Text('Disc%', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                    Expanded(flex: 2, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                    SizedBox(width: 44),
                  ]),
                ),
                const Divider(height: 1),

                // Existing rows
                if (_items.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text('No items yet — add below.', style: TextStyle(color: AppTheme.textSecondary))),
                ..._items.map((it) {
                  final qty   = (it['quantity'] as num?)?.toDouble() ?? 0;
                  final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
                  final disc  = (it['discount'] as num?)?.toDouble() ?? 0;
                  final total = (it['line_total'] as num?)?.toDouble() ?? qty * price * (1 - disc / 100);
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(children: [
                      Expanded(flex: 4, child: Text(it['products']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 1, child: Text(it['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text(qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Expanded(flex: 2, child: Text(price.toStringAsFixed(2), textAlign: TextAlign.right)),
                      Expanded(flex: 1, child: Text('${disc.toStringAsFixed(disc % 1 == 0 ? 0 : 2)}%', textAlign: TextAlign.right)),
                      Expanded(flex: 2, child: Text(total.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
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
                      Expanded(flex: 4, child: DropdownButtonFormField<String>(
                        value: _addProductId,
                        isDense: true,
                        isExpanded: true,
                        decoration: const InputDecoration(hintText: 'Pick product', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                        items: _products.map((p) => DropdownMenuItem<String>(
                          value: p['id'] as String,
                          child: Text('${p['name']}${p['sku'] != null ? " · ${p['sku']}" : ""}',
                              overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                        )).toList(),
                        onChanged: (v) => setState(() {
                          _addProductId = v;
                          final p = _products.firstWhere((x) => x['id'] == v, orElse: () => {});
                          _addUomId = p['base_uom_id'] as String?;
                          _addPriceCtrl.text = (p['selling_price'] as num?)?.toStringAsFixed(2) ?? '0';
                        }),
                      )),
                      Expanded(flex: 1, child: Padding(
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
                      Expanded(flex: 1, child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: TextField(controller: _addQtyCtrl,
                            decoration: const InputDecoration(hintText: 'Qty', isDense: true),
                            textAlign: TextAlign.right,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            textInputAction: TextInputAction.next,
                            onSubmitted: (_) => _addItem()),
                      )),
                      Expanded(flex: 2, child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: TextField(controller: _addPriceCtrl,
                            decoration: const InputDecoration(hintText: 'Price', isDense: true),
                            textAlign: TextAlign.right,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            textInputAction: TextInputAction.next,
                            onSubmitted: (_) => _addItem()),
                      )),
                      Expanded(flex: 1, child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: TextField(controller: _addDiscCtrl,
                            decoration: const InputDecoration(hintText: '%', isDense: true),
                            textAlign: TextAlign.right,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _addItem()),
                      )),
                      const Expanded(flex: 2, child: SizedBox()),
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

            const SizedBox(height: 16),

            // Totals
            Align(alignment: Alignment.centerRight, child: Container(
              padding: const EdgeInsets.all(12),
              width: 280,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _totalRow('Subtotal', (_detail['subtotal'] as num?)?.toDouble() ?? 0),
                _totalRow('Discount', (_detail['discount_total'] as num?)?.toDouble() ?? 0, color: AppTheme.warning),
                const Divider(height: 8),
                _totalRow('Grand Total', (_detail['grand_total'] as num?)?.toDouble() ?? 0, bold: true),
              ]),
            )),
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

// ─── Customer Select Dialog ───────────────────────────────────────────────────
class _CustomerSelectDialog extends StatefulWidget {
  final List<Map<String, dynamic>> customers;
  const _CustomerSelectDialog({required this.customers});
  @override
  State<_CustomerSelectDialog> createState() => _CustomerSelectDialogState();
}

class _CustomerSelectDialogState extends State<_CustomerSelectDialog> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase().trim();
    final filtered = widget.customers.where((c) {
      if (q.isEmpty) return true;
      return (c['shop_name'] as String? ?? '').toLowerCase().contains(q) ||
             (c['code'] as String? ?? '').toLowerCase().contains(q);
    }).toList();
    return AlertDialog(
      title: Text('Select Customer  ·  ${widget.customers.length} total'),
      content: SizedBox(width: 480, height: 460, child: Column(children: [
        TextField(
          decoration: const InputDecoration(hintText: 'Search name / code', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
          onChanged: (v) => setState(() => _q = v),
          autofocus: true,
        ),
        const SizedBox(height: 12),
        // Walk-in option pinned at top
        Container(
          decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.05), borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.primary.withOpacity(0.3))),
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.person_outline, color: AppTheme.primary),
            title: const Text('Walk-in', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('No customer linked', style: TextStyle(fontSize: 11)),
            onTap: () => Navigator.pop(context, {'id': null, 'shop_name': 'Walk-in'}),
          ),
        ),
        const SizedBox(height: 6),
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
                      title: Text(c['shop_name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
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

// ─── Supplier/Customer Info Strip ────────────────────────────────────────────
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
