import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpStockTransfersScreen extends ConsumerStatefulWidget {
  const ErpStockTransfersScreen({super.key});
  @override
  ConsumerState<ErpStockTransfersScreen> createState() => _ErpStockTransfersScreenState();
}

class _ErpStockTransfersScreenState extends ConsumerState<ErpStockTransfersScreen> {
  List<Map<String, dynamic>> _transfers = [];
  List<Map<String, dynamic>> _allBranches = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = _branchId;
    if (orgId == null) { setState(() => _loading = false); return; }
    try {
      final client = Supabase.instance.client;
      final baseQuery = client
          .from('stock_transfers')
          .select('*, from_branch:branches!from_branch_id(name), to_branch:branches!to_branch_id(name)')
          .eq('org_id', orgId);
      final transfers = branchId != null
          ? await baseQuery.or('from_branch_id.eq.$branchId,to_branch_id.eq.$branchId').order('created_at', ascending: false)
          : await baseQuery.order('created_at', ascending: false);
      final branches = await client.from('branches').select().eq('org_id', orgId).eq('is_active', true).order('name');
      setState(() {
        _transfers = List<Map<String, dynamic>>.from(transfers);
        _allBranches = List<Map<String, dynamic>>.from(branches);
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'completed': return AppTheme.success;
      case 'cancelled': return AppTheme.danger;
      default: return Colors.orange;
    }
  }

  void _showCreateDialog() {
    final branchId = _branchId;
    String? fromBranchId = branchId;
    String? toBranchId;
    final notesCtrl = TextEditingController();
    DateTime transferDate = DateTime.now();

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('New Stock Transfer'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: fromBranchId,
                decoration: const InputDecoration(labelText: 'From Branch *'),
                hint: const Text('Select source branch'),
                items: _allBranches.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String))).toList(),
                onChanged: (v) => setS(() => fromBranchId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: toBranchId,
                decoration: const InputDecoration(labelText: 'To Branch *'),
                hint: const Text('Select destination branch'),
                items: _allBranches.where((b) => b['id'] != fromBranchId).map((b) =>
                    DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String))).toList(),
                onChanged: (v) => setS(() => toBranchId = v),
              ),
              const SizedBox(height: 12),
              TextField(controller: notesCtrl, decoration: const InputDecoration(labelText: 'Notes'), maxLines: 2),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx, initialDate: transferDate,
                    firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) setS(() => transferDate = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Transfer Date'),
                  child: Text(DateFormat('d MMM yyyy').format(transferDate)),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (fromBranchId == null || toBranchId == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Both branches required')));
                  return;
                }
                if (fromBranchId == toBranchId) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Source and destination must be different')));
                  return;
                }
                final orgId = ref.read(currentUserProvider)?.orgId;
                final userId = ref.read(currentUserProvider)?.id;
                try {
                  final id = 'st_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client.from('stock_transfers').insert({
                    'id': id, 'org_id': orgId,
                    'from_branch_id': fromBranchId, 'to_branch_id': toBranchId,
                    'status': 'pending',
                    'notes': notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
                    'transfer_date': DateFormat('yyyy-MM-dd').format(transferDate),
                    'created_by': userId,
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack('Transfer created');
                  await _load();
                  final transfer = _transfers.firstWhere((t) => t['id'] == id, orElse: () => {});
                  if (transfer.isNotEmpty && mounted) _openTransfer(transfer);
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

  void _openTransfer(Map<String, dynamic> transfer) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _StockTransferDetailScreen(transfer: transfer, onUpdated: _load),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Stock Transfers', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _allBranches.length < 2 ? null : _showCreateDialog,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Transfer'),
          ),
        ]),
        const SizedBox(height: 8),
        Text('${_transfers.length} transfers', style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 24),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                  child: const Row(children: [
                    Expanded(flex: 2, child: Text('From', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('To', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 1, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    SizedBox(width: 48),
                  ]),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _transfers.isEmpty
                      ? const Center(child: Text('No stock transfers yet.', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: _transfers.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final t = _transfers[i];
                            final status = t['status'] as String? ?? 'pending';
                            final date = t['transfer_date'] != null
                                ? DateFormat('d MMM yyyy').format(DateTime.parse(t['transfer_date'] as String)) : '-';
                            return InkWell(
                              onTap: () => _openTransfer(t),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                child: Row(children: [
                                  Expanded(flex: 2, child: Text(t['from_branch']?['name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600))),
                                  Expanded(flex: 2, child: Text(t['to_branch']?['name'] as String? ?? '-', style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600))),
                                  Expanded(flex: 2, child: Text(date, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                                  Expanded(flex: 1, child: Container(
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
            ),
          ),
      ]),
    );
  }
}

class _StockTransferDetailScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> transfer;
  final VoidCallback onUpdated;
  const _StockTransferDetailScreen({required this.transfer, required this.onUpdated});
  @override
  ConsumerState<_StockTransferDetailScreen> createState() => _StockTransferDetailScreenState();
}

class _StockTransferDetailScreenState extends ConsumerState<_StockTransferDetailScreen> {
  late Map<String, dynamic> _transfer;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _uoms = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _transfer = widget.transfer;
    _loadItems();
  }

  Future<void> _loadItems() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    try {
      final client = Supabase.instance.client;
      final items = await client.from('stock_transfer_items')
          .select('*, products(name, sku), uoms(name, abbreviation)')
          .eq('transfer_id', _transfer['id']);
      final products = await client.from('products').select('id, name, sku, base_uom_id')
          .eq('org_id', orgId!).eq('is_active', true).order('name').limit(10000);
      final uoms = await client.from('uoms').select().eq('org_id', orgId).order('name');
      final transferRes = await client.from('stock_transfers')
          .select('*, from_branch:branches!from_branch_id(name), to_branch:branches!to_branch_id(name)')
          .eq('id', _transfer['id']).single();
      setState(() {
        _items = List<Map<String, dynamic>>.from(items);
        _products = List<Map<String, dynamic>>.from(products);
        _uoms = List<Map<String, dynamic>>.from(uoms);
        _transfer = transferRes;
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
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
            width: 420,
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
              Row(children: [
                Expanded(child: TextField(controller: qtyCtrl,
                    decoration: const InputDecoration(labelText: 'Quantity *'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: costCtrl,
                    decoration: const InputDecoration(labelText: 'Unit Cost'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true))),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (productId == null || uomId == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Product and UOM required')));
                  return;
                }
                final qty = double.tryParse(qtyCtrl.text.trim()) ?? 0;
                if (qty <= 0) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Quantity must be > 0')));
                  return;
                }
                try {
                  await Supabase.instance.client.from('stock_transfer_items').insert({
                    'id': 'sti_${DateTime.now().millisecondsSinceEpoch}',
                    'transfer_id': _transfer['id'],
                    'product_id': productId,
                    'uom_id': uomId,
                    'quantity': qty,
                    'unit_cost': double.tryParse(costCtrl.text.trim()) ?? 0,
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

  Future<void> _completeTransfer() async {
    if (_items.isEmpty) { _showSnack('Add items before completing'); return; }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Complete Transfer'),
        content: const Text('Stock will be deducted from source branch and added to destination. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Complete')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final client = Supabase.instance.client;
      final orgId = ref.read(currentUserProvider)?.orgId;
      final userId = ref.read(currentUserProvider)?.id;
      final fromBranchId = _transfer['from_branch_id'] as String;
      final toBranchId = _transfer['to_branch_id'] as String;

      for (final item in _items) {
        final qty = (item['quantity'] as num).toDouble();
        final productId = item['product_id'] as String;
        final uomId = item['uom_id'] as String;
        final now = DateTime.now().toUtc().toIso8601String();

        // Deduct from source
        await client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().millisecondsSinceEpoch}_out',
          'org_id': orgId, 'product_id': productId,
          'branch_id': fromBranchId, 'uom_id': uomId,
          'quantity': -qty, 'movement_type': 'transfer',
          'reference_id': _transfer['id'], 'reference_type': 'stock_transfer',
          'moved_at': now, 'created_by': userId,
        });
        final fromStock = await client.from('inventory_stock').select()
            .eq('org_id', orgId!).eq('product_id', productId).eq('branch_id', fromBranchId).maybeSingle();
        if (fromStock != null) {
          await client.from('inventory_stock').update({
            'quantity': (fromStock['quantity'] as num).toDouble() - qty,
            'updated_at': now,
          }).eq('id', fromStock['id']);
        }

        // Add to destination
        await client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().millisecondsSinceEpoch}_in',
          'org_id': orgId, 'product_id': productId,
          'branch_id': toBranchId, 'uom_id': uomId,
          'quantity': qty, 'movement_type': 'transfer',
          'reference_id': _transfer['id'], 'reference_type': 'stock_transfer',
          'moved_at': now, 'created_by': userId,
        });
        final toStock = await client.from('inventory_stock').select()
            .eq('org_id', orgId).eq('product_id', productId).eq('branch_id', toBranchId).maybeSingle();
        if (toStock != null) {
          await client.from('inventory_stock').update({
            'quantity': (toStock['quantity'] as num).toDouble() + qty,
            'updated_at': now,
          }).eq('id', toStock['id']);
        } else {
          await client.from('inventory_stock').insert({
            'id': 'is_${DateTime.now().millisecondsSinceEpoch}',
            'org_id': orgId, 'product_id': productId,
            'branch_id': toBranchId, 'uom_id': uomId, 'quantity': qty,
          });
        }
      }

      await client.from('stock_transfers').update({
        'status': 'completed',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _transfer['id']);

      _showSnack('Transfer completed — stock updated');
      widget.onUpdated();
      _loadItems();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _cancelTransfer() async {
    try {
      await Supabase.instance.client.from('stock_transfers').update({
        'status': 'cancelled', 'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _transfer['id']);
      _showSnack('Transfer cancelled');
      widget.onUpdated();
      _loadItems();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    final status = _transfer['status'] as String? ?? 'pending';
    final isPending = status == 'pending';
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.white, elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Stock Transfer', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text('${_transfer['from_branch']?['name'] ?? ''} → ${_transfer['to_branch']?['name'] ?? ''}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w400)),
        ]),
        actions: [
          if (isPending) ...[
            ElevatedButton(onPressed: _completeTransfer, child: const Text('Complete Transfer')),
            const SizedBox(width: 8),
            TextButton(onPressed: _cancelTransfer,
                style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
                child: const Text('Cancel')),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  _InfoChip(label: 'Status', value: status[0].toUpperCase() + status.substring(1)),
                  if (_transfer['notes'] != null) ...[
                    const SizedBox(width: 12),
                    _InfoChip(label: 'Notes', value: _transfer['notes'] as String),
                  ],
                ]),
                const SizedBox(height: 24),
                Row(children: [
                  const Text('Items', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (isPending)
                    ElevatedButton.icon(
                        onPressed: _showAddItemDialog,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add Item')),
                ]),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
                    child: Column(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                        child: const Row(children: [
                          Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                          Expanded(flex: 2, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                          Expanded(flex: 2, child: Text('Quantity', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                          Expanded(flex: 2, child: Text('Unit Cost', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
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
                                  final cost = (item['unit_cost'] as num?)?.toDouble() ?? 0;
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                    child: Row(children: [
                                      Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                                        if (item['products']?['sku'] != null)
                                          Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                      ])),
                                      Expanded(flex: 2, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary))),
                                      Expanded(flex: 2, child: Text(qty % 1 == 0 ? qty.toInt().toString() : qty.toString(), style: const TextStyle(fontWeight: FontWeight.w600))),
                                      Expanded(flex: 2, child: Text(cost.toStringAsFixed(2))),
                                      SizedBox(width: 48, child: isPending
                                          ? IconButton(
                                              icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                                              onPressed: () async {
                                                await Supabase.instance.client.from('stock_transfer_items').delete().eq('id', item['id']);
                                                _loadItems();
                                              })
                                          : const SizedBox.shrink()),
                                    ]),
                                  );
                                }),
                      ),
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
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ]),
    );
  }
}
