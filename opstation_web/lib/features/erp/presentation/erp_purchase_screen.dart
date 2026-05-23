import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

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
      case 'ordered': return Colors.blue;
      case 'received': return AppTheme.success;
      case 'cancelled': return AppTheme.danger;
      default: return AppTheme.textSecondary;
    }
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
                  final voucherNum = await Supabase.instance.client
                      .rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_type': 'PO', 'p_year': year});
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
            DropdownMenuItem(value: 'ordered', child: Text('Ordered')),
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
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _uoms = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    try {
      final client = Supabase.instance.client;
      final order = await client.from('purchase_orders')
          .select('*, suppliers(name), branches(name)').eq('id', widget.orderId).single();
      final items = await client.from('purchase_order_items')
          .select('*, products(name, sku), uoms(abbreviation)').eq('purchase_order_id', widget.orderId);
      final products = await client.from('products')
          .select('id, name, sku, base_uom_id, cost_price').eq('org_id', orgId!).eq('is_active', true).order('name');
      final uoms = await client.from('uoms').select().eq('org_id', orgId).order('name');
      setState(() {
        _order = Map<String, dynamic>.from(order);
        _items = List<Map<String, dynamic>>.from(items);
        _products = List<Map<String, dynamic>>.from(products);
        _uoms = List<Map<String, dynamic>>.from(uoms);
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  bool get _isDraft => (_order['status'] as String? ?? 'draft') == 'draft';
  bool get _isLocked => _order['is_locked'] as bool? ?? false;
  bool get _canEdit => _isDraft && !_isLocked;

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
          if (status == 'ordered')
            TextButton.icon(
              onPressed: _toggleLock,
              icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, size: 16),
              label: Text(_isLocked ? 'Unlock' : 'Lock'),
              style: TextButton.styleFrom(foregroundColor: _isLocked ? Colors.orange : AppTheme.textSecondary),
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
                  _InfoChip(label: 'Status', value: status[0].toUpperCase() + status.substring(1)),
                  if (_order['remarks'] != null) _InfoChip(label: 'Remarks', value: _order['remarks'] as String),
                  if (_isLocked) const _LockedChip(),
                ]),
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
                                    Expanded(flex: 2, child: Text(qty.toStringAsFixed(0), style: const TextStyle(fontWeight: FontWeight.w600))),
                                    Expanded(flex: 2, child: Text(cost.toStringAsFixed(2))),
                                    Expanded(flex: 2, child: Text((qty * cost).toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.w600))),
                                    SizedBox(width: 48, child: _canEdit
                                        ? IconButton(
                                            icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                                            onPressed: () async {
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
    var poQuery = Supabase.instance.client
        .from('purchase_orders')
        .select('id, voucher_number, supplier_id, suppliers(name)')
        .eq('org_id', orgId).eq('status', 'ordered');
    final pos = await poQuery.eq('branch_id', branchId);
    if (!mounted) return;
    if ((pos as List).isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No ordered POs available')));
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
              items: pos.map((p) => DropdownMenuItem(
                  value: p['id'] as String,
                  child: Text('${p['voucher_number']} — ${p['suppliers']?['name'] ?? '-'}'))).toList(),
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
                  final voucherNum = await Supabase.instance.client
                      .rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_type': 'GRN', 'p_year': year});
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
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final grn = await client.from('purchase_grns')
          .select('*, suppliers(name), purchase_orders(voucher_number), branches(name)')
          .eq('id', widget.grnId).single();
      final items = await client.from('purchase_grn_items')
          .select('*, products(name, sku), uoms(abbreviation)')
          .eq('grn_id', widget.grnId);
      final poItems = await client.from('purchase_order_items')
          .select('*, products(name, sku), uoms(abbreviation)')
          .eq('purchase_order_id', grn['po_id'] as String);
      setState(() {
        _grn = Map<String, dynamic>.from(grn);
        _items = List<Map<String, dynamic>>.from(items);
        _poItems = List<Map<String, dynamic>>.from(poItems);
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
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
                  await Supabase.instance.client.from('purchase_order_items').update({
                    'quantity_received': receivedQty,
                  }).eq('id', itemId);
                }
                await Supabase.instance.client.from('purchase_orders').update({
                  'status': 'received', 'updated_at': DateTime.now().toUtc().toIso8601String(),
                }).eq('id', _grn['po_id'] as String);
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
      final voucherNum = await Supabase.instance.client
          .rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_type': 'PI', 'p_year': year});
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
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final invoice = await client.from('purchase_invoices')
          .select('*, suppliers(name), purchase_orders(voucher_number), purchase_grns(voucher_number), branches(name)')
          .eq('id', widget.invoiceId).single();
      final items = await client.from('purchase_invoice_items')
          .select('*, products(name, sku), uoms(abbreviation)')
          .eq('invoice_id', widget.invoiceId);
      setState(() {
        _invoice = Map<String, dynamic>.from(invoice);
        _items = List<Map<String, dynamic>>.from(items);
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
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
