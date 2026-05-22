import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

// ─── Sales Order List ────────────────────────────────────────────────────────

class ErpSalesScreen extends ConsumerStatefulWidget {
  const ErpSalesScreen({super.key});
  @override
  ConsumerState<ErpSalesScreen> createState() => _ErpSalesScreenState();
}

class _ErpSalesScreenState extends ConsumerState<ErpSalesScreen> {
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
          .from('sales_orders')
          .select('*, customers(shop_name, code), branches(name)')
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
      case 'confirmed': return Colors.blue;
      case 'partially_delivered': return Colors.orange;
      case 'delivered': return AppTheme.success;
      case 'cancelled': return AppTheme.danger;
      default: return AppTheme.textSecondary;
    }
  }

  void _openOrder(Map<String, dynamic> order) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SalesOrderDetailScreen(orderId: order['id'] as String, onUpdated: _load),
    ));
  }

  void _showCreateDialog() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = ref.read(selectedBranchProvider)?['id'] as String?;
    if (orgId == null || branchId == null) {
      _showSnack('Select a branch first');
      return;
    }
    final customers = await Supabase.instance.client
        .from('customers').select('id, shop_name, code')
        .eq('org_id', orgId).eq('is_active', true).order('shop_name');
    if (!mounted) return;
    String? customerId;
    final remarksCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('New Sales Order'),
          content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: customerId,
              decoration: const InputDecoration(labelText: 'Customer (optional)'),
              hint: const Text('Walk-in / select customer'),
              items: (customers as List).map((c) => DropdownMenuItem(
                  value: c['id'] as String,
                  child: Text('${c['shop_name']} (${c['code']})'))).toList(),
              onChanged: (v) => setS(() => customerId = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: remarksCtrl, decoration: const InputDecoration(labelText: 'Remarks'), maxLines: 2),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final userId = ref.read(currentUserProvider)?.id;
                final year = DateTime.now().year;
                try {
                  final voucherNum = await Supabase.instance.client
                      .rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_type': 'SO', 'p_year': year});
                  final id = 'so_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client.from('sales_orders').insert({
                    'id': id, 'org_id': orgId, 'branch_id': branchId,
                    'voucher_number': voucherNum,
                    'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
                    'customer_id': customerId,
                    'remarks': remarksCtrl.text.trim().isEmpty ? null : remarksCtrl.text.trim(),
                    'status': 'draft',
                    'is_locked': false,
                    'created_by': userId,
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack('Sales order created');
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
          const Text('Sales Orders', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(onPressed: _showCreateDialog, icon: const Icon(Icons.add, size: 18), label: const Text('New Sales Order')),
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
            DropdownMenuItem(value: 'confirmed', child: Text('Confirmed')),
            DropdownMenuItem(value: 'partially_delivered', child: Text('Partially Delivered')),
            DropdownMenuItem(value: 'delivered', child: Text('Delivered')),
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
                Expanded(flex: 2, child: Text('Voucher #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 3, child: Text('Customer', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                SizedBox(width: 48),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _filtered.isEmpty
                  ? const Center(child: Text('No sales orders yet.', style: TextStyle(color: AppTheme.textSecondary)))
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
                              Expanded(flex: 3, child: Text(
                                  o['customers']?['shop_name'] as String? ?? 'Walk-in',
                                  style: const TextStyle(fontWeight: FontWeight.w500))),
                              Expanded(flex: 2, child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(color: _statusColor(status).withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                                child: Text(status.replaceAll('_', ' '),
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

// ─── Sales Order Detail ───────────────────────────────────────────────────────

class SalesOrderDetailScreen extends ConsumerStatefulWidget {
  final String orderId;
  final VoidCallback onUpdated;
  const SalesOrderDetailScreen({super.key, required this.orderId, required this.onUpdated});
  @override
  ConsumerState<SalesOrderDetailScreen> createState() => _SalesOrderDetailScreenState();
}

class _SalesOrderDetailScreenState extends ConsumerState<SalesOrderDetailScreen> {
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
      final order = await client.from('sales_orders')
          .select('*, customers(shop_name, code), branches(name)')
          .eq('id', widget.orderId).single();
      final items = await client.from('sales_order_items')
          .select('*, products(name, sku), uoms(name, abbreviation)')
          .eq('sales_order_id', widget.orderId);
      final products = await client.from('products')
          .select('id, name, sku, base_uom_id, selling_price')
          .eq('org_id', orgId!).eq('is_active', true).order('name');
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
            TextField(controller: qtyCtrl, decoration: const InputDecoration(labelText: 'Quantity *'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true)),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (productId == null || uomId == null) return;
                final qty = double.tryParse(qtyCtrl.text.trim()) ?? 0;
                if (qty <= 0) return;
                try {
                  await Supabase.instance.client.from('sales_order_items').insert({
                    'id': 'soi_${DateTime.now().millisecondsSinceEpoch}',
                    'sales_order_id': widget.orderId,
                    'product_id': productId, 'uom_id': uomId,
                    'quantity': qty, 'unit_price': 0, 'discount': 0, 'qty_delivered': 0,
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

  Future<void> _confirmOrder() async {
    if (_items.isEmpty) { _showSnack('Add items before confirming'); return; }
    try {
      await Supabase.instance.client.from('sales_orders').update({
        'status': 'confirmed',
        'is_locked': true,
        'locked_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.orderId);
      _showSnack('Order confirmed and locked');
      widget.onUpdated();
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _cancelOrder() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel Order'),
        content: const Text('Are you sure?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('No')),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Cancel Order')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client.from('sales_orders').update({
        'status': 'cancelled', 'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.orderId);
      _showSnack('Order cancelled');
      widget.onUpdated();
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('sales_orders').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.orderId);
      _showSnack(newLocked ? 'Order locked' : 'Order unlocked');
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    final status = _order['status'] as String? ?? 'draft';
    final createdBy = _order['created_by'] as String?;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.white, elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_order['voucher_number'] as String? ?? 'Sales Order',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text(_order['customers']?['shop_name'] as String? ?? 'Walk-in',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w400)),
        ]),
        actions: [
          if (_isDraft) ...[
            if (_isLocked)
              TextButton.icon(onPressed: _toggleLock, icon: const Icon(Icons.lock_open, size: 16),
                  label: const Text('Unlock'), style: TextButton.styleFrom(foregroundColor: Colors.orange))
            else ...[
              ElevatedButton(onPressed: _confirmOrder, child: const Text('Confirm Order')),
              const SizedBox(width: 8),
              TextButton(onPressed: _cancelOrder,
                  style: TextButton.styleFrom(foregroundColor: AppTheme.danger), child: const Text('Cancel')),
            ],
          ],
          if (!_isDraft && status != 'cancelled')
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
                // Info chips
                Wrap(spacing: 12, runSpacing: 8, children: [
                  _InfoChip(label: 'Branch', value: _order['branches']?['name'] as String? ?? '-'),
                  _InfoChip(label: 'Date', value: _order['voucher_date'] != null
                      ? DateFormat('d MMM yyyy').format(DateTime.parse(_order['voucher_date'] as String)) : '-'),
                  _InfoChip(label: 'Status', value: status.replaceAll('_', ' ')),
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
                        Expanded(flex: 2, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Qty Ordered', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Qty Delivered', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
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
                                final qty = (item['quantity'] as num?)?.toDouble() ?? 0;
                                final delivered = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  child: Row(children: [
                                    Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                                      if (item['products']?['sku'] != null)
                                        Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                    ])),
                                    Expanded(flex: 2, child: Text(item['uoms']?['abbreviation'] as String? ?? '-',
                                        style: const TextStyle(color: AppTheme.textSecondary))),
                                    Expanded(flex: 2, child: Text(qty % 1 == 0 ? qty.toInt().toString() : qty.toString(),
                                        style: const TextStyle(fontWeight: FontWeight.w600))),
                                    Expanded(flex: 2, child: Text(delivered % 1 == 0 ? delivered.toInt().toString() : delivered.toString(),
                                        style: TextStyle(fontWeight: FontWeight.w600,
                                            color: delivered >= qty ? AppTheme.success : AppTheme.textSecondary))),
                                    SizedBox(width: 48, child: _canEdit
                                        ? IconButton(
                                            icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                                            onPressed: () async {
                                              await Supabase.instance.client.from('sales_order_items').delete().eq('id', item['id']);
                                              _load();
                                            })
                                        : const SizedBox.shrink()),
                                  ]),
                                );
                              }),
                    ),
                  ]),
                )),
                // Audit trail
                const SizedBox(height: 12),
                _AuditTrail(createdBy: createdBy, createdAt: _order['created_at'] as String?),
              ]),
            ),
    );
  }
}

// ─── Delivery Orders List ─────────────────────────────────────────────────────

class ErpDeliveryOrdersScreen extends ConsumerStatefulWidget {
  const ErpDeliveryOrdersScreen({super.key});
  @override
  ConsumerState<ErpDeliveryOrdersScreen> createState() => _ErpDeliveryOrdersScreenState();
}

class _ErpDeliveryOrdersScreenState extends ConsumerState<ErpDeliveryOrdersScreen> {
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final branchId = ref.read(selectedBranchProvider)?['id'] as String?;
      var query = Supabase.instance.client
          .from('delivery_orders')
          .select('*, customers(shop_name), sales_orders(voucher_number), branches(name)')
          .eq('org_id', orgId);
      if (branchId != null) query = query.eq('branch_id', branchId);
      final res = await query.order('created_at', ascending: false);
      setState(() {
        _orders = List<Map<String, dynamic>>.from(res);
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  void _openDO(Map<String, dynamic> order) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DeliveryOrderDetailScreen(doId: order['id'] as String, onUpdated: _load),
    ));
  }

  void _showCreateDialog() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = ref.read(selectedBranchProvider)?['id'] as String?;
    if (orgId == null || branchId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select a branch first')));
      return;
    }
    // Load confirmed SOs that haven't been fully delivered
    var soQuery = Supabase.instance.client
        .from('sales_orders')
        .select('id, voucher_number, customers(shop_name)')
        .eq('org_id', orgId)
        .inFilter('status', ['confirmed', 'partially_delivered']);
    final sos = await soQuery.eq('branch_id', branchId);
    if (!mounted) return;
    if ((sos as List).isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No confirmed sales orders available')));
      return;
    }
    String? soId;
    final remarksCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('New Delivery Order'),
          content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: soId,
              decoration: const InputDecoration(labelText: 'Sales Order *'),
              hint: const Text('Select SO'),
              items: sos.map((s) => DropdownMenuItem(
                  value: s['id'] as String,
                  child: Text('${s['voucher_number']} — ${s['customers']?['shop_name'] ?? 'Walk-in'}'))).toList(),
              onChanged: (v) => setS(() => soId = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: remarksCtrl, decoration: const InputDecoration(labelText: 'Remarks'), maxLines: 2),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (soId == null) return;
                final userId = ref.read(currentUserProvider)?.id;
                final year = DateTime.now().year;
                try {
                  final so = await Supabase.instance.client.from('sales_orders')
                      .select('customer_id').eq('id', soId!).single();
                  final voucherNum = await Supabase.instance.client
                      .rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_type': 'DO', 'p_year': year});
                  final id = 'do_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client.from('delivery_orders').insert({
                    'id': id, 'org_id': orgId, 'branch_id': branchId,
                    'voucher_number': voucherNum,
                    'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
                    'so_id': soId, 'customer_id': so['customer_id'],
                    'remarks': remarksCtrl.text.trim().isEmpty ? null : remarksCtrl.text.trim(),
                    'status': 'saved', 'is_locked': true,
                    'created_by': userId,
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  await _load();
                  final doOrder = _orders.firstWhere((o) => o['id'] == id, orElse: () => {});
                  if (doOrder.isNotEmpty && mounted) _openDO(doOrder);
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
      default: return Colors.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Delivery Orders', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(onPressed: _showCreateDialog, icon: const Icon(Icons.add, size: 18), label: const Text('New DO')),
        ]),
        const SizedBox(height: 8),
        Text('${_orders.length} delivery orders', style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 24),
        if (_loading) const Center(child: CircularProgressIndicator())
        else Expanded(child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
              child: const Row(children: [
                Expanded(flex: 2, child: Text('DO #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('SO #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 3, child: Text('Customer', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                SizedBox(width: 48),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _orders.isEmpty
                  ? const Center(child: Text('No delivery orders yet.', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      itemCount: _orders.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final o = _orders[i];
                        final status = o['status'] as String? ?? 'saved';
                        final date = o['voucher_date'] != null
                            ? DateFormat('d MMM yyyy').format(DateTime.parse(o['voucher_date'] as String)) : '-';
                        return InkWell(
                          onTap: () => _openDO(o),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(children: [
                              Expanded(flex: 2, child: Text(o['voucher_number'] as String? ?? '-',
                                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                              Expanded(flex: 2, child: Text(o['sales_orders']?['voucher_number'] as String? ?? '-',
                                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                              Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 13))),
                              Expanded(flex: 3, child: Text(o['customers']?['shop_name'] as String? ?? 'Walk-in')),
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

// ─── Delivery Order Detail ────────────────────────────────────────────────────

class DeliveryOrderDetailScreen extends ConsumerStatefulWidget {
  final String doId;
  final VoidCallback onUpdated;
  const DeliveryOrderDetailScreen({super.key, required this.doId, required this.onUpdated});
  @override
  ConsumerState<DeliveryOrderDetailScreen> createState() => _DeliveryOrderDetailScreenState();
}

class _DeliveryOrderDetailScreenState extends ConsumerState<DeliveryOrderDetailScreen> {
  Map<String, dynamic> _do = {};
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _soItems = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final doOrder = await client.from('delivery_orders')
          .select('*, customers(shop_name), sales_orders(voucher_number, branch_id), branches(name)')
          .eq('id', widget.doId).single();
      final items = await client.from('delivery_order_items')
          .select('*, products(name, sku), uoms(abbreviation)')
          .eq('delivery_order_id', widget.doId);
      // Load SO items for adding delivery items
      final soItems = await client.from('sales_order_items')
          .select('*, products(name, sku), uoms(abbreviation)')
          .eq('sales_order_id', doOrder['so_id'] as String);
      setState(() {
        _do = Map<String, dynamic>.from(doOrder);
        _items = List<Map<String, dynamic>>.from(items);
        _soItems = List<Map<String, dynamic>>.from(soItems);
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  bool get _isLocked => _do['is_locked'] as bool? ?? true;
  bool get _isSaved => (_do['status'] as String? ?? 'saved') == 'saved';

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('delivery_orders').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.doId);
      _showSnack(newLocked ? 'DO locked' : 'DO unlocked');
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  void _showAddItemsDialog() async {
    // Load available SO items not yet added to this DO
    final existingProductIds = _items.map((i) => i['product_id'] as String).toSet();
    final availableItems = _soItems.where((i) {
      final ordered = (i['quantity'] as num?)?.toDouble() ?? 0;
      final delivered = (i['qty_delivered'] as num?)?.toDouble() ?? 0;
      return !existingProductIds.contains(i['product_id']) && delivered < ordered;
    }).toList();

    if (availableItems.isEmpty) {
      _showSnack('All SO items already added or fully delivered');
      return;
    }

    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = _do['branch_id'] as String;

    // Load available stock for each item
    final Map<String, double> stockMap = {};
    for (final item in availableItems) {
      final stock = await Supabase.instance.client
          .from('inventory_stock').select('quantity')
          .eq('org_id', orgId!).eq('product_id', item['product_id'] as String)
          .eq('branch_id', branchId).maybeSingle();
      stockMap[item['product_id'] as String] = (stock?['quantity'] as num?)?.toDouble() ?? 0;
    }

    if (!mounted) return;
    final controllers = <String, TextEditingController>{};
    for (final item in availableItems) {
      final ordered = (item['quantity'] as num?)?.toDouble() ?? 0;
      final delivered = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
      final pending = ordered - delivered;
      controllers[item['id'] as String] = TextEditingController(text: pending.toStringAsFixed(0));
    }

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add Delivery Items'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8)),
                child: const Row(children: [
                  Expanded(flex: 3, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text('SO Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text('Available', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text('Deliver *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.primary))),
                ]),
              ),
              const SizedBox(height: 8),
              ...availableItems.map((item) {
                final ordered = (item['quantity'] as num?)?.toDouble() ?? 0;
                final delivered = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
                final pending = ordered - delivered;
                final available = stockMap[item['product_id'] as String] ?? 0;
                final uomAbbr = item['uoms']?['abbreviation'] as String? ?? '';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  child: Row(children: [
                    Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(uomAbbr, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ])),
                    Expanded(flex: 2, child: Text('${pending.toStringAsFixed(0)} $uomAbbr', style: const TextStyle(fontSize: 13))),
                    Expanded(flex: 2, child: Text('${available.toStringAsFixed(0)} $uomAbbr',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                            color: available >= pending ? AppTheme.success : AppTheme.danger))),
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
              // Validate: delivery qty <= ordered qty AND <= available stock
              for (final item in availableItems) {
                final itemId = item['id'] as String;
                final deliverQty = double.tryParse(controllers[itemId]?.text.trim() ?? '0') ?? 0;
                if (deliverQty <= 0) continue;
                final ordered = (item['quantity'] as num?)?.toDouble() ?? 0;
                final alreadyDelivered = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
                final pending = ordered - alreadyDelivered;
                final available = stockMap[item['product_id'] as String] ?? 0;
                if (deliverQty > pending) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('${item['products']?['name']}: delivery qty exceeds ordered qty')));
                  return;
                }
                if (deliverQty > available) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('${item['products']?['name']}: insufficient stock (available: ${available.toStringAsFixed(0)})')));
                  return;
                }
              }
              try {
                final orgId = ref.read(currentUserProvider)?.orgId;
                final userId = ref.read(currentUserProvider)?.id;
                for (final item in availableItems) {
                  final itemId = item['id'] as String;
                  final deliverQty = double.tryParse(controllers[itemId]?.text.trim() ?? '0') ?? 0;
                  if (deliverQty <= 0) continue;
                  final available = stockMap[item['product_id'] as String] ?? 0;
                  // Insert DO item
                  await Supabase.instance.client.from('delivery_order_items').insert({
                    'id': 'doi_${DateTime.now().millisecondsSinceEpoch}_${item['product_id'].toString().substring(0, 4)}',
                    'delivery_order_id': widget.doId,
                    'so_item_id': itemId,
                    'product_id': item['product_id'],
                    'uom_id': item['uom_id'],
                    'qty_ordered': (item['quantity'] as num?)?.toDouble() ?? 0,
                    'qty_available': available,
                    'qty_delivered': deliverQty,
                  });
                  // Deduct stock
                  final stockRow = await Supabase.instance.client
                      .from('inventory_stock').select()
                      .eq('org_id', orgId!).eq('product_id', item['product_id'] as String)
                      .eq('branch_id', branchId).maybeSingle();
                  if (stockRow != null) {
                    await Supabase.instance.client.from('inventory_stock').update({
                      'quantity': (stockRow['quantity'] as num).toDouble() - deliverQty,
                      'updated_at': DateTime.now().toUtc().toIso8601String(),
                    }).eq('id', stockRow['id']);
                  }
                  // Post movement
                  await Supabase.instance.client.from('inventory_movements').insert({
                    'id': 'im_${DateTime.now().millisecondsSinceEpoch}_${item['product_id'].toString().substring(0, 4)}',
                    'org_id': orgId, 'product_id': item['product_id'],
                    'branch_id': branchId, 'uom_id': item['uom_id'],
                    'quantity': -deliverQty, 'movement_type': 'sale',
                    'reference_id': widget.doId, 'reference_type': 'delivery_order',
                    'moved_at': DateTime.now().toUtc().toIso8601String(), 'created_by': userId,
                  });
                  // Update SO item qty_delivered
                  final soItem = await Supabase.instance.client
                      .from('sales_order_items').select('qty_delivered').eq('id', itemId).single();
                  final newDelivered = ((soItem['qty_delivered'] as num?)?.toDouble() ?? 0) + deliverQty;
                  await Supabase.instance.client.from('sales_order_items').update({
                    'qty_delivered': newDelivered,
                  }).eq('id', itemId);
                }
                // Update SO status
                final allSoItems = await Supabase.instance.client
                    .from('sales_order_items').select('quantity, qty_delivered').eq('sales_order_id', _do['so_id'] as String);
                bool allDelivered = true;
                bool anyDelivered = false;
                for (final si in allSoItems as List) {
                  final qty = (si['quantity'] as num?)?.toDouble() ?? 0;
                  final del = (si['qty_delivered'] as num?)?.toDouble() ?? 0;
                  if (del > 0) anyDelivered = true;
                  if (del < qty) allDelivered = false;
                }
                final newSoStatus = allDelivered ? 'delivered' : (anyDelivered ? 'partially_delivered' : 'confirmed');
                await Supabase.instance.client.from('sales_orders').update({
                  'status': newSoStatus, 'updated_at': DateTime.now().toUtc().toIso8601String(),
                }).eq('id', _do['so_id'] as String);

                if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
                _showSnack('Delivery items saved — stock deducted');
                _load();
              } catch (e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
              }
            },
            child: const Text('Save Delivery'),
          ),
        ],
      ),
    );
  }

  Future<void> _createInvoice() async {
    if (_items.isEmpty) { _showSnack('No items to invoice'); return; }
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = _do['branch_id'] as String;
    final userId = ref.read(currentUserProvider)?.id;
    final year = DateTime.now().year;
    try {
      final voucherNum = await Supabase.instance.client
          .rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_type': 'SI', 'p_year': year});
      final siId = 'si_${DateTime.now().millisecondsSinceEpoch}';
      double subtotal = 0;
      // Get selling prices from products
      final productIds = _items.map((i) => i['product_id'] as String).toList();
      final priceMap = <String, double>{};
      for (final pid in productIds) {
        final prod = await Supabase.instance.client.from('products').select('selling_price').eq('id', pid).single();
        priceMap[pid] = (prod['selling_price'] as num?)?.toDouble() ?? 0;
      }
      final siItems = _items.map((item) {
        final qty = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
        final price = priceMap[item['product_id'] as String] ?? 0;
        final lineTotal = qty * price;
        subtotal += lineTotal;
        return {
          'id': 'sii_${DateTime.now().millisecondsSinceEpoch}_${item['product_id'].toString().substring(0, 4)}',
          'product_id': item['product_id'],
          'uom_id': item['uom_id'],
          'qty_delivered': qty,
          'unit_price': price,
          'discount': 0.0,
          'line_total': lineTotal,
        };
      }).toList();

      await Supabase.instance.client.from('sales_invoices').insert({
        'id': siId, 'org_id': orgId, 'branch_id': branchId,
        'voucher_number': voucherNum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'so_id': _do['so_id'], 'do_id': widget.doId,
        'customer_id': _do['customer_id'],
        'subtotal': subtotal, 'discount_total': 0, 'grand_total': subtotal,
        'is_locked': true, 'created_by': userId,
      });
      for (final item in siItems) {
        await Supabase.instance.client.from('sales_invoice_items').insert({...item, 'invoice_id': siId});
      }
      // Mark DO as invoiced
      await Supabase.instance.client.from('delivery_orders').update({
        'status': 'invoiced', 'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.doId);

      _showSnack('Sales invoice $voucherNum created');
      widget.onUpdated();
      _load();
      // Navigate to SI
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SalesInvoiceDetailScreen(invoiceId: siId, onUpdated: () {}),
        ));
      }
    } catch (e) { _showSnack('Failed: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    final status = _do['status'] as String? ?? 'saved';
    final isSavedNotInvoiced = status == 'saved';

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.white, elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_do['voucher_number'] as String? ?? 'Delivery Order',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text('SO: ${_do['sales_orders']?['voucher_number'] ?? '-'}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w400)),
        ]),
        actions: [
          if (isSavedNotInvoiced) ...[
            if (!_isLocked) ...[
              ElevatedButton(onPressed: _showAddItemsDialog, child: const Text('Add Items')),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _items.isNotEmpty ? _createInvoice : null,
                  child: const Text('Create Invoice')),
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
                  _InfoChip(label: 'Branch', value: _do['branches']?['name'] as String? ?? '-'),
                  _InfoChip(label: 'Date', value: _do['voucher_date'] != null
                      ? DateFormat('d MMM yyyy').format(DateTime.parse(_do['voucher_date'] as String)) : '-'),
                  _InfoChip(label: 'Customer', value: _do['customers']?['shop_name'] as String? ?? 'Walk-in'),
                  if (_do['remarks'] != null) _InfoChip(label: 'Remarks', value: _do['remarks'] as String),
                  if (_isLocked) const _LockedChip(),
                ]),
                const SizedBox(height: 24),
                const Text('Delivery Items', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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
                        Expanded(flex: 2, child: Text('SO Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Available', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Delivered', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _items.isEmpty
                          ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              const Text('No delivery items yet.', style: TextStyle(color: AppTheme.textSecondary)),
                              if (!_isLocked && isSavedNotInvoiced) ...[
                                const SizedBox(height: 8),
                                ElevatedButton(onPressed: _showAddItemsDialog, child: const Text('Add Items from SO')),
                              ],
                            ]))
                          : ListView.separated(
                              itemCount: _items.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final item = _items[i];
                                final ordered = (item['qty_ordered'] as num?)?.toDouble() ?? 0;
                                final available = (item['qty_available'] as num?)?.toDouble() ?? 0;
                                final delivered = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
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
                                    Expanded(flex: 2, child: Text(available.toStringAsFixed(0),
                                        style: TextStyle(fontWeight: FontWeight.w600, color: available > 0 ? AppTheme.success : AppTheme.danger))),
                                    Expanded(flex: 2, child: Text(delivered.toStringAsFixed(0),
                                        style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                                  ]),
                                );
                              }),
                    ),
                  ]),
                )),
                const SizedBox(height: 12),
                _AuditTrail(createdBy: _do['created_by'] as String?, createdAt: _do['created_at'] as String?),
              ]),
            ),
    );
  }
}

// ─── Sales Invoices List ──────────────────────────────────────────────────────

class ErpSalesInvoicesScreen extends ConsumerStatefulWidget {
  const ErpSalesInvoicesScreen({super.key});
  @override
  ConsumerState<ErpSalesInvoicesScreen> createState() => _ErpSalesInvoicesScreenState();
}

class _ErpSalesInvoicesScreenState extends ConsumerState<ErpSalesInvoicesScreen> {
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
          .from('sales_invoices')
          .select('*, customers(shop_name), sales_orders(voucher_number), delivery_orders(voucher_number)')
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
        const Text('Sales Invoices', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
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
                Expanded(flex: 2, child: Text('SI #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('SO #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('DO #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Customer', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                SizedBox(width: 48),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _invoices.isEmpty
                  ? const Center(child: Text('No sales invoices yet.', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      itemCount: _invoices.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final inv = _invoices[i];
                        final date = inv['voucher_date'] != null
                            ? DateFormat('d MMM yyyy').format(DateTime.parse(inv['voucher_date'] as String)) : '-';
                        return InkWell(
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => SalesInvoiceDetailScreen(invoiceId: inv['id'] as String, onUpdated: _load))),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(children: [
                              Expanded(flex: 2, child: Text(inv['voucher_number'] as String? ?? '-',
                                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                              Expanded(flex: 2, child: Text(inv['sales_orders']?['voucher_number'] as String? ?? '-',
                                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                              Expanded(flex: 2, child: Text(inv['delivery_orders']?['voucher_number'] as String? ?? '-',
                                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                              Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 13))),
                              Expanded(flex: 2, child: Text(inv['customers']?['shop_name'] as String? ?? 'Walk-in')),
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

// ─── Sales Invoice Detail ─────────────────────────────────────────────────────

class SalesInvoiceDetailScreen extends ConsumerStatefulWidget {
  final String invoiceId;
  final VoidCallback onUpdated;
  const SalesInvoiceDetailScreen({super.key, required this.invoiceId, required this.onUpdated});
  @override
  ConsumerState<SalesInvoiceDetailScreen> createState() => _SalesInvoiceDetailScreenState();
}

class _SalesInvoiceDetailScreenState extends ConsumerState<SalesInvoiceDetailScreen> {
  Map<String, dynamic> _invoice = {};
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final invoice = await client.from('sales_invoices')
          .select('*, customers(shop_name), sales_orders(voucher_number), delivery_orders(voucher_number), branches(name)')
          .eq('id', widget.invoiceId).single();
      final items = await client.from('sales_invoice_items')
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
      await Supabase.instance.client.from('sales_invoices').update({
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
        final qty = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
        final price = (item['unit_price'] as num?)?.toDouble() ?? 0;
        final disc = discounts[item['id'] as String] ?? (item['discount'] as num?)?.toDouble() ?? 0;
        final lineTotal = (qty * price) - disc;
        subtotal += qty * price;
        discountTotal += disc;
        await Supabase.instance.client.from('sales_invoice_items').update({
          'discount': disc, 'line_total': lineTotal,
        }).eq('id', item['id']);
      }
      await Supabase.instance.client.from('sales_invoices').update({
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
          Text(_invoice['voucher_number'] as String? ?? 'Sales Invoice',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text(_invoice['customers']?['shop_name'] as String? ?? 'Walk-in',
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
                  _InfoChip(label: 'SO #', value: _invoice['sales_orders']?['voucher_number'] as String? ?? '-'),
                  _InfoChip(label: 'DO #', value: _invoice['delivery_orders']?['voucher_number'] as String? ?? '-'),
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
                        Expanded(flex: 2, child: Text('Unit Price', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
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
                                final qty = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
                                final price = (item['unit_price'] as num?)?.toDouble() ?? 0;
                                final disc = double.tryParse(discountControllers[item['id'] as String]?.text ?? '0') ?? 0;
                                final lineTotal = (qty * price) - disc;
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
                                    Expanded(flex: 2, child: Text(price.toStringAsFixed(2))),
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
