import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

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
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final res = await Supabase.instance.client
          .from('sales_orders')
          .select('*, customers(shop_name, code), branches(name)')
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
      _filtered = _statusFilter == 'all'
          ? _orders
          : _orders.where((o) => o['status'] == _statusFilter).toList();
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'confirmed': return Colors.blue;
      case 'delivered': return AppTheme.success;
      case 'cancelled': return AppTheme.danger;
      default: return AppTheme.textSecondary;
    }
  }

  void _openOrder(Map<String, dynamic> order) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _SalesOrderDetailScreen(order: order, onUpdated: _load),
    ));
  }

  void _showCreateDialog() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final client = Supabase.instance.client;
    final customers = await client
        .from('customers')
        .select('id, shop_name, code')
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('shop_name');
    final branches = await client
        .from('branches')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('name');
    if (!mounted) return;
    String? customerId;
    String? branchId;
    final notesCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('New Sales Order'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
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
              DropdownButtonFormField<String>(
                value: branchId,
                decoration: const InputDecoration(labelText: 'Ship From Branch *'),
                hint: const Text('Select branch'),
                items: (branches as List).map((w) => DropdownMenuItem(
                    value: w['id'] as String,
                    child: Text(w['name'] as String))).toList(),
                onChanged: (v) => setS(() => branchId = v),
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
                if (branchId == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Branch is required')));
                  return;
                }
                final userId = ref.read(currentUserProvider)?.id;
                final id = 'so_${DateTime.now().millisecondsSinceEpoch}';
                try {
                  await client.from('sales_orders').insert({
                    'id': id,
                    'org_id': orgId,
                    'customer_id': customerId,
                    'branch_id': branchId,
                    'status': 'draft',
                    'notes': notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
                    'created_by': userId,
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack('Sales order created');
                  await _load();
                  final newOrder = _orders.firstWhere((o) => o['id'] == id, orElse: () => {});
                  if (newOrder.isNotEmpty && mounted) _openOrder(newOrder);
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: $e')));
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
            const Text('Sales Orders',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: _showCreateDialog,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Sales Order'),
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
                DropdownMenuItem(value: 'confirmed', child: Text('Confirmed')),
                DropdownMenuItem(value: 'delivered', child: Text('Delivered')),
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
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: const BoxDecoration(
                      color: AppTheme.background,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                    ),
                    child: const Row(children: [
                      Expanded(flex: 2, child: Text('SO #', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 3, child: Text('Customer', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Branch', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Created', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
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
                              final createdAt = o['created_at'] != null
                                  ? DateFormat('d MMM yyyy').format(DateTime.parse(o['created_at'] as String).toLocal())
                                  : '-';
                              return InkWell(
                                onTap: () => _openOrder(o),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  child: Row(children: [
                                    Expanded(flex: 2, child: Text(o['id'].toString().substring(3, 16),
                                        style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primary))),
                                    Expanded(flex: 3, child: Text(o['customers']?['shop_name'] as String? ?? 'Walk-in',
                                        style: const TextStyle(fontWeight: FontWeight.w500))),
                                    Expanded(flex: 2, child: Text(o['branches']?['name'] as String? ?? '-',
                                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                                    Expanded(flex: 2, child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: _statusColor(status).withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(status[0].toUpperCase() + status.substring(1),
                                          style: TextStyle(color: _statusColor(status), fontSize: 12, fontWeight: FontWeight.w600)),
                                    )),
                                    Expanded(flex: 2, child: Text(createdAt,
                                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                                    const SizedBox(width: 48, child: Icon(Icons.chevron_right, color: AppTheme.textSecondary)),
                                  ]),
                                ),
                              );
                            },
                          ),
                  ),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

class _SalesOrderDetailScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> order;
  final VoidCallback onUpdated;
  const _SalesOrderDetailScreen({required this.order, required this.onUpdated});
  @override
  ConsumerState<_SalesOrderDetailScreen> createState() => _SalesOrderDetailScreenState();
}

class _SalesOrderDetailScreenState extends ConsumerState<_SalesOrderDetailScreen> {
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
          .from('sales_order_items')
          .select('*, products(name, sku), uoms(name, abbreviation)')
          .eq('sales_order_id', _order['id']);
      final products = await client
          .from('products')
          .select('id, name, sku, base_uom_id, selling_price')
          .eq('org_id', orgId!)
          .eq('is_active', true)
          .order('name');
      final uoms = await client.from('uoms').select().eq('org_id', orgId).order('name');
      final orderRes = await client
          .from('sales_orders')
          .select('*, customers(shop_name, code), branches(name)')
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
    final priceCtrl = TextEditingController(text: '0');
    final discCtrl = TextEditingController(text: '0');
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
                    final product = _products.firstWhere((p) => p['id'] == v, orElse: () => {});
                    uomId = product['base_uom_id'] as String?;
                    priceCtrl.text = product['selling_price']?.toString() ?? '0';
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
                Expanded(child: TextField(controller: qtyCtrl,
                    decoration: const InputDecoration(labelText: 'Quantity *'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: priceCtrl,
                    decoration: const InputDecoration(labelText: 'Unit Price'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: discCtrl,
                    decoration: const InputDecoration(labelText: 'Discount'),
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
                if (qty <= 0) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Quantity must be greater than 0')));
                  return;
                }
                try {
                  await Supabase.instance.client.from('sales_order_items').insert({
                    'id': 'soi_${DateTime.now().millisecondsSinceEpoch}',
                    'sales_order_id': _order['id'],
                    'product_id': productId,
                    'uom_id': uomId,
                    'quantity': qty,
                    'unit_price': double.tryParse(priceCtrl.text.trim()) ?? 0,
                    'discount': double.tryParse(discCtrl.text.trim()) ?? 0,
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _loadItems();
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
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _order['id']);
      _showSnack('Order confirmed');
      widget.onUpdated();
      _loadItems();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _deliverOrder() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Mark as Delivered'),
        content: const Text('This will deduct all items from stock. Proceed?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Deliver')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final client = Supabase.instance.client;
      final orgId = ref.read(currentUserProvider)?.orgId;
      final userId = ref.read(currentUserProvider)?.id;
      final branchId = _order['branch_id'] as String;
      for (final item in _items) {
        final qty = (item['quantity'] as num).toDouble();
        final productId = item['product_id'] as String;
        final uomId = item['uom_id'] as String;
        await client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().millisecondsSinceEpoch}_${productId.substring(0, 4)}',
          'org_id': orgId,
          'product_id': productId,
          'branch_id': branchId,
          'uom_id': uomId,
          'quantity': -qty,
          'movement_type': 'sale',
          'reference_id': _order['id'],
          'reference_type': 'sales_order',
          'moved_at': DateTime.now().toUtc().toIso8601String(),
          'created_by': userId,
        });
        final existing = await client
            .from('inventory_stock')
            .select()
            .eq('org_id', orgId!)
            .eq('product_id', productId)
            .eq('branch_id', branchId)
            .maybeSingle();
        if (existing != null) {
          final newQty = (existing['quantity'] as num).toDouble() - qty;
          await client.from('inventory_stock').update({
            'quantity': newQty,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', existing['id']);
        }
      }
      await client.from('sales_orders').update({
        'status': 'delivered',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _order['id']);
      _showSnack('Order delivered — stock deducted');
      widget.onUpdated();
      _loadItems();
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
      await Supabase.instance.client.from('sales_orders').update({
        'status': 'cancelled',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _order['id']);
      _showSnack('Order cancelled');
      widget.onUpdated();
      _loadItems();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    final status = _order['status'] as String? ?? 'draft';
    final isDraft = status == 'draft';
    final isConfirmed = status == 'confirmed';
    double total = 0;
    for (final item in _items) {
      final qty = (item['quantity'] as num?)?.toDouble() ?? 0;
      final price = (item['unit_price'] as num?)?.toDouble() ?? 0;
      final disc = (item['discount'] as num?)?.toDouble() ?? 0;
      total += (qty * price) - disc;
    }
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Sales Order', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text(_order['customers']?['shop_name'] as String? ?? 'Walk-in',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w400)),
        ]),
        actions: [
          if (isDraft) ...[
            ElevatedButton(onPressed: _confirmOrder, child: const Text('Confirm')),
            const SizedBox(width: 8),
            TextButton(onPressed: _cancelOrder,
                style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
                child: const Text('Cancel')),
          ],
          if (isConfirmed) ...[
            ElevatedButton(onPressed: _deliverOrder, child: const Text('Mark Delivered')),
            const SizedBox(width: 8),
            TextButton(onPressed: _cancelOrder,
                style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
                child: const Text('Cancel')),
          ],
          if (status == 'delivered')
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: AppTheme.success.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
              child: const Text('Delivered', style: TextStyle(color: AppTheme.success, fontWeight: FontWeight.w600)),
            ),
          if (status == 'cancelled')
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
              child: const Text('Cancelled', style: TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w600)),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  _InfoChip(label: 'Branch', value: _order['branches']?['name'] as String? ?? '-'),
                  const SizedBox(width: 16),
                  _InfoChip(label: 'Status', value: status[0].toUpperCase() + status.substring(1)),
                  if (_order['notes'] != null) ...[
                    const SizedBox(width: 16),
                    _InfoChip(label: 'Notes', value: _order['notes'] as String),
                  ],
                ]),
                const SizedBox(height: 24),
                Row(children: [
                  const Text('Items', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (isDraft)
                    ElevatedButton.icon(
                        onPressed: _showAddItemDialog,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add Item')),
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
                          Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                          Expanded(flex: 2, child: Text('Unit Price', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                          Expanded(flex: 2, child: Text('Discount', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
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
                                  final qty = (item['quantity'] as num?)?.toDouble() ?? 0;
                                  final price = (item['unit_price'] as num?)?.toDouble() ?? 0;
                                  final disc = (item['discount'] as num?)?.toDouble() ?? 0;
                                  final lineTotal = (qty * price) - disc;
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                    child: Row(children: [
                                      Expanded(flex: 4, child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                                          if (item['products']?['sku'] != null)
                                            Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                        ],
                                      )),
                                      Expanded(flex: 2, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary))),
                                      Expanded(flex: 2, child: Text(qty % 1 == 0 ? qty.toInt().toString() : qty.toString(), style: const TextStyle(fontWeight: FontWeight.w600))),
                                      Expanded(flex: 2, child: Text(price.toStringAsFixed(2))),
                                      Expanded(flex: 2, child: Text(disc.toStringAsFixed(2))),
                                      Expanded(flex: 2, child: Text(lineTotal.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.w600))),
                                      SizedBox(width: 48, child: isDraft
                                          ? IconButton(
                                              icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                                              onPressed: () async {
                                                await Supabase.instance.client.from('sales_order_items').delete().eq('id', item['id']);
                                                _loadItems();
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
                            Text('Total: ${total.toStringAsFixed(2)}',
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                          ]),
                        ),
                      ],
                    ]),
                  ),
                ),
              ]),
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
        Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ]),
    );
  }
}
