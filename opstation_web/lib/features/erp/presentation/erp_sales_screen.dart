import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/layout/collapsible_list_pane.dart';
import '../../auth/auth_controller.dart';

// ─── Sales Orders (Master-Detail) ────────────────────────────────────────────

class ErpSalesScreen extends ConsumerStatefulWidget {
  const ErpSalesScreen({super.key});
  @override
  ConsumerState<ErpSalesScreen> createState() => _ErpSalesScreenState();
}

class _ErpSalesScreenState extends ConsumerState<ErpSalesScreen> {
  List<Map<String, dynamic>> _orders = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _uoms = [];
  List<Map<String, dynamic>> _customers = [];
  bool _listLoading = true;
  bool _detailLoading = false;
  String _search = '';
  String _statusFilter = 'all';

  // inline add row
  String? _addProductId;
  String? _addUomId;
  final _addQtyCtrl = TextEditingController(text: '1');
  // inline edit
  final Map<String, TextEditingController> _qtyControllers = {};

  @override
  void initState() { super.initState(); _loadList(); _loadMeta(); }

  @override
  void dispose() {
    _addQtyCtrl.dispose();
    for (final c in _qtyControllers.values) c.dispose();
    super.dispose();
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  Future<void> _loadMeta() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final p = await client.from('products').select('id, name, sku, base_uom_id, selling_price').eq('org_id', orgId).eq('is_active', true).order('name');
      final u = await client.from('uoms').select().eq('org_id', orgId).order('name');
      final c = await client.from('customers').select('id, shop_name, code').eq('org_id', orgId).eq('is_active', true).order('shop_name');
      setState(() { _products = List<Map<String,dynamic>>.from(p); _uoms = List<Map<String,dynamic>>.from(u); _customers = List<Map<String,dynamic>>.from(c); });
    } catch (_) {}
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null) return;
    try {
      var q = Supabase.instance.client.from('sales_orders').select('*, customers(shop_name, code)').eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final res = await q.order('created_at', ascending: false);
      setState(() { _orders = List<Map<String,dynamic>>.from(res); _listLoading = false; });
    } catch (_) { setState(() => _listLoading = false); }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final order = await client.from('sales_orders').select('*, customers(shop_name, code), branches(name)').eq('id', id).single();
      final items = await client.from('sales_order_items').select('*, products(name, sku), uoms(name, abbreviation)').eq('sales_order_id', id);
      _qtyControllers.clear();
      for (final item in items as List) {
        _qtyControllers[item['id'] as String] = TextEditingController(text: (item['quantity'] as num?)?.toStringAsFixed(0) ?? '1');
      }
      setState(() { _detail = Map<String,dynamic>.from(order); _items = List<Map<String,dynamic>>.from(items); _detailLoading = false; });
    } catch (_) { setState(() => _detailLoading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  bool get _isDraft => (_detail['status'] as String? ?? 'draft') == 'draft';
  bool get _isLocked => _detail['is_locked'] as bool? ?? false;
  bool get _canEdit => _isDraft && !_isLocked;

  Future<void> _logAudit(String voucherId, String type, String action, String? details) async {
    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    if (orgId == null) return;
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': orgId, 'voucher_type': type, 'voucher_id': voucherId,
        'action': action, 'details': details, 'performed_by': userId,
      });
    } catch (_) {}
  }

  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    final year = DateTime.now().year;
    try {
      final voucherNum = await Supabase.instance.client.rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_type': 'SO', 'p_year': year});
      final id = 'so_${DateTime.now().millisecondsSinceEpoch}';
      await Supabase.instance.client.from('sales_orders').insert({
        'id': id, 'org_id': orgId, 'branch_id': branchId,
        'voucher_number': voucherNum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'status': 'draft', 'is_locked': false,
        'created_by': ref.read(currentUserProvider)?.id,
      });
      await _logAudit(id, 'SO', 'created', 'Sales Order created');
      _showSnack('SO created');
      await _loadList();
      _loadDetail(id);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _saveHeader() async {
    if (_detail.isEmpty) return;
    try {
      await Supabase.instance.client.from('sales_orders').update({
        'customer_id': _detail['customer_id'],
        'remarks': _detail['remarks'],
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      _showSnack('Saved');
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _addItem() async {
    if (_addProductId == null || _addUomId == null) { _showSnack('Select product and UOM'); return; }
    final qty = double.tryParse(_addQtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) { _showSnack('Enter valid qty'); return; }
    try {
      await Supabase.instance.client.from('sales_order_items').insert({
        'id': 'soi_${DateTime.now().millisecondsSinceEpoch}',
        'sales_order_id': _detail['id'],
        'product_id': _addProductId, 'uom_id': _addUomId,
        'quantity': qty, 'unit_price': 0, 'discount': 0, 'qty_delivered': 0,
      });
      setState(() { _addProductId = null; _addUomId = null; _addQtyCtrl.text = '1'; });
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _deleteItem(String itemId) async {
    try {
      await Supabase.instance.client.from('sales_order_items').delete().eq('id', itemId);
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _confirmOrder() async {
    if (_items.isEmpty) { _showSnack('Add items first'); return; }
    try {
      await Supabase.instance.client.from('sales_orders').update({
        'status': 'confirmed', 'is_locked': true,
        'locked_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      _showSnack('Order confirmed');
      await _loadList();
      _loadDetail(_detail['id'] as String);
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
      }).eq('id', _detail['id']);
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _cancelOrder() async {
    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Cancel Order'),
      content: const Text('Are you sure?'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('No')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Cancel')),
      ],
    ));
    if (confirm != true) return;
    try {
      await Supabase.instance.client.from('sales_orders').update({'status': 'cancelled'}).eq('id', _detail['id']);
      _showSnack('Cancelled');
      await _loadList();
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  List<Map<String, dynamic>> get _filteredOrders {
    return _orders.where((o) {
      final matchStatus = _statusFilter == 'all' || o['status'] == _statusFilter;
      final q = _search.toLowerCase();
      final matchSearch = q.isEmpty ||
          (o['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
          (o['customers']?['shop_name'] as String? ?? '').toLowerCase().contains(q);
      return matchStatus && matchSearch;
    }).toList();
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

  @override
  Widget build(BuildContext context) {
    return CollapsibleListPane(
        listChild: Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Row(children: [
                  const Text('Sales Orders', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 24), onPressed: _createNew, tooltip: 'New SO'),
                ]),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(hintText: 'Search voucher or customer...', prefixIcon: Icon(Icons.search, size: 16), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)),
                  onChanged: (v) => setState(() => _search = v),
                ),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: DropdownButtonFormField<String>(
                  value: _statusFilter,
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All Status', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'draft', child: Text('Draft', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'confirmed', child: Text('Confirmed', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'partially_delivered', child: Text('Partial', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'delivered', child: Text('Delivered', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'cancelled', child: Text('Cancelled', style: TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) => setState(() => _statusFilter = v ?? 'all'),
                )),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _listLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredOrders.isEmpty
                      ? const Center(child: Text('No orders', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)))
                      : ListView.separated(
                          itemCount: _filteredOrders.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final o = _filteredOrders[i];
                            final isSelected = o['id'] == _selectedId;
                            final status = o['status'] as String? ?? 'draft';
                            return InkWell(
                              onTap: () => _loadDetail(o['id'] as String),
                              child: Container(
                                color: isSelected ? AppTheme.primary.withOpacity(0.06) : null,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Text(o['voucher_number'] as String? ?? '-',
                                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: isSelected ? AppTheme.primary : Colors.black87)),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(color: _statusColor(status).withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                                      child: Text(status == 'partially_delivered' ? 'Partial' : status,
                                          style: TextStyle(color: _statusColor(status), fontSize: 10, fontWeight: FontWeight.w600)),
                                    ),
                                  ]),
                                  const SizedBox(height: 2),
                                  Text(o['customers']?['shop_name'] as String? ?? 'Walk-in',
                                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                  Text(o['voucher_date'] != null
                                      ? DateFormat('d MMM yyyy').format(DateTime.parse(o['voucher_date'] as String)) : '',
                                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                ]),
                              ),
                            );
                          }),
            ),
        ]),
        detailChild: _selectedId == null
            ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.receipt_long_outlined, size: 48, color: AppTheme.border),
                const SizedBox(height: 12),
                const Text('Select a Sales Order or create new', style: TextStyle(color: AppTheme.textSecondary)),
                const SizedBox(height: 16),
                ElevatedButton.icon(onPressed: _createNew, icon: const Icon(Icons.add, size: 16), label: const Text('New Sales Order')),
              ]))
            : _detailLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildDetail(),
    );
  }

  Widget _buildDetail() {
    final status = _detail['status'] as String? ?? 'draft';
    final voucherNum = _detail['voucher_number'] as String? ?? '-';
    final isLocked = _detail['is_locked'] as bool? ?? false;
    final custId = _detail['customer_id'] as String?;

    return Column(children: [
      // ── Voucher AppBar ─────────────────────────────────────
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(voucherNum, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Text('Sales Order', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
          const SizedBox(width: 16),
          _StatusChip(status: status.replaceAll('_', ' '), color: _statusColor(status)),
          if (isLocked) ...[const SizedBox(width: 8), const _LockedBadge()],
          const Spacer(),
          if (_canEdit) ...[
            ElevatedButton(onPressed: _confirmOrder, child: const Text('Confirm Order')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _cancelOrder, style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger), child: const Text('Cancel')),
            const SizedBox(width: 8),
          ],
          if (_isDraft)
            IconButton(
              icon: Icon(isLocked ? Icons.lock_open : Icons.lock_outline, color: isLocked ? Colors.orange : AppTheme.textSecondary),
              tooltip: isLocked ? 'Unlock' : 'Lock',
              onPressed: _toggleLock,
            ),
          if (!_isDraft && status != 'cancelled')
            IconButton(
              icon: Icon(isLocked ? Icons.lock_open : Icons.lock_outline, color: isLocked ? Colors.orange : AppTheme.textSecondary),
              tooltip: isLocked ? 'Unlock' : 'Lock',
              onPressed: _toggleLock,
            ),
        ]),
      ),

      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ── Header Fields ───────────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Row(children: [
                  Expanded(child: _InfoRow(label: 'Voucher No.', value: voucherNum)),
                  const SizedBox(width: 16),
                  Expanded(child: _InfoRow(label: 'Date', value: _detail['voucher_date'] != null
                      ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-')),
                  const SizedBox(width: 16),
                  Expanded(child: _InfoRow(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-')),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(flex: 2, child: _canEdit
                      ? DropdownButtonFormField<String>(
                          value: custId,
                          decoration: const InputDecoration(labelText: 'Customer', isDense: true),
                          hint: const Text('Walk-in'),
                          items: [
                            const DropdownMenuItem(value: null, child: Text('Walk-in')),
                            ..._customers.map((c) => DropdownMenuItem(value: c['id'] as String,
                                child: Text('${c['shop_name']} (${c['code']})'))),
                          ],
                          onChanged: (v) async {
                            setState(() => _detail['customer_id'] = v);
                            try {
                              await Supabase.instance.client.from('sales_orders').update({
                                'customer_id': v, 'updated_at': DateTime.now().toUtc().toIso8601String(),
                              }).eq('id', _detail['id']);
                            } catch (_) {}
                          },
                        )
                      : _InfoRow(label: 'Customer', value: _detail['customers']?['shop_name'] as String? ?? 'Walk-in')),
                  const SizedBox(width: 16),
                  Expanded(child: _canEdit
                      ? TextField(
                          controller: TextEditingController(text: _detail['remarks'] as String? ?? ''),
                          decoration: const InputDecoration(labelText: 'Remarks', isDense: true),
                          onChanged: (v) => _detail['remarks'] = v,
                        )
                      : _InfoRow(label: 'Remarks', value: _detail['remarks'] as String? ?? '-')),
                  if (_canEdit) ...[
                    const SizedBox(width: 12),
                    ElevatedButton(onPressed: _saveHeader, child: const Text('Save')),
                  ],
                ]),
              ]),
            ),

            const SizedBox(height: 16),

            // ── Items Table ─────────────────────────────────────
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                // Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
                  child: Row(children: [
                    const Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    const Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    const Expanded(flex: 2, child: Text('Qty Ordered', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    SizedBox(width: _canEdit ? 40 : 0),
                  ]),
                ),
                const Divider(height: 1),
                // Items
                ..._items.map((item) {
                  final qty = (item['quantity'] as num?)?.toDouble() ?? 0;
                  return Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(children: [
                        Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          if (item['products']?['sku'] != null)
                            Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                        ])),
                        Expanded(flex: 1, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                        Expanded(flex: 2, child: _canEdit
                            ? SizedBox(height: 32, child: TextField(
                                controller: _qtyControllers[item['id'] as String],
                                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                onSubmitted: (v) async {
                                  final newQty = double.tryParse(v) ?? qty;
                                  await Supabase.instance.client.from('sales_order_items').update({'quantity': newQty}).eq('id', item['id']);
                                  _loadDetail(_detail['id'] as String);
                                },
                              ))
                            : Text(qty % 1 == 0 ? qty.toInt().toString() : qty.toString(), style: const TextStyle(fontWeight: FontWeight.w600))),
                        if (_canEdit) SizedBox(width: 40, child: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.danger),
                          onPressed: () => _deleteItem(item['id'] as String),
                        )),
                      ]),
                    ),
                    const Divider(height: 1),
                  ]);
                }),
                // Add row
                if (_canEdit) Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Expanded(flex: 4, child: DropdownButtonFormField<String>(
                      value: _addProductId,
                      decoration: const InputDecoration(hintText: 'Select product', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                      hint: const Text('+ Add product', style: TextStyle(color: AppTheme.primary, fontSize: 13)),
                      items: _products.map((p) => DropdownMenuItem(value: p['id'] as String,
                          child: Text('${p['name']}${p['sku'] != null ? ' (${p['sku']})' : ''}', style: const TextStyle(fontSize: 13)))).toList(),
                      onChanged: (v) {
                        setState(() {
                          _addProductId = v;
                          final prod = _products.firstWhere((p) => p['id'] == v, orElse: () => {});
                          _addUomId = prod['base_uom_id'] as String?;
                        });
                      },
                    )),
                    const SizedBox(width: 8),
                    Expanded(flex: 1, child: DropdownButtonFormField<String>(
                      value: _addUomId,
                      decoration: const InputDecoration(hintText: 'UOM', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                      items: _uoms.map((u) => DropdownMenuItem(value: u['id'] as String, child: Text(u['abbreviation'] as String? ?? '', style: const TextStyle(fontSize: 13)))).toList(),
                      onChanged: (v) => setState(() => _addUomId = v),
                    )),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: TextField(
                      controller: _addQtyCtrl,
                      decoration: const InputDecoration(hintText: 'Qty', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onSubmitted: (_) => _addItem(),
                    )),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: const SizedBox.shrink()),
                    SizedBox(width: 40, child: IconButton(
                      icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 20),
                      onPressed: _addItem,
                      tooltip: 'Add item',
                    )),
                  ]),
                ),
              ]),
            ),

            const SizedBox(height: 16),
            _AuditTrailRow(createdBy: _detail['created_by'] as String?, createdAt: _detail['created_at'] as String?),
          ]),
        ),
      ),
    ]);
  }
}

// ─── Delivery Orders (Master-Detail) ─────────────────────────────────────────

class ErpDeliveryOrdersScreen extends ConsumerStatefulWidget {
  const ErpDeliveryOrdersScreen({super.key});
  @override
  ConsumerState<ErpDeliveryOrdersScreen> createState() => _ErpDeliveryOrdersScreenState();
}

class _ErpDeliveryOrdersScreenState extends ConsumerState<ErpDeliveryOrdersScreen> {
  List<Map<String, dynamic>> _orders = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  Map<String, dynamic> _linkedSo = {};
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _soItems = [];
  bool _listLoading = true;
  bool _detailLoading = false;
  String _search = '';
  String _statusFilter = 'all';
  // inline delivery qty
  final Map<String, TextEditingController> _deliverQtyCtrl = {};

  @override
  void initState() { super.initState(); _loadList(); }

  @override
  void dispose() {
    for (final c in _deliverQtyCtrl.values) c.dispose();
    super.dispose();
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId; if (orgId == null) return;
    try {
      var q = Supabase.instance.client.from('delivery_orders')
          .select('*, customers(shop_name), sales_orders(voucher_number)').eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final res = await q.order('created_at', ascending: false);
      setState(() { _orders = List<Map<String,dynamic>>.from(res); _listLoading = false; });
    } catch (_) { setState(() => _listLoading = false); }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final do_ = await client.from('delivery_orders')
          .select('*, customers(shop_name), sales_orders(voucher_number, customer_id), branches(name)')
          .eq('id', id).single();
      final items = await client.from('delivery_order_items')
          .select('*, products(name, sku), uoms(abbreviation)').eq('delivery_order_id', id);
      final soItems = await client.from('sales_order_items')
          .select('*, products(name, sku), uoms(abbreviation)').eq('sales_order_id', do_['so_id'] as String);
      // Load SO details
      final so = await client.from('sales_orders')
          .select('*, customers(shop_name, code), branches(name)').eq('id', do_['so_id'] as String).single();

      // Build delivery qty controllers for available SO items
      final existingSoItemIds = (items as List).map((i) => i['so_item_id'] as String).toSet();
      _deliverQtyCtrl.clear();
      for (final soItem in soItems as List) {
        final ordered = (soItem['quantity'] as num?)?.toDouble() ?? 0;
        final delivered = (soItem['qty_delivered'] as num?)?.toDouble() ?? 0;
        final pending = ordered - delivered;
        if (!existingSoItemIds.contains(soItem['id'] as String) && pending > 0) {
          _deliverQtyCtrl[soItem['id'] as String] = TextEditingController(text: pending.toStringAsFixed(0));
        }
      }

      setState(() {
        _detail = Map<String,dynamic>.from(do_);
        _items = List<Map<String,dynamic>>.from(items);
        _soItems = List<Map<String,dynamic>>.from(soItems);
        _linkedSo = Map<String,dynamic>.from(so);
        _detailLoading = false;
      });
    } catch (_) { setState(() => _detailLoading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  bool get _isLocked => _detail['is_locked'] as bool? ?? false;
  bool get _isSaved => (_detail['status'] as String? ?? 'saved') == 'saved';

  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    // Load confirmed SOs
    final sos = await Supabase.instance.client.from('sales_orders')
        .select('id, voucher_number, customers(shop_name)').eq('org_id', orgId)
        .eq('branch_id', branchId).inFilter('status', ['confirmed', 'partially_delivered']);
    if (!mounted) return;
    if ((sos as List).isEmpty) { _showSnack('No confirmed Sales Orders available'); return; }
    String? soId;
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('New Delivery Order'),
          content: SizedBox(width: 400, child: DropdownButtonFormField<String>(
            value: soId,
            decoration: const InputDecoration(labelText: 'Sales Order *'),
            hint: const Text('Select SO'),
            items: sos.map((s) => DropdownMenuItem(value: s['id'] as String,
                child: Text('${s['voucher_number']} — ${s['customers']?['shop_name'] ?? 'Walk-in'}'))).toList(),
            onChanged: (v) => setS(() => soId = v),
          )),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (soId == null) return;
                final year = DateTime.now().year;
                try {
                  final so = sos.firstWhere((s) => s['id'] == soId);
                  final voucherNum = await Supabase.instance.client.rpc('next_voucher_number',
                      params: {'p_org_id': orgId, 'p_type': 'DO', 'p_year': year});
                  final id = 'do_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client.from('delivery_orders').insert({
                    'id': id, 'org_id': orgId, 'branch_id': branchId,
                    'voucher_number': voucherNum,
                    'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
                    'so_id': soId, 'customer_id': _linkedSo['customer_id'],
                    'status': 'saved', 'is_locked': false,
                    'created_by': ref.read(currentUserProvider)?.id,
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  await _loadList();
                  _loadDetail(id);
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

  Future<void> _logAudit(String voucherId, String type, String action, String? details) async {
    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    if (orgId == null) return;
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': orgId, 'voucher_type': type, 'voucher_id': voucherId,
        'action': action, 'details': details, 'performed_by': userId,
      });
    } catch (_) {}
  }

  Future<void> _saveDeliveryOrder() async {
    await _saveDelivery();
    // Lock the DO after saving
    try {
      await Supabase.instance.client.from('delivery_orders').update({
        'is_locked': true,
        'locked_by': ref.read(currentUserProvider)?.id,
        'locked_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'DO', 'saved', 'Delivery Order saved');
    } catch (_) {}
    // Auto create invoice
    await _createInvoice();
  }

  Future<void> _saveDelivery() async {
    if (_deliverQtyCtrl.isEmpty) { _showSnack('No items to save'); return; }
    final orgId = _orgId;
    final branchId = _detail['branch_id'] as String;
    final userId = ref.read(currentUserProvider)?.id;

    for (final entry in _deliverQtyCtrl.entries) {
      final soItemId = entry.key;
      final deliverQty = double.tryParse(entry.value.text.trim()) ?? 0;
      if (deliverQty <= 0) continue;
      final soItem = _soItems.firstWhere((i) => i['id'] == soItemId, orElse: () => {});
      if (soItem.isEmpty) continue;
      final ordered = (soItem['quantity'] as num?)?.toDouble() ?? 0;
      final alreadyDelivered = (soItem['qty_delivered'] as num?)?.toDouble() ?? 0;
      final pending = ordered - alreadyDelivered;
      if (deliverQty > pending) { _showSnack('${soItem['products']?['name']}: qty exceeds pending (${pending.toStringAsFixed(0)})'); return; }
      // Check stock
      final stock = await Supabase.instance.client.from('inventory_stock').select('quantity')
          .eq('org_id', orgId!).eq('product_id', soItem['product_id'] as String)
          .eq('branch_id', branchId).maybeSingle();
      final available = (stock?['quantity'] as num?)?.toDouble() ?? 0;
      if (deliverQty > available) { _showSnack('${soItem['products']?['name']}: insufficient stock (${available.toStringAsFixed(0)} available)'); return; }
    }

    try {
      for (final entry in _deliverQtyCtrl.entries) {
        final soItemId = entry.key;
        final deliverQty = double.tryParse(entry.value.text.trim()) ?? 0;
        if (deliverQty <= 0) continue;
        final soItem = _soItems.firstWhere((i) => i['id'] == soItemId, orElse: () => {});
        if (soItem.isEmpty) continue;
        final ordered = (soItem['quantity'] as num?)?.toDouble() ?? 0;
        final stock = await Supabase.instance.client.from('inventory_stock').select()
            .eq('org_id', orgId!).eq('product_id', soItem['product_id'] as String)
            .eq('branch_id', branchId).maybeSingle();

        await Supabase.instance.client.from('delivery_order_items').insert({
          'id': 'doi_${DateTime.now().millisecondsSinceEpoch}_${soItemId.substring(0, 4)}',
          'delivery_order_id': _detail['id'],
          'so_item_id': soItemId,
          'product_id': soItem['product_id'],
          'uom_id': soItem['uom_id'],
          'qty_ordered': ordered,
          'qty_available': (stock?['quantity'] as num?)?.toDouble() ?? 0,
          'qty_delivered': deliverQty,
        });
        if (stock != null) {
          await Supabase.instance.client.from('inventory_stock').update({
            'quantity': (stock['quantity'] as num).toDouble() - deliverQty,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', stock['id']);
        }
        await Supabase.instance.client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().millisecondsSinceEpoch}_${soItemId.substring(0, 4)}',
          'org_id': orgId, 'product_id': soItem['product_id'],
          'branch_id': branchId, 'uom_id': soItem['uom_id'],
          'quantity': -deliverQty, 'movement_type': 'sale',
          'reference_id': _detail['id'], 'reference_type': 'delivery_order',
          'moved_at': DateTime.now().toUtc().toIso8601String(), 'created_by': userId,
        });
        final soItemRes = await Supabase.instance.client.from('sales_order_items').select('qty_delivered').eq('id', soItemId).single();
        await Supabase.instance.client.from('sales_order_items').update({
          'qty_delivered': ((soItemRes['qty_delivered'] as num?)?.toDouble() ?? 0) + deliverQty,
        }).eq('id', soItemId);
      }
      // Update SO status
      final allSoItems = await Supabase.instance.client.from('sales_order_items')
          .select('quantity, qty_delivered').eq('sales_order_id', _detail['so_id'] as String);
      bool allDel = true; bool anyDel = false;
      for (final si in allSoItems as List) {
        if (((si['qty_delivered'] as num?)?.toDouble() ?? 0) > 0) anyDel = true;
        if (((si['qty_delivered'] as num?)?.toDouble() ?? 0) < ((si['quantity'] as num?)?.toDouble() ?? 0)) allDel = false;
      }
      await Supabase.instance.client.from('sales_orders').update({
        'status': allDel ? 'delivered' : (anyDel ? 'partially_delivered' : 'confirmed'),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['so_id'] as String);

      _showSnack('Delivery saved — stock deducted');
      await _loadList();
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _createInvoice() async {
    if (_items.isEmpty) { _showSnack('No items to invoice'); return; }
    final orgId = _orgId; final branchId = _detail['branch_id'] as String;
    final userId = ref.read(currentUserProvider)?.id;
    final year = DateTime.now().year;
    try {
      final voucherNum = await Supabase.instance.client.rpc('next_voucher_number',
          params: {'p_org_id': orgId, 'p_type': 'SI', 'p_year': year});
      final siId = 'si_${DateTime.now().millisecondsSinceEpoch}';
      double subtotal = 0;
      final Map<String, double> priceMap = {};
      for (final item in _items) {
        final pid = item['product_id'] as String;
        final prod = await Supabase.instance.client.from('products').select('selling_price').eq('id', pid).single();
        priceMap[pid] = (prod['selling_price'] as num?)?.toDouble() ?? 0;
      }
      final siItems = _items.asMap().entries.map((e) {
        final i = e.key; final item = e.value;
        final qty = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
        final price = priceMap[item['product_id'] as String] ?? 0;
        final lineTotal = qty * price;
        subtotal += lineTotal;
        return {'id': 'sii_${DateTime.now().millisecondsSinceEpoch}_$i', 'product_id': item['product_id'],
            'uom_id': item['uom_id'], 'qty_delivered': qty, 'unit_price': price, 'discount': 0.0, 'line_total': lineTotal};
      }).toList();
      await Supabase.instance.client.from('sales_invoices').insert({
        'id': siId, 'org_id': orgId, 'branch_id': branchId,
        'voucher_number': voucherNum, 'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'so_id': _detail['so_id'], 'do_id': _detail['id'], 'customer_id': _detail['customer_id'],
        'subtotal': subtotal, 'discount_total': 0, 'grand_total': subtotal,
        'is_locked': false, 'created_by': userId,
      });
      for (int i = 0; i < siItems.length; i++) {
        await Supabase.instance.client.from('sales_invoice_items').insert({...siItems[i], 'invoice_id': siId});
      }
      // Update DO status based on SO fulfillment
      final soItemsCheck = await Supabase.instance.client.from('sales_order_items')
          .select('quantity, qty_delivered').eq('sales_order_id', _detail['so_id'] as String);
      bool allDone = true;
      for (final si in soItemsCheck as List) {
        if (((si['qty_delivered'] as num?)?.toDouble() ?? 0) < ((si['quantity'] as num?)?.toDouble() ?? 0)) { allDone = false; break; }
      }
      await Supabase.instance.client.from('delivery_orders').update({
        'status': allDone ? 'invoiced' : 'partially_delivered',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      _showSnack('Invoice $voucherNum created');
      await _loadList();
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('delivery_orders').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  List<Map<String, dynamic>> get _filteredOrders => _orders.where((o) {
    final matchStatus = _statusFilter == 'all' || o['status'] == _statusFilter;
    final q = _search.toLowerCase();
    final matchSearch = q.isEmpty ||
        (o['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
        (o['sales_orders']?['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
        (o['customers']?['shop_name'] as String? ?? '').toLowerCase().contains(q);
    return matchStatus && matchSearch;
  }).toList();

  Color _statusColor(String s) {
    if (s == 'invoiced') return AppTheme.success;
    if (s == 'cancelled') return AppTheme.danger;
    return Colors.blue;
  }

  @override
  Widget build(BuildContext context) {
    return CollapsibleListPane(
        listChild: Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Row(children: [
                  const Text('Delivery Orders', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 24), onPressed: _createNew, tooltip: 'New DO'),
                ]),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(hintText: 'Search DO/SO/customer...', prefixIcon: Icon(Icons.search, size: 16), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)),
                  onChanged: (v) => setState(() => _search = v),
                ),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: DropdownButtonFormField<String>(
                  value: _statusFilter,
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'saved', child: Text('Saved', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'partially_delivered', child: Text('Partial', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'invoiced', child: Text('Invoiced', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'cancelled', child: Text('Cancelled', style: TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) => setState(() => _statusFilter = v ?? 'all'),
                )),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _listLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredOrders.isEmpty
                      ? const Center(child: Text('No DOs', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)))
                      : ListView.separated(
                          itemCount: _filteredOrders.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final o = _filteredOrders[i];
                            final isSelected = o['id'] == _selectedId;
                            final status = o['status'] as String? ?? 'saved';
                            return InkWell(
                              onTap: () => _loadDetail(o['id'] as String),
                              child: Container(
                                color: isSelected ? AppTheme.primary.withOpacity(0.06) : null,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Text(o['voucher_number'] as String? ?? '-',
                                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: isSelected ? AppTheme.primary : Colors.black87)),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(color: _statusColor(status).withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                                      child: Text(status, style: TextStyle(color: _statusColor(status), fontSize: 10, fontWeight: FontWeight.w600)),
                                    ),
                                  ]),
                                  Text('SO: ${o['sales_orders']?['voucher_number'] ?? '-'}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                  Text(o['customers']?['shop_name'] as String? ?? 'Walk-in', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                ]),
                              ),
                            );
                          }),
            ),
          ]),
        detailChild: _selectedId == null
            ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.local_shipping_outlined, size: 48, color: AppTheme.border),
                const SizedBox(height: 12),
                const Text('Select a Delivery Order or create new', style: TextStyle(color: AppTheme.textSecondary)),
                const SizedBox(height: 16),
                ElevatedButton.icon(onPressed: _createNew, icon: const Icon(Icons.add, size: 16), label: const Text('New Delivery Order')),
              ]))
            : _detailLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildDetail(),
    );
  }

  Widget _buildDetail() {
    final status = _detail['status'] as String? ?? 'saved';
    final isInvoiced = status == 'invoiced';
    final pendingSoItems = _soItems.where((i) {
      final ordered = (i['quantity'] as num?)?.toDouble() ?? 0;
      final delivered = (i['qty_delivered'] as num?)?.toDouble() ?? 0;
      final existingSoItemIds = _items.map((di) => di['so_item_id'] as String).toSet();
      return !existingSoItemIds.contains(i['id'] as String) && delivered < ordered;
    }).toList();

    return Column(children: [
      // AppBar
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_detail['voucher_number'] as String? ?? '-', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const Text('Delivery Order', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
          const SizedBox(width: 12),
          _StatusChip(status: status, color: status == 'invoiced' ? AppTheme.success : Colors.blue),
          if (_isLocked) ...[const SizedBox(width: 8), const _LockedBadge()],
          const Spacer(),
          if (_isSaved && !_isLocked) ...[
            if (pendingSoItems.isNotEmpty)
              ElevatedButton(onPressed: _saveDeliveryOrder, child: const Text('Save Delivery Order')),
            const SizedBox(width: 8),
            if (_items.isNotEmpty)
              ElevatedButton(
                onPressed: _createInvoice,
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
                child: const Text('Create Invoice'),
              ),
            const SizedBox(width: 8),
          ],
          if (!isInvoiced)
            IconButton(
              icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, color: _isLocked ? Colors.orange : AppTheme.textSecondary),
              tooltip: _isLocked ? 'Unlock' : 'Lock',
              onPressed: _toggleLock,
            ),
        ]),
      ),

      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Linked SO info
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.04),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.primary.withOpacity(0.2)),
              ),
              child: Row(children: [
                const Icon(Icons.link, size: 16, color: AppTheme.primary),
                const SizedBox(width: 8),
                Text('Sales Order: ', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                Text(_linkedSo['voucher_number'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary)),
                const SizedBox(width: 16),
                Text(_linkedSo['customers']?['shop_name'] as String? ?? 'Walk-in', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                if (_linkedSo['voucher_date'] != null) ...[
                  const SizedBox(width: 16),
                  Text(DateFormat('d MMM yyyy').format(DateTime.parse(_linkedSo['voucher_date'] as String)),
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ],
                const SizedBox(width: 16),
                _StatusChip(
                  status: (_linkedSo['status'] as String? ?? '').replaceAll('_', ' '),
                  color: _statusColor(_linkedSo['status'] as String? ?? ''),
                ),
              ]),
            ),

            const SizedBox(height: 12),

            // DO header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Row(children: [
                Expanded(child: _InfoRow(label: 'DO No.', value: _detail['voucher_number'] as String? ?? '-')),
                const SizedBox(width: 16),
                Expanded(child: _InfoRow(label: 'Date', value: _detail['voucher_date'] != null
                    ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-')),
                const SizedBox(width: 16),
                Expanded(child: _InfoRow(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-')),
              ]),
            ),

            const SizedBox(height: 16),

            // Delivered items
            if (_items.isNotEmpty) ...[
              const Text('Delivered Items', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
                    child: const Row(children: [
                      Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('SO Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Available', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Delivered', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    ]),
                  ),
                  const Divider(height: 1),
                  ..._items.map((item) => Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(children: [
                        Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          if (item['products']?['sku'] != null) Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                        ])),
                        Expanded(flex: 1, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                        Expanded(flex: 2, child: Text((item['qty_ordered'] as num?)?.toStringAsFixed(0) ?? '-', style: const TextStyle(fontWeight: FontWeight.w600))),
                        Expanded(flex: 2, child: Text((item['qty_available'] as num?)?.toStringAsFixed(0) ?? '-',
                            style: TextStyle(color: ((item['qty_available'] as num?)?.toDouble() ?? 0) > 0 ? AppTheme.success : AppTheme.danger, fontWeight: FontWeight.w600))),
                        Expanded(flex: 2, child: Text((item['qty_delivered'] as num?)?.toStringAsFixed(0) ?? '-',
                            style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                      ]),
                    ),
                    const Divider(height: 1),
                  ])),
                ]),
              ),
              const SizedBox(height: 16),
            ],

            // Pending SO items for delivery entry
            if (!_isLocked && _isSaved && pendingSoItems.isNotEmpty) ...[
              Row(children: [
                const Text('Add Delivery from SO', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                  child: Text('${pendingSoItems.length} pending', style: const TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange.withOpacity(0.3))),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(color: Colors.orange.withOpacity(0.05), borderRadius: const BorderRadius.vertical(top: Radius.circular(8))),
                    child: const Row(children: [
                      Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Pending', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Deliver Qty *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.primary))),
                    ]),
                  ),
                  const Divider(height: 1),
                  ...pendingSoItems.map((item) {
                    final ordered = (item['quantity'] as num?)?.toDouble() ?? 0;
                    final delivered = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
                    final pending = ordered - delivered;
                    final ctrl = _deliverQtyCtrl[item['id'] as String];
                    return Column(children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(children: [
                          Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            if (item['products']?['sku'] != null) Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                          ])),
                          Expanded(flex: 1, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                          Expanded(flex: 2, child: Text(pending.toStringAsFixed(0), style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.w600))),
                          Expanded(flex: 2, child: ctrl != null ? SizedBox(height: 32, child: TextField(
                            controller: ctrl,
                            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          )) : const SizedBox.shrink()),
                        ]),
                      ),
                      const Divider(height: 1),
                    ]);
                  }),
                ]),
              ),
            ],

            const SizedBox(height: 16),
            _AuditTrailRow(createdBy: _detail['created_by'] as String?, createdAt: _detail['created_at'] as String?),
          ]),
        ),
      ),
    ]);
  }
}

// ─── Sales Invoices (Master-Detail) ──────────────────────────────────────────

class ErpSalesInvoicesScreen extends ConsumerStatefulWidget {
  const ErpSalesInvoicesScreen({super.key});
  @override
  ConsumerState<ErpSalesInvoicesScreen> createState() => _ErpSalesInvoicesScreenState();
}

class _ErpSalesInvoicesScreenState extends ConsumerState<ErpSalesInvoicesScreen> {
  List<Map<String, dynamic>> _invoices = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _items = [];
  bool _listLoading = true;
  bool _detailLoading = false;
  String _search = '';
  final Map<String, TextEditingController> _discountCtrl = {};

  @override
  void initState() { super.initState(); _loadList(); }

  @override
  void dispose() {
    for (final c in _discountCtrl.values) c.dispose();
    super.dispose();
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId; if (orgId == null) return;
    try {
      var q = Supabase.instance.client.from('sales_invoices')
          .select('*, customers(shop_name), sales_orders(voucher_number), delivery_orders(voucher_number)')
          .eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final res = await q.order('created_at', ascending: false);
      setState(() { _invoices = List<Map<String,dynamic>>.from(res); _listLoading = false; });
    } catch (_) { setState(() => _listLoading = false); }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final inv = await client.from('sales_invoices')
          .select('*, customers(shop_name, code), sales_orders(voucher_number, customers(shop_name)), delivery_orders(voucher_number), branches(name)')
          .eq('id', id).single();
      final items = await client.from('sales_invoice_items')
          .select('*, products(name, sku), uoms(abbreviation)').eq('invoice_id', id);
      _discountCtrl.clear();
      for (final item in items as List) {
        _discountCtrl[item['id'] as String] = TextEditingController(text: (item['discount'] as num?)?.toStringAsFixed(2) ?? '0');
      }
      setState(() { _detail = Map<String,dynamic>.from(inv); _items = List<Map<String,dynamic>>.from(items); _detailLoading = false; });
    } catch (_) { setState(() => _detailLoading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  bool get _isLocked => _detail['is_locked'] as bool? ?? true;

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('sales_invoices').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
      }).eq('id', _detail['id']);
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _saveDiscounts() async {
    try {
      double subtotal = 0, discountTotal = 0;
      for (final item in _items) {
        final qty = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
        final price = (item['unit_price'] as num?)?.toDouble() ?? 0;
        final discPct = double.tryParse(_discountCtrl[item['id'] as String]?.text ?? '0') ?? 0;
        final discAmt = qty * price * discPct / 100;
        final lineTotal = (qty * price) - discAmt;
        subtotal += qty * price;
        discountTotal += discAmt;
        await Supabase.instance.client.from('sales_invoice_items').update({'discount': discPct, 'line_total': lineTotal}).eq('id', item['id']);
      }
      await Supabase.instance.client.from('sales_invoices').update({
        'subtotal': subtotal, 'discount_total': discountTotal, 'grand_total': subtotal - discountTotal,
      }).eq('id', _detail['id']);
      _showSnack('Saved');
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  List<Map<String, dynamic>> get _filteredInvoices => _invoices.where((i) {
    final q = _search.toLowerCase();
    return q.isEmpty ||
        (i['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
        (i['sales_orders']?['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
        (i['customers']?['shop_name'] as String? ?? '').toLowerCase().contains(q);
  }).toList();

  @override
  Widget build(BuildContext context) {
    return CollapsibleListPane(
        listChild: Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                const Align(alignment: Alignment.centerLeft, child: Text('Sales Invoices', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(hintText: 'Search SI/SO/customer...', prefixIcon: Icon(Icons.search, size: 16), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _listLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredInvoices.isEmpty
                      ? const Center(child: Text('No invoices', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)))
                      : ListView.separated(
                          itemCount: _filteredInvoices.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final inv = _filteredInvoices[i];
                            final isSelected = inv['id'] == _selectedId;
                            final isLocked = inv['is_locked'] as bool? ?? false;
                            return InkWell(
                              onTap: () => _loadDetail(inv['id'] as String),
                              child: Container(
                                color: isSelected ? AppTheme.primary.withOpacity(0.06) : null,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Text(inv['voucher_number'] as String? ?? '-',
                                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: isSelected ? AppTheme.primary : Colors.black87)),
                                    const Spacer(),
                                    if (isLocked) const Icon(Icons.lock_outline, size: 12, color: Colors.orange),
                                  ]),
                                  Text('SO: ${inv['sales_orders']?['voucher_number'] ?? '-'} · DO: ${inv['delivery_orders']?['voucher_number'] ?? '-'}',
                                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                  Text(inv['customers']?['shop_name'] as String? ?? 'Walk-in', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                  Text('Total: ${(inv['grand_total'] as num?)?.toStringAsFixed(2) ?? '0'}',
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                                ]),
                              ),
                            );
                          }),
            ),
          ]),
        detailChild: _selectedId == null
            ? const Center(child: Text('Select a Sales Invoice', style: TextStyle(color: AppTheme.textSecondary)))
            : _detailLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildDetail(),
    );
  }

  Widget _buildDetail() {
    final subtotal = (_detail['subtotal'] as num?)?.toDouble() ?? 0;
    final discountTotal = (_detail['discount_total'] as num?)?.toDouble() ?? 0;
    final grandTotal = (_detail['grand_total'] as num?)?.toDouble() ?? 0;

    return Column(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_detail['voucher_number'] as String? ?? '-', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const Text('Sales Invoice', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
          const SizedBox(width: 12),
          if (_isLocked) const _LockedBadge(),
          const Spacer(),
          if (!_isLocked) ...[
            ElevatedButton(onPressed: _saveDiscounts, child: const Text('Save')),
            const SizedBox(width: 8),
          ],
          IconButton(
            icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, color: _isLocked ? Colors.orange : AppTheme.textSecondary),
            tooltip: _isLocked ? 'Unlock' : 'Lock',
            onPressed: _toggleLock,
          ),
        ]),
      ),

      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Header info
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Row(children: [
                  Expanded(child: _InfoRow(label: 'SI No.', value: _detail['voucher_number'] as String? ?? '-')),
                  const SizedBox(width: 16),
                  Expanded(child: _InfoRow(label: 'Date', value: _detail['voucher_date'] != null
                      ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-')),
                  const SizedBox(width: 16),
                  Expanded(child: _InfoRow(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-')),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _InfoRow(label: 'Customer', value: _detail['customers']?['shop_name'] as String? ?? _detail['sales_orders']?['customers']?['shop_name'] as String? ?? 'Walk-in')),
                  const SizedBox(width: 16),
                  Expanded(child: _InfoRow(label: 'SO #', value: _detail['sales_orders']?['voucher_number'] as String? ?? '-')),
                  const SizedBox(width: 16),
                  Expanded(child: _InfoRow(label: 'DO #', value: _detail['delivery_orders']?['voucher_number'] as String? ?? '-')),
                ]),
              ]),
            ),

            const SizedBox(height: 16),

            // Items
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
                  child: const Row(children: [
                    Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Unit Price', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Discount', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Line Total', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                  ]),
                ),
                const Divider(height: 1),
                ..._items.map((item) {
                  final qty = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
                  final price = (item['unit_price'] as num?)?.toDouble() ?? 0;
                  final disc = double.tryParse(_discountCtrl[item['id'] as String]?.text ?? '0') ?? 0;
                  final lineTotal = (qty * price) - disc;
                  return Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(children: [
                        Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          if (item['products']?['sku'] != null) Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                        ])),
                        Expanded(flex: 1, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                        Expanded(flex: 2, child: Text(qty.toStringAsFixed(0), style: const TextStyle(fontWeight: FontWeight.w600))),
                        Expanded(flex: 2, child: Text(price.toStringAsFixed(2))),
                        Expanded(flex: 2, child: _isLocked
                            ? Text(disc.toStringAsFixed(2))
                            : SizedBox(height: 32, child: TextField(
                                controller: _discountCtrl[item['id'] as String],
                                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                onChanged: (_) => setState(() {}),
                              ))),
                        Expanded(flex: 2, child: Text(lineTotal.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.w700))),
                      ]),
                    ),
                    const Divider(height: 1),
                  ]);
                }),
                // Totals
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    _TotalsRow(label: 'Subtotal', value: subtotal.toStringAsFixed(2)),
                    _TotalsRow(label: 'Discount', value: '- ${discountTotal.toStringAsFixed(2)}', color: Colors.orange),
                    const Divider(),
                    _TotalsRow(label: 'Grand Total', value: grandTotal.toStringAsFixed(2), bold: true),
                  ]),
                ),
              ]),
            ),

            const SizedBox(height: 16),
            _AuditTrailRow(createdBy: _detail['created_by'] as String?, createdAt: _detail['created_at'] as String?),
          ]),
        ),
      ),
    ]);
  }
}

// ─── Shared Widgets ───────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final String status;
  final Color color;
  const _StatusChip({required this.status, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
    child: Text(status, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
  );
}

class _LockedBadge extends StatelessWidget {
  const _LockedBadge();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
    child: const Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.lock_outline, size: 12, color: Colors.orange),
      SizedBox(width: 4),
      Text('Locked', style: TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.w600)),
    ]),
  );
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w500)),
    const SizedBox(height: 2),
    Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
  ]);
}

class _TotalsRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final Color? color;
  const _TotalsRow({required this.label, required this.value, this.bold = false, this.color});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label: ', style: TextStyle(fontSize: bold ? 14 : 12, color: AppTheme.textSecondary, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
      Text(value, style: TextStyle(fontSize: bold ? 15 : 13, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color)),
    ]),
  );
}

class _AuditTrailRow extends StatelessWidget {
  final String? createdBy;
  final String? createdAt;
  const _AuditTrailRow({this.createdBy, this.createdAt});
  @override
  Widget build(BuildContext context) {
    if (createdBy == null && createdAt == null) return const SizedBox.shrink();
    return FutureBuilder<String>(
      future: _resolveName(createdBy),
      builder: (_, snap) {
        final name = snap.data ?? createdBy ?? '-';
        final date = createdAt != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(createdAt!).toLocal()) : '-';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
  static Future<String> _resolveName(String? id) async {
    if (id == null) return '-';
    try {
      final res = await Supabase.instance.client.from('users').select('name').eq('id', id).maybeSingle();
      return res?['name'] as String? ?? id;
    } catch (_) { return id; }
  }
}
