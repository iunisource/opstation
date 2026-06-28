import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';
import '../services/voucher_pdf.dart';
import '../services/voucher_meta.dart';

// ─── Purchase Orders List ─────────────────────────────────────────────────────

class ErpPurchaseScreen extends ConsumerStatefulWidget {
  const ErpPurchaseScreen({super.key});
  @override
  ConsumerState<ErpPurchaseScreen> createState() => _ErpPurchaseScreenState();
}

class _ErpPurchaseScreenState extends ConsumerState<ErpPurchaseScreen> {
  List<Map<String, dynamic>> _orders = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loading = true;
  String _statusFilter = 'all';

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final branchId = ref.read(selectedBranchProvider)?['id'] as String?;
      var query = Supabase.instance.client
          .from('purchase_orders')
          .select('*, suppliers(name), branches(name)')
          .eq('org_id', orgId);
      if (branchId != null) query = query.eq('branch_id', branchId);
      final res = await query.order('created_at', ascending: false);
      setState(() {
        _orders = List<Map<String, dynamic>>.from(res);
        _filtered = _orders;
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  void _applyFilter() {
    setState(() {
      _filtered = _statusFilter == 'all'
          ? _orders
          : _orders.where((o) => o['status'] == _statusFilter).toList();
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'pending_approval': return Colors.orange;
      case 'ordered': return Colors.blue;
      case 'partially_received': return Colors.teal;
      case 'received': return AppTheme.success;
      case 'cancelled': return AppTheme.danger;
      default: return AppTheme.textSecondary;
    }
  }

  String _statusLabel(String s) {
    final parts = s.split('_');
    return parts.map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
  }

  void _openOrder(Map<String, dynamic> order) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PurchaseOrderDetailScreen(orderId: order['id'] as String, onUpdated: _load),
    ));
  }

  void _showCreateDialog() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = ref.read(selectedBranchProvider)?['id'] as String?;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    final suppliers = await Supabase.instance.client
        .from('suppliers').select().eq('org_id', orgId).eq('is_active', true).order('name').limit(10000);
    if (!mounted) return;
    String? supplierId;
    final remarksCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('New Purchase Order'),
          content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: supplierId,
              decoration: const InputDecoration(labelText: 'Supplier *'),
              hint: const Text('Select supplier'),
              items: (suppliers as List).map((s) => DropdownMenuItem(
                  value: s['id'] as String, child: Text(s['name'] as String))).toList(),
              onChanged: (v) => setS(() => supplierId = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: remarksCtrl, decoration: const InputDecoration(labelText: 'Remarks'), maxLines: 2),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (supplierId == null) { ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Select a supplier'))); return; }
                final userId = ref.read(currentUserProvider)?.id;
                final year = DateTime.now().year;
                try {
                  final _vSeq = await Supabase.instance.client
                      .rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'PO', 'p_year': year});
                  final voucherNum = 'PO-$year-${_vSeq.toString().padLeft(4, '0')}';
                  final id = 'po_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client.from('purchase_orders').insert({
                    'id': id, 'org_id': orgId, 'branch_id': branchId,
                    'voucher_number': voucherNum,
                    'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
                    'supplier_id': supplierId,
                    'remarks': remarksCtrl.text.trim().isEmpty ? null : remarksCtrl.text.trim(),
                    'status': 'draft', 'is_locked': false, 'created_by': userId,
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack('Purchase order created');
                  await _load();
                  final order = _orders.firstWhere((o) => o['id'] == id, orElse: () => {});
                  if (order.isNotEmpty && mounted) _openOrder(order);
                } catch (e) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: $e')));
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Purchase Orders', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(onPressed: _showCreateDialog, icon: const Icon(Icons.add, size: 18), label: const Text('New PO')),
        ]),
        const SizedBox(height: 8),
        Text('${_filtered.length} orders', style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        SizedBox(width: 280, child: DropdownButtonFormField<String>(
          value: _statusFilter,
          decoration: const InputDecoration(labelText: 'Status', isDense: true),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All')),
            DropdownMenuItem(value: 'draft', child: Text('Draft')),
            DropdownMenuItem(value: 'pending_approval', child: Text('Pending Approval')),
            DropdownMenuItem(value: 'ordered', child: Text('Ordered')),
            DropdownMenuItem(value: 'partially_received', child: Text('Partially Received')),
            DropdownMenuItem(value: 'received', child: Text('Received')),
            DropdownMenuItem(value: 'cancelled', child: Text('Cancelled')),
          ],
          onChanged: (v) { if (v != null) { setState(() => _statusFilter = v); _applyFilter(); } },
        )),
        const SizedBox(height: 16),
        if (_loading) const Center(child: CircularProgressIndicator())
        else Expanded(child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
              child: const Row(children: [
                Expanded(flex: 2, child: Text('PO #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 3, child: Text('Supplier', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                SizedBox(width: 48),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _filtered.isEmpty
                  ? const Center(child: Text('No purchase orders yet.', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      itemCount: _filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final o = _filtered[i];
                        final status = o['status'] as String? ?? 'draft';
                        final date = o['voucher_date'] != null
                            ? DateFormat('d MMM yyyy').format(DateTime.parse(o['voucher_date'] as String)) : '-';
                        return InkWell(
                          onTap: () => _openOrder(o),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(children: [
                              Expanded(flex: 2, child: Text(o['voucher_number'] as String? ?? '-',
                                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                              Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 13))),
                              Expanded(flex: 3, child: Text(o['suppliers']?['name'] as String? ?? '-')),
                              Expanded(flex: 2, child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(color: _statusColor(status).withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                                child: Text(_statusLabel(status),
                                    style: TextStyle(color: _statusColor(status), fontSize: 12, fontWeight: FontWeight.w600)),
                              )),
                              const SizedBox(width: 48, child: Icon(Icons.chevron_right, color: AppTheme.textSecondary)),
                            ]),
                          ),
                        );
                      }),
            ),
          ]),
        )),
      ]),
    );
  }
}

// ─── Purchase Order Detail ────────────────────────────────────────────────────

class PurchaseOrderDetailScreen extends ConsumerStatefulWidget {
  final String orderId;
  final VoidCallback onUpdated;
  const PurchaseOrderDetailScreen({super.key, required this.orderId, required this.onUpdated});
  @override
  ConsumerState<PurchaseOrderDetailScreen> createState() => _PurchaseOrderDetailScreenState();
}

class _PurchaseOrderDetailScreenState extends ConsumerState<PurchaseOrderDetailScreen> {
  Map<String, dynamic> _order = {};
  bool _approvalRequired = false;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _uoms = [];
  VoucherMeta _meta = VoucherMeta();
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _canDelete {
    final role = ref.read(currentUserProvider)?.role;
    return role == WebUserRole.masterAdmin || role == WebUserRole.admin;
  }

  final Map<String, TextEditingController> _qtyCtrls = {};

  @override
  void dispose() {
    for (final c in _qtyCtrls.values) { c.dispose(); }
    super.dispose();
  }

  // Rebuild the per-line qty controllers from the current items.
  void _syncQtyCtrls() {
    for (final c in _qtyCtrls.values) { c.dispose(); }
    _qtyCtrls.clear();
    for (final it in _items) {
      final id = it['id'] as String;
      final q = (it['quantity_ordered'] as num?)?.toDouble() ?? 0;
      _qtyCtrls[id] = TextEditingController(text: q.toStringAsFixed(q % 1 == 0 ? 0 : 2));
    }
  }

  Future<void> _saveLineQty(String itemId) async {
    if (!_canEdit) return;
    final cur = (_items.firstWhere((i) => i['id'] == itemId, orElse: () => {})['quantity_ordered'] as num?)?.toDouble() ?? 0;
    final q = double.tryParse(_qtyCtrls[itemId]?.text.trim() ?? '');
    if (q == null || q <= 0) {
      _qtyCtrls[itemId]?.text = cur.toStringAsFixed(cur % 1 == 0 ? 0 : 2);
      _showSnack('Enter a quantity greater than 0');
      return;
    }
    if (q == cur) return; // no change
    try {
      await Supabase.instance.client.from('purchase_order_items')
          .update({'quantity_ordered': q}).eq('id', itemId);
      final idx = _items.indexWhere((i) => i['id'] == itemId);
      if (idx >= 0) setState(() => _items[idx]['quantity_ordered'] = q);
      _showSnack('Quantity updated');
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _load() async {
    final orgId = _orgId;
    try {
      final client = Supabase.instance.client;
      final order = await client.from('purchase_orders')
          .select('*, suppliers(name, address, contact_person, contact_number, phone, ntn), branches(name)').eq('id', widget.orderId).single();
      final items = await client.from('purchase_order_items')
          .select('*, products(name, sku), uoms(abbreviation)').eq('purchase_order_id', widget.orderId);
      final products = await client.from('products')
          .select('id, name, sku, base_uom_id, cost_price').eq('org_id', orgId!).eq('is_active', true).order('name').limit(10000);
      final uoms = await client.from('uoms').select().eq('org_id', orgId).order('name');
      final cfg = await client.from('app_config').select('value')
          .eq('org_id', orgId).eq('key', 'org.po_approval_required').maybeSingle();
      final meta = await VoucherMeta.fetch(
        orgId: orgId,
        customerId: null,  // PO has no customer; salesperson lookup will be null
        createdById: order['created_by'] as String?,
      );
      setState(() {
        _order = Map<String, dynamic>.from(order);
        _approvalRequired = (cfg?['value'] as String?) == 'true';
        _items = List<Map<String, dynamic>>.from(items);
        _syncQtyCtrls();
        _products = List<Map<String, dynamic>>.from(products);
        _uoms = List<Map<String, dynamic>>.from(uoms);
        _meta = meta;
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  Future<void> _logAudit(String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'id': 'al_${DateTime.now().microsecondsSinceEpoch}',
        'voucher_id': widget.orderId, 'voucher_type': 'PO',
        'action': action, 'details': details,
        'user_id': ref.read(currentUserProvider)?.id,
      });
    } catch (_) {}
  }

  Future<void> _deletePO() async {
    // Cascade check: no GRN should exist for this PO
    try {
      final grns = await Supabase.instance.client.from('purchase_grns')
          .select('id, voucher_number').eq('po_id', widget.orderId);
      if ((grns as List).isNotEmpty) {
        _showSnack('Cannot delete: ${grns.length} GRN(s) exist. Delete them first.');
        return;
      }
    } catch (e) { _showSnack('Failed to check: $e'); return; }

    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete Purchase Order?'),
      content: Text('Permanently delete ${_order['voucher_number']}? This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete')),
      ],
    ));
    if (confirm != true) return;

    try {
      final vNum = _order['voucher_number'] as String? ?? '';
      final bankErr = await _bankCancelledVoucherNumber(
        orgId: _orgId, branchId: _order['branch_id'] as String?, voucherNumber: vNum);
      if (bankErr != null) _showSnack('Bank # failed: $bankErr');

      await _logAudit('deleted', 'Voucher $vNum deleted by admin');
      await Supabase.instance.client.from('purchase_order_items').delete().eq('purchase_order_id', widget.orderId);
      await Supabase.instance.client.from('purchase_orders').delete().eq('id', widget.orderId);

      _showSnack('Deleted');
      widget.onUpdated();
      if (mounted) Navigator.of(context).pop();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _printPO() async {
    final user = ref.read(currentUserProvider);
    final lines = _items.map((it) {
      final qty = (it['quantity_ordered'] as num?)?.toDouble() ?? 0;
      final cost = (it['unit_cost'] as num?)?.toDouble() ?? 0;
      return VoucherLine(
        product: it['products']?['name'] as String? ?? '-',
        sku: it['products']?['sku'] as String?,
        uom: it['uoms']?['abbreviation'] as String?,
        qty: qty, unitPrice: cost, lineTotal: qty * cost,
      );
    }).toList();
    double subtotal = 0;
    for (final l in lines) { subtotal += l.qty * (l.unitPrice ?? 0); }
    final sup = _order['suppliers'] as Map?;
    final date = _order['voucher_date'] != null
        ? DateFormat('d MMM yyyy').format(DateTime.parse(_order['voucher_date'] as String)) : null;
    final createdAt = _order['created_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_order['created_at'] as String).toLocal()) : null;
    await VoucherPdf.printVoucher(
      voucherNumber: _order['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Purchase Order',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _order['branches']?['name'] as String?,
      date: date,
      customerOrSupplier: sup?['name'] as String?,
      customerAddress: sup?['address'] as String?,
      customerContact: sup?['contact_person'] as String?,
      customerPhone: (sup?['contact_number'] ?? sup?['phone']) as String?,
      status: (_order['status'] as String? ?? '').replaceAll('_', ' '),
      remarks: _order['remarks'] as String?,
      lines: lines,
      subtotal: subtotal, grandTotal: subtotal,
      preparedBy: _meta.preparedBy,
      createdAt: createdAt,
      footerNote: _meta.footerNote,
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  bool get _isDraft => (_order['status'] as String? ?? 'draft') == 'draft';
  bool get _isPending => (_order['status'] as String? ?? '') == 'pending_approval';
  bool get _isAdmin {
    final role = ref.read(currentUserProvider)?.role;
    return role == WebUserRole.masterAdmin || role == WebUserRole.admin || role == WebUserRole.superAdmin;
  }
  bool get _isLocked => _order['is_locked'] as bool? ?? false;
  bool get _canEdit => _isDraft && !_isLocked;
  // Line-item deletion is gated on the lock ONLY — not on approval/status.
  // Unlock the PO and lines can be deleted regardless of whether it's been
  // marked ordered/approved; while locked, deletion is blocked.
  bool get _canDeleteLine => !_isLocked;

  void _showAddItemDialog() {
    String? productId;
    String? uomId;
    final qtyCtrl = TextEditingController(text: '1');
    final costCtrl = TextEditingController(text: '0');
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Add Item'),
          content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: productId,
              decoration: const InputDecoration(labelText: 'Product *'),
              hint: const Text('Select product'),
              items: _products.map((p) => DropdownMenuItem(
                  value: p['id'] as String,
                  child: Text('${p['name']}${p['sku'] != null ? ' (${p['sku']})' : ''}'))).toList(),
              onChanged: (v) {
                setS(() {
                  productId = v;
                  final prod = _products.firstWhere((p) => p['id'] == v, orElse: () => {});
                  uomId = prod['base_uom_id'] as String?;
                  costCtrl.text = prod['cost_price']?.toString() ?? '0';
                });
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: uomId,
              decoration: const InputDecoration(labelText: 'UOM *'),
              hint: const Text('Select UOM'),
              items: _uoms.map((u) => DropdownMenuItem(
                  value: u['id'] as String,
                  child: Text('${u['name']} (${u['abbreviation']})'))).toList(),
              onChanged: (v) => setS(() => uomId = v),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TextField(controller: qtyCtrl, decoration: const InputDecoration(labelText: 'Quantity *'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: costCtrl, decoration: const InputDecoration(labelText: 'Unit Cost'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true))),
            ]),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (productId == null || uomId == null) return;
                final qty = double.tryParse(qtyCtrl.text.trim()) ?? 0;
                if (qty <= 0) return;
                try {
                  await Supabase.instance.client.from('purchase_order_items').insert({
                    'id': 'poi_${DateTime.now().millisecondsSinceEpoch}',
                    'purchase_order_id': widget.orderId,
                    'product_id': productId, 'uom_id': uomId,
                    'quantity_ordered': qty, 'quantity_received': 0,
                    'unit_cost': double.tryParse(costCtrl.text.trim()) ?? 0,
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _load();
                } catch (e) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: $e')));
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _markOrdered() async {
    if (_items.isEmpty) { _showSnack('Add items first'); return; }
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'status': 'ordered', 'is_locked': true,
        'ordered_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.orderId);
      _showSnack('PO marked as ordered and locked');
      ref.invalidate(poPendingApprovalCountProvider);
      widget.onUpdated();
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _submitForApproval() async {
    if (_items.isEmpty) { _showSnack('Add items first'); return; }
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'status': 'pending_approval', 'is_locked': true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.orderId);
      _showSnack('Submitted for approval');
      ref.invalidate(poPendingApprovalCountProvider);
      widget.onUpdated();
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _approve() async {
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'status': 'ordered', 'is_locked': true,
        'ordered_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.orderId);
      _showSnack('PO approved and ordered');
      ref.invalidate(poPendingApprovalCountProvider);
      widget.onUpdated();
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _returnToDraft() async {
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'status': 'draft', 'is_locked': false,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.orderId);
      _showSnack('Returned to draft');
      ref.invalidate(poPendingApprovalCountProvider);
      widget.onUpdated();
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.orderId);
      _showSnack(newLocked ? 'PO locked' : 'PO unlocked');
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _cancelOrder() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel PO'),
        content: const Text('Are you sure?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('No')),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Cancel PO')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'status': 'cancelled', 'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.orderId);
      _showSnack('PO cancelled');
      widget.onUpdated();
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  double get _total => _items.fold(0.0, (sum, item) =>
      sum + ((item['quantity_ordered'] as num?)?.toDouble() ?? 0) *
            ((item['unit_cost'] as num?)?.toDouble() ?? 0));

  @override
  Widget build(BuildContext context) {
    final status = _order['status'] as String? ?? 'draft';
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.white, elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_order['voucher_number'] as String? ?? 'Purchase Order',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text(_order['suppliers']?['name'] as String? ?? '-',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w400)),
        ]),
        actions: [
          if (_isDraft) ...[
            if (!_isLocked) ...[
              if (_approvalRequired)
                ElevatedButton(onPressed: _submitForApproval, child: const Text('Submit for Approval'))
              else
                ElevatedButton(onPressed: _markOrdered, child: const Text('Mark Ordered')),
              const SizedBox(width: 8),
              TextButton(onPressed: _cancelOrder,
                  style: TextButton.styleFrom(foregroundColor: AppTheme.danger), child: const Text('Cancel')),
            ],
            TextButton.icon(
              onPressed: _toggleLock,
              icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, size: 16),
              label: Text(_isLocked ? 'Unlock' : 'Lock'),
              style: TextButton.styleFrom(foregroundColor: _isLocked ? Colors.orange : AppTheme.textSecondary),
            ),
          ],
          if (_isPending) ...[
            if (_isAdmin) ...[
              ElevatedButton.icon(
                onPressed: _approve,
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Approve'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: _returnToDraft,
                  style: TextButton.styleFrom(foregroundColor: Colors.orange), child: const Text('Return to Draft')),
            ] else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Colors.orange.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.hourglass_top, size: 14, color: Colors.orange),
                  SizedBox(width: 6),
                  Text('Awaiting approval', style: TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
          ],
          if (status == 'ordered')
            TextButton.icon(
              onPressed: _toggleLock,
              icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, size: 16),
              label: Text(_isLocked ? 'Unlock' : 'Lock'),
              style: TextButton.styleFrom(foregroundColor: _isLocked ? Colors.orange : AppTheme.textSecondary),
            ),
          IconButton(
            icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary),
            tooltip: 'Print / PDF',
            onPressed: _printPO,
          ),
          if (_canDelete)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
              tooltip: 'Delete',
              onPressed: _deletePO,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 12, runSpacing: 8, children: [
                  _InfoChip(label: 'Branch', value: _order['branches']?['name'] as String? ?? '-'),
                  _InfoChip(label: 'Date', value: _order['voucher_date'] != null
                      ? DateFormat('d MMM yyyy').format(DateTime.parse(_order['voucher_date'] as String)) : '-'),
                  _InfoChip(label: 'Status', value: status.split('_').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ')),
                  if (_order['remarks'] != null) _InfoChip(label: 'Remarks', value: _order['remarks'] as String),
                  if (_isLocked) const _LockedChip(),
                ]),
                _VoucherInfoStrip(
                  supplierAddress: _order['suppliers']?['address'] as String?,
                  supplierContact: _order['suppliers']?['contact_person'] as String?,
                  supplierPhone: (_order['suppliers']?['contact_number'] ?? _order['suppliers']?['phone']) as String?,
                  ntn: _order['suppliers']?['ntn'] as String?,
                  preparedBy: _meta.preparedBy,
                  createdAt: _order['created_at'] != null
                      ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_order['created_at'] as String).toLocal())
                      : null,
                ),
                const SizedBox(height: 24),
                Row(children: [
                  const Text('Items', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (_canEdit)
                    ElevatedButton.icon(onPressed: _showAddItemDialog,
                        icon: const Icon(Icons.add, size: 16), label: const Text('Add Item')),
                ]),
                const SizedBox(height: 12),
                Expanded(child: Container(
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
                  child: Column(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                      child: const Row(children: [
                        Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Unit Cost', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        SizedBox(width: 48),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _items.isEmpty
                          ? const Center(child: Text('No items yet.', style: TextStyle(color: AppTheme.textSecondary)))
                          : ListView.separated(
                              itemCount: _items.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final item = _items[i];
                                final qty = (item['quantity_ordered'] as num?)?.toDouble() ?? 0;
                                final cost = (item['unit_cost'] as num?)?.toDouble() ?? 0;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  child: Row(children: [
                                    Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                                      if (item['products']?['sku'] != null)
                                        Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                    ])),
                                    Expanded(flex: 1, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary))),
                                    Expanded(flex: 2, child: _canEdit
                                        ? SizedBox(
                                            width: 96,
                                            child: Focus(
                                              onFocusChange: (has) { if (!has) _saveLineQty(item['id'] as String); },
                                              child: TextField(
                                                controller: _qtyCtrls[item['id']],
                                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                                style: const TextStyle(fontWeight: FontWeight.w600),
                                                decoration: const InputDecoration(
                                                    isDense: true,
                                                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                                                onSubmitted: (_) => _saveLineQty(item['id'] as String),
                                              ),
                                            ))
                                        : Text(qty.toStringAsFixed(0), style: const TextStyle(fontWeight: FontWeight.w600))),
                                    Expanded(flex: 2, child: Text(cost.toStringAsFixed(2))),
                                    Expanded(flex: 2, child: Text((qty * cost).toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.w600))),
                                    SizedBox(width: 48, child: _canDeleteLine
                                        ? IconButton(
                                            icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                                            tooltip: 'Delete item',
                                            onPressed: () async {
                                              if (_isLocked) { _showSnack('Unlock the PO to delete items'); return; }
                                              await Supabase.instance.client.from('purchase_order_items').delete().eq('id', item['id']);
                                              _load();
                                            })
                                        : const SizedBox.shrink()),
                                  ]),
                                );
                              }),
                    ),
                    if (_items.isNotEmpty) ...[
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        child: Row(children: [
                          const Spacer(),
                          Text('Total: ${_total.toStringAsFixed(2)}',
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        ]),
                      ),
                    ],
                  ]),
                )),
                const SizedBox(height: 12),
                _AuditTrail(createdBy: _order['created_by'] as String?, createdAt: _order['created_at'] as String?),
              ]),
            ),
    );
  }
}

// ─── GRN List ─────────────────────────────────────────────────────────────────

class ErpGrnScreen extends ConsumerStatefulWidget {
  const ErpGrnScreen({super.key});
  @override
  ConsumerState<ErpGrnScreen> createState() => _ErpGrnScreenState();
}

class _ErpGrnScreenState extends ConsumerState<ErpGrnScreen> {
  List<Map<String, dynamic>> _grns = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final branchId = ref.read(selectedBranchProvider)?['id'] as String?;
      var query = Supabase.instance.client
          .from('purchase_grns')
          .select('*, suppliers(name), purchase_orders(voucher_number), branches(name)')
          .eq('org_id', orgId);
      if (branchId != null) query = query.eq('branch_id', branchId);
      final res = await query.order('created_at', ascending: false);
      setState(() {
        _grns = List<Map<String, dynamic>>.from(res);
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  void _openGrn(Map<String, dynamic> grn) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GrnDetailScreen(grnId: grn['id'] as String, onUpdated: _load),
    ));
  }

  void _showCreateDialog() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = ref.read(selectedBranchProvider)?['id'] as String?;
    if (orgId == null || branchId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select a branch first')));
      return;
    }
    // POs open for a NEW GRN: status ordered/partially_received, remaining qty > 0,
    // and no pending GRN (one already created whose received qty isn't confirmed yet).
    final client = Supabase.instance.client;
    final poRows = List<Map<String, dynamic>>.from(await client
        .from('purchase_orders')
        .select('id, voucher_number, supplier_id, suppliers(name)')
        .eq('org_id', orgId).eq('branch_id', branchId)
        .inFilter('status', ['ordered', 'partially_received']));
    if (!mounted) return;
    final List<Map<String, dynamic>> pos = [];
    if (poRows.isNotEmpty) {
      final poIds = poRows.map((p) => p['id'] as String).toList();
      final itemRows = List<Map<String, dynamic>>.from(await client
          .from('purchase_order_items')
          .select('purchase_order_id, quantity_ordered, qty_received')
          .inFilter('purchase_order_id', poIds));
      final remaining = <String, double>{};
      for (final it in itemRows) {
        final pid = it['purchase_order_id'] as String;
        final ord = (it['quantity_ordered'] as num?)?.toDouble() ?? 0;
        final rcv = (it['qty_received'] as num?)?.toDouble() ?? 0;
        remaining[pid] = (remaining[pid] ?? 0) + (ord - rcv);
      }
      final grnRows = List<Map<String, dynamic>>.from(await client
          .from('purchase_grns').select('id, po_id')
          .inFilter('po_id', poIds).neq('status', 'cancelled'));
      final pendingPos = <String>{};
      if (grnRows.isNotEmpty) {
        final grnIds = grnRows.map((g) => g['id'] as String).toList();
        final grnItemRows = List<Map<String, dynamic>>.from(await client
            .from('purchase_grn_items').select('grn_id').inFilter('grn_id', grnIds));
        final withItems = grnItemRows.map((r) => r['grn_id'] as String).toSet();
        for (final g in grnRows) {
          if (!withItems.contains(g['id'] as String)) pendingPos.add(g['po_id'] as String);
        }
      }
      for (final p in poRows) {
        final pid = p['id'] as String;
        final rem = remaining[pid] ?? 0;
        if (rem > 0.0001 && !pendingPos.contains(pid)) pos.add({...p, '_remaining': rem});
      }
    }
    if (pos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No POs available for a new GRN (all received, or pending an unconfirmed GRN)')));
      return;
    }
    String? poId;
    final remarksCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('New Goods Receipt Note'),
          content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: poId,
              decoration: const InputDecoration(labelText: 'Purchase Order *'),
              hint: const Text('Select PO'),
              items: pos.map((p) {
                final rem = (p['_remaining'] as num?)?.toDouble() ?? 0;
                final remStr = rem == rem.roundToDouble() ? rem.toInt().toString() : rem.toStringAsFixed(2);
                return DropdownMenuItem(
                  value: p['id'] as String,
                  child: Text('${p['voucher_number']} — ${p['suppliers']?['name'] ?? '-'}  ·  $remStr left'));
              }).toList(),
              onChanged: (v) => setS(() => poId = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: remarksCtrl, decoration: const InputDecoration(labelText: 'Remarks'), maxLines: 2),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (poId == null) return;
                final userId = ref.read(currentUserProvider)?.id;
                final year = DateTime.now().year;
                try {
                  final po = pos.firstWhere((p) => p['id'] == poId);
                  final _vSeq = await Supabase.instance.client
                      .rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'GRN', 'p_year': year});
                  final voucherNum = 'GRN-$year-${_vSeq.toString().padLeft(4, '0')}';
                  final id = 'grn_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client.from('purchase_grns').insert({
                    'id': id, 'org_id': orgId, 'branch_id': branchId,
                    'voucher_number': voucherNum,
                    'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
                    'po_id': poId, 'supplier_id': po['supplier_id'],
                    'remarks': remarksCtrl.text.trim().isEmpty ? null : remarksCtrl.text.trim(),
                    'status': 'saved', 'is_locked': true, 'created_by': userId,
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  await _load();
                  final grn = _grns.firstWhere((g) => g['id'] == id, orElse: () => {});
                  if (grn.isNotEmpty && mounted) _openGrn(grn);
                } catch (e) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: $e')));
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'invoiced': return AppTheme.success;
      case 'cancelled': return AppTheme.danger;
      default:
      return Colors.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Goods Receipt Notes', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(onPressed: _showCreateDialog, icon: const Icon(Icons.add, size: 18), label: const Text('New GRN')),
        ]),
        const SizedBox(height: 8),
        Text('${_grns.length} GRNs', style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 24),
        if (_loading) const Center(child: CircularProgressIndicator())
        else Expanded(child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
              child: const Row(children: [
                Expanded(flex: 2, child: Text('GRN #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('PO #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 3, child: Text('Supplier', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                SizedBox(width: 48),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _grns.isEmpty
                  ? const Center(child: Text('No GRNs yet.', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      itemCount: _grns.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final g = _grns[i];
                        final status = g['status'] as String? ?? 'saved';
                        final date = g['voucher_date'] != null
                            ? DateFormat('d MMM yyyy').format(DateTime.parse(g['voucher_date'] as String)) : '-';
                        return InkWell(
                          onTap: () => _openGrn(g),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(children: [
                              Expanded(flex: 2, child: Text(g['voucher_number'] as String? ?? '-',
                                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                              Expanded(flex: 2, child: Text(g['purchase_orders']?['voucher_number'] as String? ?? '-',
                                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                              Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 13))),
                              Expanded(flex: 3, child: Text(g['suppliers']?['name'] as String? ?? '-')),
                              Expanded(flex: 2, child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(color: _statusColor(status).withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                                child: Text(status[0].toUpperCase() + status.substring(1),
                                    style: TextStyle(color: _statusColor(status), fontSize: 12, fontWeight: FontWeight.w600)),
                              )),
                              const SizedBox(width: 48, child: Icon(Icons.chevron_right, color: AppTheme.textSecondary)),
                            ]),
                          ),
                        );
                      }),
            ),
          ]),
        )),
      ]),
    );
  }
}

// ─── GRN Detail ───────────────────────────────────────────────────────────────

class GrnDetailScreen extends ConsumerStatefulWidget {
  final String grnId;
  final VoidCallback onUpdated;
  const GrnDetailScreen({super.key, required this.grnId, required this.onUpdated});
  @override
  ConsumerState<GrnDetailScreen> createState() => _GrnDetailScreenState();
}

class _GrnDetailScreenState extends ConsumerState<GrnDetailScreen> {
  Map<String, dynamic> _grn = {};
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _poItems = [];
  VoucherMeta _meta = VoucherMeta();
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _canDelete {
    final role = ref.read(currentUserProvider)?.role;
    return role == WebUserRole.masterAdmin || role == WebUserRole.admin;
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final grn = await client.from('purchase_grns')
          .select('*, suppliers(name, address, contact_person, contact_number, phone, ntn), purchase_orders(voucher_number), branches(name)')
          .eq('id', widget.grnId).single();
      final items = await client.from('purchase_grn_items')
          .select('*, products(name, sku), uoms(abbreviation)')
          .eq('grn_id', widget.grnId);
      final poItems = await client.from('purchase_order_items')
          .select('*, products(name, sku), uoms(abbreviation)')
          .eq('purchase_order_id', grn['po_id'] as String);
      final meta = await VoucherMeta.fetch(
        orgId: _orgId ?? '',
        customerId: null,
        createdById: grn['created_by'] as String?,
      );
      setState(() {
        _grn = Map<String, dynamic>.from(grn);
        _items = List<Map<String, dynamic>>.from(items);
        _poItems = List<Map<String, dynamic>>.from(poItems);
        _meta = meta;
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  Future<void> _logAudit(String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'id': 'al_${DateTime.now().microsecondsSinceEpoch}',
        'voucher_id': widget.grnId, 'voucher_type': 'GRN',
        'action': action, 'details': details,
        'user_id': ref.read(currentUserProvider)?.id,
      });
    } catch (_) {}
  }

  Future<void> _deleteGRN() async {
    // Cascade: no PI exists
    try {
      final pis = await Supabase.instance.client.from('purchase_invoices')
          .select('id, voucher_number').eq('grn_id', widget.grnId);
      if ((pis as List).isNotEmpty) {
        _showSnack('Cannot delete: PI ${pis.first['voucher_number']} exists. Delete the invoice first.');
        return;
      }
    } catch (e) { _showSnack('Failed to check: $e'); return; }

    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete GRN?'),
      content: Text('Permanently delete ${_grn['voucher_number']}? Stock will be removed (reversal of received goods). This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete')),
      ],
    ));
    if (confirm != true) return;

    final orgId = _orgId;
    final branchId = _grn['branch_id'] as String;
    final userId = ref.read(currentUserProvider)?.id;
    try {
      for (final item in _items) {
        final pid = item['product_id'] as String;
        final received = (item['qty_received'] as num?)?.toDouble() ?? 0;
        if (received <= 0) continue;

        // Stock: subtract what was received
        final stock = await Supabase.instance.client.from('inventory_stock').select()
            .eq('org_id', orgId!).eq('product_id', pid).eq('branch_id', branchId).maybeSingle();
        if (stock != null) {
          await Supabase.instance.client.from('inventory_stock').update({
            'quantity': ((stock['quantity'] as num).toDouble()) - received,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', stock['id']);
        }
        // Movement: negative adjustment with reference
        await Supabase.instance.client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'org_id': orgId, 'product_id': pid, 'branch_id': branchId, 'uom_id': item['uom_id'],
          'quantity': -received, 'movement_type': 'adjustment',
          'reference_id': widget.grnId, 'reference_type': 'grn_deleted',
          'moved_at': DateTime.now().toUtc().toIso8601String(), 'created_by': userId,
        });

        // Restore PO item qty_received
        final poItemId = item['po_item_id'] as String?;
        if (poItemId != null) {
          final poItem = await Supabase.instance.client.from('purchase_order_items')
              .select('qty_received').eq('id', poItemId).single();
          await Supabase.instance.client.from('purchase_order_items').update({
            'qty_received': ((poItem['qty_received'] as num?)?.toDouble() ?? 0) - received,
          }).eq('id', poItemId);
        }
      }

      // Re-evaluate PO status
      final poId = _grn['po_id'] as String?;
      if (poId != null) {
        final remaining = await Supabase.instance.client.from('purchase_order_items')
            .select('quantity_ordered, qty_received').eq('purchase_order_id', poId);
        bool allRcvd = true; bool anyRcvd = false;
        for (final pi in remaining as List) {
          final ord = ((pi['quantity_ordered'] as num?)?.toDouble() ?? 0);
          final rcv = ((pi['qty_received'] as num?)?.toDouble() ?? 0);
          if (rcv > 0) anyRcvd = true;
          if (rcv < ord) allRcvd = false;
        }
        await Supabase.instance.client.from('purchase_orders').update({
          'status': allRcvd ? 'received' : (anyRcvd ? 'partially_received' : 'ordered'),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', poId);
      }

      final vNum = _grn['voucher_number'] as String? ?? '';
      final bankErr = await _bankCancelledVoucherNumber(
        orgId: orgId, branchId: branchId, voucherNumber: vNum);
      if (bankErr != null) _showSnack('Bank # failed: $bankErr');

      await _logAudit('deleted', 'Voucher $vNum deleted by admin, stock reversed');
      await Supabase.instance.client.from('purchase_grn_items').delete().eq('grn_id', widget.grnId);
      await Supabase.instance.client.from('purchase_grns').delete().eq('id', widget.grnId);

      _showSnack('Deleted — stock reversed');
      widget.onUpdated();
      if (mounted) Navigator.of(context).pop();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _printGRN() async {
    final user = ref.read(currentUserProvider);
    final lines = _items.map((it) {
      final qty = (it['qty_received'] as num?)?.toDouble() ?? 0;
      return VoucherLine(
        product: it['products']?['name'] as String? ?? '-',
        sku: it['products']?['sku'] as String?,
        uom: it['uoms']?['abbreviation'] as String?,
        qty: qty,
      );
    }).toList();
    final sup = _grn['suppliers'] as Map?;
    final date = _grn['voucher_date'] != null
        ? DateFormat('d MMM yyyy').format(DateTime.parse(_grn['voucher_date'] as String)) : null;
    final createdAt = _grn['created_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_grn['created_at'] as String).toLocal()) : null;
    final poVoucher = _grn['purchase_orders']?['voucher_number'] as String?;
    await VoucherPdf.printVoucher(
      voucherNumber: _grn['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Goods Receipt Note',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _grn['branches']?['name'] as String?,
      date: date,
      customerOrSupplier: sup?['name'] as String?,
      customerAddress: sup?['address'] as String?,
      customerContact: sup?['contact_person'] as String?,
      customerPhone: (sup?['contact_number'] ?? sup?['phone']) as String?,
      status: (_grn['status'] as String? ?? '').replaceAll('_', ' '),
      lines: lines,
      preparedBy: _meta.preparedBy,
      createdAt: createdAt,
      footerNote: _meta.footerNote,
      relatedRefs: poVoucher != null ? {'PO #': poVoucher} : null,
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  bool get _isLocked => _grn['is_locked'] as bool? ?? true;
  bool get _isSaved => (_grn['status'] as String? ?? 'saved') == 'saved';

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('purchase_grns').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.grnId);
      _showSnack(newLocked ? 'GRN locked' : 'GRN unlocked');
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  void _showAddItemsDialog() {
    final existingProductIds = _items.map((i) => i['product_id'] as String).toSet();
    final availableItems = _poItems.where((i) => !existingProductIds.contains(i['product_id'] as String)).toList();
    if (availableItems.isEmpty) { _showSnack('All PO items already added'); return; }
    final controllers = <String, TextEditingController>{};
    for (final item in availableItems) {
      final qty = (item['quantity_ordered'] as num?)?.toDouble() ?? 0;
      controllers[item['id'] as String] = TextEditingController(text: qty.toStringAsFixed(0));
    }
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add Received Items'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8)),
                child: const Row(children: [
                  Expanded(flex: 3, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text('PO Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text('Received *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.primary))),
                ]),
              ),
              const SizedBox(height: 8),
              ...availableItems.map((item) {
                final ordered = (item['quantity_ordered'] as num?)?.toDouble() ?? 0;
                final uomAbbr = item['uoms']?['abbreviation'] as String? ?? '';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  child: Row(children: [
                    Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(uomAbbr, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ])),
                    Expanded(flex: 2, child: Text('${ordered.toStringAsFixed(0)} $uomAbbr', style: const TextStyle(fontSize: 13))),
                    Expanded(flex: 2, child: SizedBox(height: 36, child: TextField(
                      controller: controllers[item['id'] as String],
                      decoration: const InputDecoration(isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          border: OutlineInputBorder()),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ))),
                  ]),
                );
              }),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              for (final item in availableItems) {
                final itemId = item['id'] as String;
                final receivedQty = double.tryParse(controllers[itemId]?.text.trim() ?? '0') ?? 0;
                final ordered = (item['quantity_ordered'] as num?)?.toDouble() ?? 0;
                if (receivedQty > ordered) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('${item['products']?['name']}: received qty exceeds ordered qty')));
                  return;
                }
              }
              try {
                final orgId = ref.read(currentUserProvider)?.orgId;
                final userId = ref.read(currentUserProvider)?.id;
                final branchId = _grn['branch_id'] as String;
                for (final item in availableItems) {
                  final itemId = item['id'] as String;
                  final receivedQty = double.tryParse(controllers[itemId]?.text.trim() ?? '0') ?? 0;
                  if (receivedQty <= 0) continue;
                  await Supabase.instance.client.from('purchase_grn_items').insert({
                    'id': 'grni_${DateTime.now().millisecondsSinceEpoch}_${item['product_id'].toString().substring(0, 4)}',
                    'grn_id': widget.grnId,
                    'po_item_id': itemId,
                    'product_id': item['product_id'],
                    'uom_id': item['uom_id'],
                    'qty_ordered': (item['quantity_ordered'] as num?)?.toDouble() ?? 0,
                    'qty_received': receivedQty,
                  });
                  final existing = await Supabase.instance.client.from('inventory_stock').select()
                      .eq('org_id', orgId!).eq('product_id', item['product_id'] as String)
                      .eq('branch_id', branchId).maybeSingle();
                  if (existing != null) {
                    await Supabase.instance.client.from('inventory_stock').update({
                      'quantity': (existing['quantity'] as num).toDouble() + receivedQty,
                      'updated_at': DateTime.now().toUtc().toIso8601String(),
                    }).eq('id', existing['id']);
                  } else {
                    await Supabase.instance.client.from('inventory_stock').insert({
                      'id': 'is_${DateTime.now().millisecondsSinceEpoch}',
                      'org_id': orgId, 'product_id': item['product_id'],
                      'branch_id': branchId, 'uom_id': item['uom_id'], 'quantity': receivedQty,
                    });
                  }
                  await Supabase.instance.client.from('inventory_movements').insert({
                    'id': 'im_${DateTime.now().millisecondsSinceEpoch}_${item['product_id'].toString().substring(0, 4)}',
                    'org_id': orgId, 'product_id': item['product_id'],
                    'branch_id': branchId, 'uom_id': item['uom_id'],
                    'quantity': receivedQty, 'movement_type': 'purchase',
                    'reference_id': widget.grnId, 'reference_type': 'purchase_grn',
                    'moved_at': DateTime.now().toUtc().toIso8601String(), 'created_by': userId,
                  });
                  final poItemRow = await Supabase.instance.client.from('purchase_order_items')
                      .select('qty_received').eq('id', itemId).single();
                  await Supabase.instance.client.from('purchase_order_items').update({
                    'qty_received': ((poItemRow['qty_received'] as num?)?.toDouble() ?? 0) + receivedQty,
                  }).eq('id', itemId);
                }
                // PO status from remaining qty (supports partial receipts across GRNs)
                final poId = _grn['po_id'] as String;
                final remRows = await Supabase.instance.client.from('purchase_order_items')
                    .select('quantity_ordered, qty_received').eq('purchase_order_id', poId);
                bool allRcvd = true; bool anyRcvd = false;
                for (final pi in remRows as List) {
                  final ord = ((pi['quantity_ordered'] as num?)?.toDouble() ?? 0);
                  final rcv = ((pi['qty_received'] as num?)?.toDouble() ?? 0);
                  if (rcv > 0) anyRcvd = true;
                  if (rcv < ord) allRcvd = false;
                }
                await Supabase.instance.client.from('purchase_orders').update({
                  'status': allRcvd ? 'received' : (anyRcvd ? 'partially_received' : 'ordered'),
                  'updated_at': DateTime.now().toUtc().toIso8601String(),
                }).eq('id', poId);
                if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
                _showSnack('Items received — stock updated');
                _load();
              } catch (e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
              }
            },
            child: const Text('Save Receipt'),
          ),
        ],
      ),
    );
  }

  Future<void> _createInvoice() async {
    if (_items.isEmpty) { _showSnack('No items to invoice'); return; }
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = _grn['branch_id'] as String;
    final userId = ref.read(currentUserProvider)?.id;
    final year = DateTime.now().year;
    try {
      final _vSeq = await Supabase.instance.client
          .rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'PI', 'p_year': year});
      final voucherNum = 'PI-$year-${_vSeq.toString().padLeft(4, '0')}';
      final piId = 'pi_${DateTime.now().millisecondsSinceEpoch}';
      double subtotal = 0;
      final piItems = _items.map((item) {
        final qty = (item['qty_received'] as num?)?.toDouble() ?? 0;
        final cost = (item['unit_cost'] as num?)?.toDouble() ?? 0;
        final lineTotal = qty * cost;
        subtotal += lineTotal;
        return {
          'id': 'pii_${DateTime.now().millisecondsSinceEpoch}_${item['product_id'].toString().substring(0, 4)}',
          'product_id': item['product_id'],
          'uom_id': item['uom_id'],
          'qty_received': qty,
          'unit_cost': cost,
          'discount': 0.0,
          'line_total': lineTotal,
        };
      }).toList();
      await Supabase.instance.client.from('purchase_invoices').insert({
        'id': piId, 'org_id': orgId, 'branch_id': branchId,
        'voucher_number': voucherNum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'po_id': _grn['po_id'], 'grn_id': widget.grnId,
        'supplier_id': _grn['supplier_id'],
        'subtotal': subtotal, 'discount_total': 0, 'grand_total': subtotal,
        'is_locked': true, 'created_by': userId,
      });
      for (final item in piItems) {
        await Supabase.instance.client.from('purchase_invoice_items').insert({...item, 'invoice_id': piId});
      }
      await Supabase.instance.client.from('purchase_grns').update({
        'status': 'invoiced', 'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.grnId);
      _showSnack('Purchase invoice $voucherNum created');
      widget.onUpdated();
      _load();
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PurchaseInvoiceDetailScreen(invoiceId: piId, onUpdated: () {}),
        ));
      }
    } catch (e) { _showSnack('Failed: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    final status = _grn['status'] as String? ?? 'saved';
    final isSavedNotInvoiced = status == 'saved';
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.white, elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_grn['voucher_number'] as String? ?? 'GRN',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text('PO: ${_grn['purchase_orders']?['voucher_number'] ?? '-'}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w400)),
        ]),
        actions: [
          if (isSavedNotInvoiced) ...[
            if (!_isLocked) ...[
              ElevatedButton(onPressed: _showAddItemsDialog, child: const Text('Add Items')),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _items.isNotEmpty ? _createInvoice : null, child: const Text('Create Invoice')),
              const SizedBox(width: 8),
            ],
            TextButton.icon(
              onPressed: _toggleLock,
              icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, size: 16),
              label: Text(_isLocked ? 'Unlock' : 'Lock'),
              style: TextButton.styleFrom(foregroundColor: _isLocked ? Colors.orange : AppTheme.textSecondary),
            ),
          ],
          if (status == 'invoiced')
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: AppTheme.success.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
              child: const Text('Invoiced', style: TextStyle(color: AppTheme.success, fontWeight: FontWeight.w600)),
            ),
          IconButton(
            icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary),
            tooltip: 'Print / PDF',
            onPressed: _printGRN,
          ),
          if (_canDelete)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
              tooltip: 'Delete',
              onPressed: _deleteGRN,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 12, runSpacing: 8, children: [
                  _InfoChip(label: 'Branch', value: _grn['branches']?['name'] as String? ?? '-'),
                  _InfoChip(label: 'Date', value: _grn['voucher_date'] != null
                      ? DateFormat('d MMM yyyy').format(DateTime.parse(_grn['voucher_date'] as String)) : '-'),
                  _InfoChip(label: 'Supplier', value: _grn['suppliers']?['name'] as String? ?? '-'),
                  if (_grn['remarks'] != null) _InfoChip(label: 'Remarks', value: _grn['remarks'] as String),
                  if (_isLocked) const _LockedChip(),
                ]),
                _VoucherInfoStrip(
                  supplierAddress: _grn['suppliers']?['address'] as String?,
                  supplierContact: _grn['suppliers']?['contact_person'] as String?,
                  supplierPhone: (_grn['suppliers']?['contact_number'] ?? _grn['suppliers']?['phone']) as String?,
                  ntn: _grn['suppliers']?['ntn'] as String?,
                  preparedBy: _meta.preparedBy,
                  createdAt: _grn['created_at'] != null
                      ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_grn['created_at'] as String).toLocal())
                      : null,
                ),
                const SizedBox(height: 24),
                const Text('Received Items', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                Expanded(child: Container(
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
                  child: Column(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                      child: const Row(children: [
                        Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('PO Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Received', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _items.isEmpty
                          ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              const Text('No items yet.', style: TextStyle(color: AppTheme.textSecondary)),
                              if (!_isLocked && isSavedNotInvoiced) ...[
                                const SizedBox(height: 8),
                                ElevatedButton(onPressed: _showAddItemsDialog, child: const Text('Add from PO')),
                              ],
                            ]))
                          : ListView.separated(
                              itemCount: _items.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final item = _items[i];
                                final ordered = (item['qty_ordered'] as num?)?.toDouble() ?? 0;
                                final received = (item['qty_received'] as num?)?.toDouble() ?? 0;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  child: Row(children: [
                                    Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                                      if (item['products']?['sku'] != null)
                                        Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                    ])),
                                    Expanded(flex: 2, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary))),
                                    Expanded(flex: 2, child: Text(ordered.toStringAsFixed(0), style: const TextStyle(fontWeight: FontWeight.w600))),
                                    Expanded(flex: 2, child: Text(received.toStringAsFixed(0),
                                        style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.success))),
                                  ]),
                                );
                              }),
                    ),
                  ]),
                )),
                const SizedBox(height: 12),
                _AuditTrail(createdBy: _grn['created_by'] as String?, createdAt: _grn['created_at'] as String?),
              ]),
            ),
    );
  }
}

// ─── Purchase Invoices List ───────────────────────────────────────────────────

class ErpPurchaseInvoicesScreen extends ConsumerStatefulWidget {
  const ErpPurchaseInvoicesScreen({super.key});
  @override
  ConsumerState<ErpPurchaseInvoicesScreen> createState() => _ErpPurchaseInvoicesScreenState();
}

class _ErpPurchaseInvoicesScreenState extends ConsumerState<ErpPurchaseInvoicesScreen> {
  List<Map<String, dynamic>> _invoices = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final branchId = ref.read(selectedBranchProvider)?['id'] as String?;
      var query = Supabase.instance.client
          .from('purchase_invoices')
          .select('*, suppliers(name), purchase_orders(voucher_number), purchase_grns(voucher_number)')
          .eq('org_id', orgId);
      if (branchId != null) query = query.eq('branch_id', branchId);
      final res = await query.order('created_at', ascending: false);
      setState(() {
        _invoices = List<Map<String, dynamic>>.from(res);
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Purchase Invoices', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text('${_invoices.length} invoices', style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 24),
        if (_loading) const Center(child: CircularProgressIndicator())
        else Expanded(child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
              child: const Row(children: [
                Expanded(flex: 2, child: Text('PI #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('PO #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('GRN #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Supplier', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                SizedBox(width: 48),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _invoices.isEmpty
                  ? const Center(child: Text('No purchase invoices yet.', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      itemCount: _invoices.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final inv = _invoices[i];
                        final date = inv['voucher_date'] != null
                            ? DateFormat('d MMM yyyy').format(DateTime.parse(inv['voucher_date'] as String)) : '-';
                        return InkWell(
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => PurchaseInvoiceDetailScreen(invoiceId: inv['id'] as String, onUpdated: _load))),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(children: [
                              Expanded(flex: 2, child: Text(inv['voucher_number'] as String? ?? '-',
                                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                              Expanded(flex: 2, child: Text(inv['purchase_orders']?['voucher_number'] as String? ?? '-',
                                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                              Expanded(flex: 2, child: Text(inv['purchase_grns']?['voucher_number'] as String? ?? '-',
                                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                              Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 13))),
                              Expanded(flex: 2, child: Text(inv['suppliers']?['name'] as String? ?? '-')),
                              Expanded(flex: 2, child: Text((inv['grand_total'] as num?)?.toStringAsFixed(2) ?? '0',
                                  style: const TextStyle(fontWeight: FontWeight.w700))),
                              const SizedBox(width: 48, child: Icon(Icons.chevron_right, color: AppTheme.textSecondary)),
                            ]),
                          ),
                        );
                      }),
            ),
          ]),
        )),
      ]),
    );
  }
}

// ─── Purchase Invoice Detail ──────────────────────────────────────────────────

class PurchaseInvoiceDetailScreen extends ConsumerStatefulWidget {
  final String invoiceId;
  final VoidCallback onUpdated;
  const PurchaseInvoiceDetailScreen({super.key, required this.invoiceId, required this.onUpdated});
  @override
  ConsumerState<PurchaseInvoiceDetailScreen> createState() => _PurchaseInvoiceDetailScreenState();
}

class _PurchaseInvoiceDetailScreenState extends ConsumerState<PurchaseInvoiceDetailScreen> {
  Map<String, dynamic> _invoice = {};
  List<Map<String, dynamic>> _items = [];
  VoucherMeta _meta = VoucherMeta();
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _canDelete {
    final role = ref.read(currentUserProvider)?.role;
    return role == WebUserRole.masterAdmin || role == WebUserRole.admin;
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final invoice = await client.from('purchase_invoices')
          .select('*, suppliers(name, address, contact_person, contact_number, phone, ntn), purchase_orders(voucher_number), purchase_grns(voucher_number), branches(name)')
          .eq('id', widget.invoiceId).single();
      final items = await client.from('purchase_invoice_items')
          .select('*, products(name, sku), uoms(abbreviation)')
          .eq('invoice_id', widget.invoiceId);
      final meta = await VoucherMeta.fetch(
        orgId: _orgId ?? '',
        customerId: null,
        createdById: invoice['created_by'] as String?,
      );
      setState(() {
        _invoice = Map<String, dynamic>.from(invoice);
        _items = List<Map<String, dynamic>>.from(items);
        _meta = meta;
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  Future<void> _logAudit(String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'id': 'al_${DateTime.now().microsecondsSinceEpoch}',
        'voucher_id': widget.invoiceId, 'voucher_type': 'PI',
        'action': action, 'details': details,
        'user_id': ref.read(currentUserProvider)?.id,
      });
    } catch (_) {}
  }

  Future<void> _deletePI() async {
    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete Purchase Invoice?'),
      content: Text('Permanently delete ${_invoice['voucher_number']}? The GRN will be available for re-invoicing. This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete')),
      ],
    ));
    if (confirm != true) return;

    try {
      final vNum = _invoice['voucher_number'] as String? ?? '';
      final grnId = _invoice['grn_id'] as String?;

      await _logAudit('deleted', 'Voucher $vNum deleted by admin');
      await Supabase.instance.client.from('purchase_invoice_items').delete().eq('invoice_id', widget.invoiceId);
      await Supabase.instance.client.from('purchase_invoices').delete().eq('id', widget.invoiceId);

      // Revert GRN status from 'invoiced' to 'saved' so a new invoice can be created
      if (grnId != null) {
        await Supabase.instance.client.from('purchase_grns').update({
          'status': 'saved',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', grnId);
      }

      final bankErr = await _bankCancelledVoucherNumber(
        orgId: _orgId, branchId: _invoice['branch_id'] as String?, voucherNumber: vNum);
      if (bankErr != null) _showSnack('Bank # failed: $bankErr');

      _showSnack('Deleted — GRN restored to saved');
      if (mounted) Navigator.of(context).pop();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _printPI() async {
    final user = ref.read(currentUserProvider);
    final lines = _items.map((it) {
      final qty = (it['qty_received'] as num?)?.toDouble() ?? 0;
      final cost = (it['unit_cost'] as num?)?.toDouble() ?? 0;
      final disc = (it['discount'] as num?)?.toDouble() ?? 0;
      final lt = (it['line_total'] as num?)?.toDouble() ?? qty * cost - disc;
      return VoucherLine(
        product: it['products']?['name'] as String? ?? '-',
        sku: it['products']?['sku'] as String?,
        uom: it['uoms']?['abbreviation'] as String?,
        qty: qty, unitPrice: cost, lineTotal: lt,
      );
    }).toList();
    final sup = _invoice['suppliers'] as Map?;
    final date = _invoice['voucher_date'] != null
        ? DateFormat('d MMM yyyy').format(DateTime.parse(_invoice['voucher_date'] as String)) : null;
    final createdAt = _invoice['created_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_invoice['created_at'] as String).toLocal()) : null;
    final poVoucher = _invoice['purchase_orders']?['voucher_number'] as String?;
    final grnVoucher = _invoice['purchase_grns']?['voucher_number'] as String?;
    final refs = <String, String>{};
    if (poVoucher != null) refs['PO #'] = poVoucher;
    if (grnVoucher != null) refs['GRN #'] = grnVoucher;

    await VoucherPdf.printVoucher(
      voucherNumber: _invoice['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Purchase Invoice',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _invoice['branches']?['name'] as String?,
      date: date,
      customerOrSupplier: sup?['name'] as String?,
      customerAddress: sup?['address'] as String?,
      customerContact: sup?['contact_person'] as String?,
      customerPhone: (sup?['contact_number'] ?? sup?['phone']) as String?,
      lines: lines,
      subtotal: (_invoice['subtotal'] as num?)?.toDouble() ?? 0,
      discountTotal: (_invoice['discount_total'] as num?)?.toDouble() ?? 0,
      grandTotal: (_invoice['grand_total'] as num?)?.toDouble() ?? 0,
      preparedBy: _meta.preparedBy,
      createdAt: createdAt,
      footerNote: _meta.footerNote,
      relatedRefs: refs.isNotEmpty ? refs : null,
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  bool get _isLocked => _invoice['is_locked'] as bool? ?? true;

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('purchase_invoices').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
      }).eq('id', widget.invoiceId);
      _showSnack(newLocked ? 'Invoice locked' : 'Invoice unlocked');
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _saveDiscounts(Map<String, double> discounts) async {
    try {
      double subtotal = 0, discountTotal = 0;
      for (final item in _items) {
        final qty = (item['qty_received'] as num?)?.toDouble() ?? 0;
        final cost = (item['unit_cost'] as num?)?.toDouble() ?? 0;
        final disc = discounts[item['id'] as String] ?? (item['discount'] as num?)?.toDouble() ?? 0;
        final lineTotal = (qty * cost) - disc;
        subtotal += qty * cost;
        discountTotal += disc;
        await Supabase.instance.client.from('purchase_invoice_items').update({
          'discount': disc, 'line_total': lineTotal,
        }).eq('id', item['id']);
      }
      await Supabase.instance.client.from('purchase_invoices').update({
        'subtotal': subtotal, 'discount_total': discountTotal,
        'grand_total': subtotal - discountTotal,
      }).eq('id', widget.invoiceId);
      _showSnack('Invoice updated');
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    final discountControllers = <String, TextEditingController>{};
    for (final item in _items) {
      discountControllers[item['id'] as String] = TextEditingController(
          text: (item['discount'] as num?)?.toStringAsFixed(2) ?? '0');
    }
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.white, elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_invoice['voucher_number'] as String? ?? 'Purchase Invoice',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text(_invoice['suppliers']?['name'] as String? ?? '-',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w400)),
        ]),
        actions: [
          if (!_isLocked)
            ElevatedButton(
              onPressed: () {
                final discounts = <String, double>{};
                for (final item in _items) {
                  discounts[item['id'] as String] = double.tryParse(
                      discountControllers[item['id'] as String]?.text.trim() ?? '0') ?? 0;
                }
                _saveDiscounts(discounts);
              },
              child: const Text('Save'),
            ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _toggleLock,
            icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, size: 16),
            label: Text(_isLocked ? 'Unlock' : 'Lock'),
            style: TextButton.styleFrom(foregroundColor: _isLocked ? Colors.orange : AppTheme.textSecondary),
          ),
          IconButton(
            icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary),
            tooltip: 'Print / PDF',
            onPressed: _printPI,
          ),
          if (_canDelete)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
              tooltip: 'Delete',
              onPressed: _deletePI,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 12, runSpacing: 8, children: [
                  _InfoChip(label: 'Branch', value: _invoice['branches']?['name'] as String? ?? '-'),
                  _InfoChip(label: 'Date', value: _invoice['voucher_date'] != null
                      ? DateFormat('d MMM yyyy').format(DateTime.parse(_invoice['voucher_date'] as String)) : '-'),
                  _InfoChip(label: 'PO #', value: _invoice['purchase_orders']?['voucher_number'] as String? ?? '-'),
                  _InfoChip(label: 'GRN #', value: _invoice['purchase_grns']?['voucher_number'] as String? ?? '-'),
                  if (_isLocked) const _LockedChip(),
                ]),
                _VoucherInfoStrip(
                  supplierAddress: _invoice['suppliers']?['address'] as String?,
                  supplierContact: _invoice['suppliers']?['contact_person'] as String?,
                  supplierPhone: (_invoice['suppliers']?['contact_number'] ?? _invoice['suppliers']?['phone']) as String?,
                  ntn: _invoice['suppliers']?['ntn'] as String?,
                  preparedBy: _meta.preparedBy,
                  createdAt: _invoice['created_at'] != null
                      ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_invoice['created_at'] as String).toLocal())
                      : null,
                ),
                const SizedBox(height: 24),
                Expanded(child: Container(
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
                  child: Column(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                      child: const Row(children: [
                        Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Unit Cost', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Discount', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Line Total', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _items.isEmpty
                          ? const Center(child: Text('No items.', style: TextStyle(color: AppTheme.textSecondary)))
                          : ListView.separated(
                              itemCount: _items.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final item = _items[i];
                                final qty = (item['qty_received'] as num?)?.toDouble() ?? 0;
                                final cost = (item['unit_cost'] as num?)?.toDouble() ?? 0;
                                final disc = double.tryParse(discountControllers[item['id'] as String]?.text ?? '0') ?? 0;
                                final lineTotal = (qty * cost) - disc;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                  child: Row(children: [
                                    Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                                      if (item['products']?['sku'] != null)
                                        Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                    ])),
                                    Expanded(flex: 1, child: Text(item['uoms']?['abbreviation'] as String? ?? '-',
                                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                                    Expanded(flex: 2, child: Text(qty.toStringAsFixed(0), style: const TextStyle(fontWeight: FontWeight.w600))),
                                    Expanded(flex: 2, child: Text(cost.toStringAsFixed(2))),
                                    Expanded(flex: 2, child: _isLocked
                                        ? Text(disc.toStringAsFixed(2))
                                        : SizedBox(height: 32, child: TextField(
                                            controller: discountControllers[item['id'] as String],
                                            decoration: const InputDecoration(isDense: true,
                                                contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                                border: OutlineInputBorder()),
                                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                          ))),
                                    Expanded(flex: 2, child: Text(lineTotal.toStringAsFixed(2),
                                        style: const TextStyle(fontWeight: FontWeight.w700))),
                                  ]),
                                );
                              }),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        _TotalRow(label: 'Subtotal', value: (_invoice['subtotal'] as num?)?.toStringAsFixed(2) ?? '0'),
                        _TotalRow(label: 'Discount', value: '- ${(_invoice['discount_total'] as num?)?.toStringAsFixed(2) ?? '0'}'),
                        const Divider(),
                        _TotalRow(label: 'Grand Total', value: (_invoice['grand_total'] as num?)?.toStringAsFixed(2) ?? '0', bold: true),
                      ]),
                    ),
                  ]),
                )),
                const SizedBox(height: 12),
                _AuditTrail(createdBy: _invoice['created_by'] as String?, createdAt: _invoice['created_at'] as String?),
              ]),
            ),
    );
  }
}

// ─── Shared Widgets ───────────────────────────────────────────────────────────

class _InfoChip extends StatelessWidget {
  final String label;
  final String value;
  const _InfoChip({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
    ]),
  );
}

class _LockedChip extends StatelessWidget {
  const _LockedChip();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange.withOpacity(0.3))),
    child: const Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.lock_outline, size: 14, color: Colors.orange),
      SizedBox(width: 4),
      Text('Locked', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w600, fontSize: 13)),
    ]),
  );
}

class _AuditTrail extends ConsumerWidget {
  final String? createdBy;
  final String? createdAt;
  const _AuditTrail({this.createdBy, this.createdAt});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (createdBy == null && createdAt == null) return const SizedBox.shrink();
    return FutureBuilder<String>(
      future: _resolveUserName(createdBy),
      builder: (_, snap) {
        final name = snap.data ?? createdBy ?? '-';
        final date = createdAt != null
            ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(createdAt!).toLocal()) : '-';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Row(children: [
            const Icon(Icons.history, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 8),
            Text('Created by $name on $date', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
        );
      },
    );
  }
  Future<String> _resolveUserName(String? userId) async {
    if (userId == null) return '-';
    try {
      final res = await Supabase.instance.client.from('users').select('name').eq('id', userId).maybeSingle();
      return res?['name'] as String? ?? userId;
    } catch (_) { return userId; }
  }
}

class _TotalRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  const _TotalRow({required this.label, required this.value, this.bold = false});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label: ', style: TextStyle(fontSize: bold ? 15 : 13, color: AppTheme.textSecondary, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
      Text(value, style: TextStyle(fontSize: bold ? 16 : 13, fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
    ]),
  );
}

// ─── Shared helpers (mirrored from erp_sales_screen.dart) ─────────────────────

/// Returns null on success OR when there's nothing meaningful to bank (e.g.
/// legacy numeric-only voucher numbers from before the TYPE-YYYY-NNNN scheme).
/// Returns a human-readable failure reason for actual DB errors so the caller
/// can surface it in a snack.
Future<String?> _bankCancelledVoucherNumber({
  required String? orgId,
  required String? branchId,
  required String voucherNumber,
}) async {
  if (orgId == null || orgId.isEmpty) return 'org missing';
  if (voucherNumber.isEmpty) return null;
  final parts = voucherNumber.split('-');
  if (parts.length != 3) {
    // ignore: avoid_print
    print('[VoucherBank] $voucherNumber is legacy format, skipping');
    return null;
  }
  final year = int.tryParse(parts[1]);
  final number = int.tryParse(parts[2]);
  if (year == null || number == null) {
    // ignore: avoid_print
    print('[VoucherBank] $voucherNumber not numeric, skipping');
    return null;
  }
  try {
    await Supabase.instance.client.from('voucher_cancelled_numbers').insert({
      'id': 'cancel_${DateTime.now().millisecondsSinceEpoch}',
      'org_id': orgId,
      'branch_id': branchId,
      'voucher_type': parts[0],
      'year': year,
      'number': number,
    });
    // ignore: avoid_print
    print('[VoucherBank] $voucherNumber banked for reuse');
    return null;
  } catch (e) {
    // ignore: avoid_print
    print('[VoucherBank] failed to bank $voucherNumber: $e');
    return e.toString().split('\n').first;
  }
}

/// Compact info strip showing supplier details + prepared-by on detail screens.
class _VoucherInfoStrip extends StatelessWidget {
  final String? supplierAddress;
  final String? supplierContact;
  final String? supplierPhone;
  final String? ntn;
  final String? preparedBy;
  final String? createdAt;

  const _VoucherInfoStrip({
    this.supplierAddress,
    this.supplierContact,
    this.supplierPhone,
    this.ntn,
    this.preparedBy,
    this.createdAt,
  });

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[];
    if (supplierAddress != null && supplierAddress!.trim().isNotEmpty) {
      tiles.add(_tile(Icons.location_on_outlined, 'Address', supplierAddress!));
    }
    if (supplierContact != null && supplierContact!.isNotEmpty) {
      tiles.add(_tile(Icons.account_circle_outlined, 'Contact Person', supplierContact!));
    }
    if (supplierPhone != null && supplierPhone!.isNotEmpty) {
      tiles.add(_tile(Icons.phone_outlined, 'Phone', supplierPhone!));
    }
    if (ntn != null && ntn!.isNotEmpty) {
      tiles.add(_tile(Icons.badge_outlined, 'NTN', ntn!));
    }
    if (tiles.isEmpty && (preparedBy == null || preparedBy!.isEmpty)) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.background,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (tiles.isNotEmpty) Wrap(spacing: 24, runSpacing: 8, children: tiles),
        if (preparedBy != null && preparedBy!.isNotEmpty) ...[
          if (tiles.isNotEmpty) const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.draw_outlined, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(
              'Prepared by: ${preparedBy!}${createdAt != null ? "  ·  $createdAt" : ""}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontStyle: FontStyle.italic),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _tile(IconData icon, String label, String value) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
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

/// Audit trail viewer (mirrors sales).
class _AuditTrailList extends StatelessWidget {
  final String voucherId;
  final String voucherType;
  const _AuditTrailList({required this.voucherId, required this.voucherType});
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      future: Supabase.instance.client.from('voucher_audit_log')
          .select('*, users(name)').eq('voucher_id', voucherId).eq('voucher_type', voucherType)
          .order('performed_at', ascending: false).limit(50),
      builder: (ctx, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final entries = List<Map<String, dynamic>>.from(snap.data!);
        if (entries.isEmpty) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(top: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: AppTheme.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Audit Trail',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary, letterSpacing: 0.6)),
            const SizedBox(height: 8),
            ...entries.map((e) {
              final action = e['action'] as String? ?? '-';
              final details = e['details'] as String? ?? '';
              final userName = e['users']?['name'] as String? ?? '—';
              final ts = e['performed_at'] != null
                  ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(e['performed_at'] as String).toLocal()) : '';
              IconData icon;
              Color color;
              switch (action) {
                case 'created':   icon = Icons.add_circle_outline;   color = AppTheme.success; break;
                case 'saved':     icon = Icons.save_outlined;        color = AppTheme.primary; break;
                case 'confirmed': icon = Icons.check_circle_outline; color = AppTheme.success; break;
                case 'locked':    icon = Icons.lock_outline;         color = Colors.orange; break;
                case 'unlocked':  icon = Icons.lock_open;            color = AppTheme.textSecondary; break;
                case 'invoiced':  icon = Icons.receipt_long_outlined; color = AppTheme.primary; break;
                case 'cancelled': icon = Icons.cancel_outlined;      color = AppTheme.danger; break;
                case 'deleted':   icon = Icons.delete_outline;       color = AppTheme.danger; break;
                default:          icon = Icons.history;              color = AppTheme.textSecondary;
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: 8),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(action, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: color)),
                      const SizedBox(width: 8),
                      Text('by $userName', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      const Spacer(),
                      Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ]),
                    if (details.isNotEmpty) Text(details, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ])),
                ]),
              );
            }),
          ]),
        );
      },
    );
  }
}
