import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

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
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final res = await Supabase.instance.client
          .from('purchase_orders')
          .select('*, suppliers(name), warehouses(name)')
          .eq('org_id', orgId)
          .order('created_at', ascending: false);
      setState(() {
        _orders = List<Map<String, dynamic>>.from(res);
        _filtered = _orders;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _applyFilter() {
    setState(() {
      _filtered = _orders.where((o) {
        if (_statusFilter == 'all') return true;
        return o['status'] == _statusFilter;
      }).toList();
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'ordered': return Colors.blue;
      case 'received': return AppTheme.success;
      case 'cancelled': return AppTheme.danger;
      default: return AppTheme.textSecondary;
    }
  }

  void _openOrder(Map<String, dynamic> order) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PurchaseOrderDetailScreen(
        order: order,
        onUpdated: _load,
      ),
    ));
  }

  void _showCreateDialog() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final client = Supabase.instance.client;
    final suppliers = await client
        .from('suppliers')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('name');
    final warehouses = await client
        .from('warehouses')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('name');
    if (!mounted) return;
    String? supplierId;
    String? warehouseId;
    final notesCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('New Purchase Order'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: supplierId,
                decoration: const InputDecoration(labelText: 'Supplier *'),
                hint: const Text('Select supplier'),
                items: (suppliers as List).map((s) => DropdownMenuItem(
                    value: s['id'] as String,
                    child: Text(s['name'] as String))).toList(),
                onChanged: (v) => setS(() => supplierId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: warehouseId,
                decoration: const InputDecoration(labelText: 'Receive Into Warehouse *'),
                hint: const Text('Select warehouse'),
                items: (warehouses as List).map((w) => DropdownMenuItem(
                    value: w['id'] as String,
                    child: Text(w['name'] as String))).toList(),
                onChanged: (v) => setS(() => warehouseId = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notesCtrl,
                decoration: const InputDecoration(labelText: 'Notes'),
                maxLines: 2,
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (supplierId == null || warehouseId == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Supplier and warehouse are required')));
                  return;
                }
                final userId = ref.read(currentUserProvider)?.id;
                final id = 'po_${DateTime.now().millisecondsSinceEpoch}';
                try {
                  await client.from('purchase_orders').insert({
                    'id': id,
                    'org_id': orgId,
                    'supplier_id': supplierId,
                    'warehouse_id': warehouseId,
                    'status': 'draft',
                    'notes': notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
                    'created_by': userId,
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack('Purchase order created');
                  await _load();
                  // Open the new order immediately
                  final newOrder = _orders.firstWhere((o) => o['id'] == id,
                      orElse: () => {});
                  if (newOrder.isNotEmpty && mounted) _openOrder(newOrder);
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('Failed: $e')));
                  }
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Purchase Orders',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: _showCreateDialog,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Purchase Order'),
            ),
          ]),
          const SizedBox(height: 8),
          Text('${_filtered.length} orders',
              style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          SizedBox(
            width: 280,
            child: DropdownButtonFormField<String>(
              value: _statusFilter,
              decoration: const InputDecoration(labelText: 'Status', isDense: true),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All statuses')),
                DropdownMenuItem(value: 'draft', child: Text('Draft')),
                DropdownMenuItem(value: 'ordered', child: Text('Ordered')),
                DropdownMenuItem(value: 'received', child: Text('Received')),
                DropdownMenuItem(value: 'cancelled', child: Text('Cancelled')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _statusFilter = v);
                _applyFilter();
              },
            ),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: const BoxDecoration(
                        color: AppTheme.background,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                      ),
                      child: const Row(children: [
                        Expanded(flex: 2, child: Text('PO #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 3, child: Text('Supplier', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Warehouse', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Created', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        SizedBox(width: 48),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _filtered.isEmpty
                          ? const Center(
                              child: Text('No purchase orders yet.',
                                  style: TextStyle(color: AppTheme.textSecondary)))
                          : ListView.separated(
                              itemCount: _filtered.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final o = _filtered[i];
                                final status = o['status'] as String? ?? 'draft';
                                final createdAt = o['created_at'] != null
                                    ? DateFormat('d MMM yyyy').format(
                                        DateTime.parse(o['created_at'] as String).toLocal())
                                    : '-';
                                return InkWell(
                                  onTap: () => _openOrder(o),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 20, vertical: 12),
                                    child: Row(children: [
                                      Expanded(
                                          flex: 2,
                                          child: Text(
                                              o['id'].toString().substring(3, 16),
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  color: AppTheme.primary))),
                                      Expanded(
                                          flex: 3,
                                          child: Text(
                                              o['suppliers']?['name'] as String? ?? '-')),
                                      Expanded(
                                          flex: 2,
                                          child: Text(
                                              o['warehouses']?['name'] as String? ?? '-',
                                              style: const TextStyle(
                                                  color: AppTheme.textSecondary,
                                                  fontSize: 13))),
                                      Expanded(
                                        flex: 2,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: _statusColor(status).withOpacity(0.1),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            status[0].toUpperCase() + status.substring(1),
                                            style: TextStyle(
                                                color: _statusColor(status),
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                          flex: 2,
                                          child: Text(createdAt,
                                              style: const TextStyle(
                                                  color: AppTheme.textSecondary,
                                                  fontSize: 13))),
                                      const SizedBox(
                                          width: 48,
                                          child: Icon(Icons.chevron_right,
                                              color: AppTheme.textSecondary)),
                                    ]),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Purchase Order Detail Screen ─────────────────────────────────────────────

class _PurchaseOrderDetailScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> order;
  final VoidCallback onUpdated;
  const _PurchaseOrderDetailScreen({required this.order, required this.onUpdated});
  @override
  ConsumerState<_PurchaseOrderDetailScreen> createState() =>
      _PurchaseOrderDetailScreenState();
}

class _PurchaseOrderDetailScreenState
    extends ConsumerState<_PurchaseOrderDetailScreen> {
  late Map<String, dynamic> _order;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _uoms = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _order = widget.order;
    _loadItems();
  }

  Future<void> _loadItems() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    try {
      final client = Supabase.instance.client;
      final items = await client
          .from('purchase_order_items')
          .select('*, products(name, sku), uoms(name, abbreviation)')
          .eq('purchase_order_id', _order['id']);
      final products = await client
          .from('products')
          .select('id, name, sku, base_uom_id')
          .eq('org_id', orgId!)
          .eq('is_active', true)
          .order('name');
      final uoms = await client
          .from('uoms')
          .select()
          .eq('org_id', orgId)
          .order('name');
      // Reload order to get latest status
      final orderRes = await client
          .from('purchase_orders')
          .select('*, suppliers(name), warehouses(name)')
          .eq('id', _order['id'])
          .single();
      setState(() {
        _items = List<Map<String, dynamic>>.from(items);
        _products = List<Map<String, dynamic>>.from(products);
        _uoms = List<Map<String, dynamic>>.from(uoms);
        _order = orderRes;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

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
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                    // Auto-select base UOM
                    final product = _products.firstWhere(
                        (p) => p['id'] == v, orElse: () => {});
                    uomId = product['base_uom_id'] as String?;
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
                Expanded(child: TextField(
                    controller: qtyCtrl,
                    decoration: const InputDecoration(labelText: 'Quantity *'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 12),
                Expanded(child: TextField(
                    controller: costCtrl,
                    decoration: const InputDecoration(labelText: 'Unit Cost'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true))),
              ]),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (productId == null || uomId == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Product and UOM are required')));
                  return;
                }
                final qty = double.tryParse(qtyCtrl.text.trim()) ?? 0;
                final cost = double.tryParse(costCtrl.text.trim()) ?? 0;
                if (qty <= 0) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Quantity must be greater than 0')));
                  return;
                }
                try {
                  await Supabase.instance.client.from('purchase_order_items').insert({
                    'id': 'poi_${DateTime.now().millisecondsSinceEpoch}',
                    'purchase_order_id': _order['id'],
                    'product_id': productId,
                    'uom_id': uomId,
                    'quantity_ordered': qty,
                    'quantity_received': 0,
                    'unit_cost': cost,
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _loadItems();
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('Failed: $e')));
                  }
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
    try {
      await Supabase.instance.client
          .from('purchase_orders')
          .update({
            'status': 'ordered',
            'ordered_at': DateTime.now().toUtc().toIso8601String(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', _order['id']);
      _showSnack('Order marked as ordered');
      widget.onUpdated();
      _loadItems();
    } catch (e) {
      _showSnack('Failed: $e');
    }
  }

  Future<void> _receiveOrder() async {
    if (_items.isEmpty) {
      _showSnack('Add items before receiving');
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Receive Purchase Order'),
        content: const Text(
            'This will add all ordered quantities to stock and cannot be undone. Proceed?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
              child: const Text('Receive')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final client = Supabase.instance.client;
      final orgId = ref.read(currentUserProvider)?.orgId;
      final userId = ref.read(currentUserProvider)?.id;
      final warehouseId = _order['warehouse_id'] as String;
      for (final item in _items) {
        final qty = (item['quantity_ordered'] as num).toDouble();
        final productId = item['product_id'] as String;
        final uomId = item['uom_id'] as String;
        // Post movement
        await client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().millisecondsSinceEpoch}_${productId.substring(0, 4)}',
          'org_id': orgId,
          'product_id': productId,
          'warehouse_id': warehouseId,
          'uom_id': uomId,
          'quantity': qty,
          'movement_type': 'purchase',
          'reference_id': _order['id'],
          'reference_type': 'purchase_order',
          'moved_at': DateTime.now().toUtc().toIso8601String(),
          'created_by': userId,
        });
        // Upsert stock
        final existing = await client
            .from('inventory_stock')
            .select()
            .eq('org_id', orgId!)
            .eq('product_id', productId)
            .eq('warehouse_id', warehouseId)
            .maybeSingle();
        if (existing != null) {
          final newQty = (existing['quantity'] as num).toDouble() + qty;
          await client.from('inventory_stock').update({
            'quantity': newQty,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', existing['id']);
        } else {
          await client.from('inventory_stock').insert({
            'id': 'is_${DateTime.now().millisecondsSinceEpoch}_${productId.substring(0, 4)}',
            'org_id': orgId,
            'product_id': productId,
            'warehouse_id': warehouseId,
            'uom_id': uomId,
            'quantity': qty,
          });
        }
        // Update received qty on item
        await client.from('purchase_order_items').update({
          'quantity_received': qty,
        }).eq('id', item['id']);
      }
      // Mark order received
      await client.from('purchase_orders').update({
        'status': 'received',
        'received_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _order['id']);
      _showSnack('Purchase order received — stock updated');
      widget.onUpdated();
      _loadItems();
    } catch (e) {
      _showSnack('Failed: $e');
    }
  }

  Future<void> _cancelOrder() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel Order'),
        content: const Text('Are you sure you want to cancel this purchase order?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
              child: const Text('No')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            child: const Text('Cancel Order'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'status': 'cancelled',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _order['id']);
      _showSnack('Order cancelled');
      widget.onUpdated();
      _loadItems();
    } catch (e) {
      _showSnack('Failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _order['status'] as String? ?? 'draft';
    final isDraft = status == 'draft';
    final isOrdered = status == 'ordered';
    final isReceived = status == 'received';
    final isCancelled = status == 'cancelled';

    double total = 0;
    for (final item in _items) {
      total += ((item['quantity_ordered'] as num?)?.toDouble() ?? 0) *
          ((item['unit_cost'] as num?)?.toDouble() ?? 0);
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Purchase Order',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text(_order['suppliers']?['name'] as String? ?? '',
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary,
                  fontWeight: FontWeight.w400)),
        ]),
        actions: [
          if (isDraft || isOrdered) ...[
            if (isDraft)
              TextButton(onPressed: _markOrdered, child: const Text('Mark Ordered')),
            if (isOrdered)
              ElevatedButton(
                  onPressed: _receiveOrder,
                  child: const Text('Receive All')),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _cancelOrder,
              style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
              child: const Text('Cancel Order'),
            ),
          ],
          if (isReceived)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.success.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('Received',
                  style: TextStyle(color: AppTheme.success, fontWeight: FontWeight.w600)),
            ),
          if (isCancelled)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.danger.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('Cancelled',
                  style: TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w600)),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Order info row
                  Row(children: [
                    _InfoChip(label: 'Warehouse',
                        value: _order['warehouses']?['name'] as String? ?? '-'),
                    const SizedBox(width: 16),
                    _InfoChip(label: 'Status',
                        value: status[0].toUpperCase() + status.substring(1)),
                    if (_order['notes'] != null) ...[
                      const SizedBox(width: 16),
                      _InfoChip(label: 'Notes', value: _order['notes'] as String),
                    ],
                  ]),
                  const SizedBox(height: 24),
                  // Items
                  Row(children: [
                    const Text('Items',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    if (isDraft)
                      ElevatedButton.icon(
                        onPressed: _showAddItemDialog,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add Item'),
                      ),
                  ]),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Column(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          decoration: const BoxDecoration(
                            color: AppTheme.background,
                            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                          ),
                          child: const Row(children: [
                            Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                            Expanded(flex: 2, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                            Expanded(flex: 2, child: Text('Qty Ordered', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                            Expanded(flex: 2, child: Text('Unit Cost', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                            Expanded(flex: 2, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                            SizedBox(width: 48),
                          ]),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: _items.isEmpty
                              ? const Center(
                                  child: Text('No items yet. Add items to this order.',
                                      style: TextStyle(color: AppTheme.textSecondary)))
                              : ListView.separated(
                                  itemCount: _items.length,
                                  separatorBuilder: (_, __) => const Divider(height: 1),
                                  itemBuilder: (_, i) {
                                    final item = _items[i];
                                    final qty = (item['quantity_ordered'] as num?)?.toDouble() ?? 0;
                                    final cost = (item['unit_cost'] as num?)?.toDouble() ?? 0;
                                    final lineTotal = qty * cost;
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 20, vertical: 12),
                                      child: Row(children: [
                                        Expanded(
                                            flex: 4,
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(item['products']?['name'] as String? ?? '',
                                                    style: const TextStyle(fontWeight: FontWeight.w600)),
                                                if (item['products']?['sku'] != null)
                                                  Text(item['products']['sku'] as String,
                                                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                              ],
                                            )),
                                        Expanded(
                                            flex: 2,
                                            child: Text(
                                                item['uoms']?['abbreviation'] as String? ?? '-',
                                                style: const TextStyle(color: AppTheme.textSecondary))),
                                        Expanded(
                                            flex: 2,
                                            child: Text(
                                                qty % 1 == 0 ? qty.toInt().toString() : qty.toString(),
                                                style: const TextStyle(fontWeight: FontWeight.w600))),
                                        Expanded(
                                            flex: 2,
                                            child: Text(cost.toStringAsFixed(2))),
                                        Expanded(
                                            flex: 2,
                                            child: Text(lineTotal.toStringAsFixed(2),
                                                style: const TextStyle(fontWeight: FontWeight.w600))),
                                        SizedBox(
                                          width: 48,
                                          child: isDraft
                                              ? IconButton(
                                                  icon: const Icon(Icons.delete_outline,
                                                      size: 18, color: AppTheme.danger),
                                                  onPressed: () async {
                                                    await Supabase.instance.client
                                                        .from('purchase_order_items')
                                                        .delete()
                                                        .eq('id', item['id']);
                                                    _loadItems();
                                                  },
                                                )
                                              : const SizedBox.shrink(),
                                        ),
                                      ]),
                                    );
                                  },
                                ),
                        ),
                        if (_items.isNotEmpty) ...[
                          const Divider(height: 1),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(children: [
                              const Spacer(),
                              Text('Total: ${total.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800, fontSize: 16)),
                            ]),
                          ),
                        ],
                      ]),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final String value;
  const _InfoChip({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label: ',
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 13)),
        Text(value,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ]),
    );
  }
}
