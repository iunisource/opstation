import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

class ErpPosScreen extends ConsumerStatefulWidget {
  const ErpPosScreen({super.key});
  @override
  ConsumerState<ErpPosScreen> createState() => _ErpPosScreenState();
}

class _ErpPosScreenState extends ConsumerState<ErpPosScreen> {
  Map<String, dynamic>? _activeSession;
  List<Map<String, dynamic>> _sessions = [];
  List<Map<String, dynamic>> _branches = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final userId = ref.read(currentUserProvider)?.id;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final sessions = await client
          .from('pos_sessions')
          .select('*, branches(name)')
          .eq('org_id', orgId)
          .order('opened_at', ascending: false)
          .limit(20);
      final branches = await client
          .from('branches')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      final activeList = (sessions as List).where((s) =>
          s['status'] == 'open' && s['opened_by'] == userId).toList();
      setState(() {
        _sessions = List<Map<String, dynamic>>.from(sessions);
        _branches = List<Map<String, dynamic>>.from(branches);
        _activeSession = activeList.isNotEmpty ? activeList.first : null;
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

  void _showOpenSessionDialog() {
    String? branchId;
    final cashCtrl = TextEditingController(text: '0');
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Open POS Session'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: branchId,
                decoration: const InputDecoration(labelText: 'Branch *'),
                hint: const Text('Select branch'),
                items: _branches.map((w) => DropdownMenuItem(
                    value: w['id'] as String,
                    child: Text(w['name'] as String))).toList(),
                onChanged: (v) => setS(() => branchId = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: cashCtrl,
                decoration: const InputDecoration(
                    labelText: 'Opening Cash',
                    hintText: '0.00'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
                      const SnackBar(content: Text('Select a branch')));
                  return;
                }
                final orgId = ref.read(currentUserProvider)?.orgId;
                final userId = ref.read(currentUserProvider)?.id;
                try {
                  await Supabase.instance.client.from('pos_sessions').insert({
                    'id': 'poss_${DateTime.now().millisecondsSinceEpoch}',
                    'org_id': orgId,
                    'branch_id': branchId,
                    'opened_by': userId,
                    'opening_cash': double.tryParse(cashCtrl.text.trim()) ?? 0,
                    'status': 'open',
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack('Session opened');
                  await _load();
                  if (_activeSession != null && mounted) {
                    _openSession(_activeSession!);
                  }
                } catch (e) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: $e')));
                }
              },
              child: const Text('Open Session'),
            ),
          ],
        ),
      ),
    );
  }

  void _openSession(Map<String, dynamic> session) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PosSessionScreen(session: session, onUpdated: _load),
    ));
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
            const Text('Point of Sale',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            if (_activeSession != null)
              ElevatedButton.icon(
                onPressed: () => _openSession(_activeSession!),
                icon: const Icon(Icons.point_of_sale, size: 18),
                label: const Text('Resume Session'),
              )
            else
              ElevatedButton.icon(
                onPressed: _showOpenSessionDialog,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Open Session'),
              ),
          ]),
          const SizedBox(height: 8),
          if (_activeSession != null)
            Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AppTheme.success.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.success.withOpacity(0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.circle, color: AppTheme.success, size: 10),
                const SizedBox(width: 8),
                Text(
                  'Active session open — ${_activeSession!['branches']?['name'] ?? ''}',
                  style: const TextStyle(color: AppTheme.success, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => _openSession(_activeSession!),
                  child: const Text('Go to session →'),
                ),
              ]),
            ),
          const SizedBox(height: 8),
          const Text('Recent Sessions',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
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
                      Expanded(flex: 2, child: Text('Branch', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Opened', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Closed', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 48),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _sessions.isEmpty
                        ? const Center(child: Text('No sessions yet.', style: TextStyle(color: AppTheme.textSecondary)))
                        : ListView.separated(
                            itemCount: _sessions.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final s = _sessions[i];
                              final isOpen = s['status'] == 'open';
                              final openedAt = s['opened_at'] != null
                                  ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(s['opened_at'] as String).toLocal())
                                  : '-';
                              final closedAt = s['closed_at'] != null
                                  ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(s['closed_at'] as String).toLocal())
                                  : '-';
                              return InkWell(
                                onTap: () => _openSession(s),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  child: Row(children: [
                                    Expanded(flex: 2, child: Text(s['branches']?['name'] as String? ?? '-',
                                        style: const TextStyle(fontWeight: FontWeight.w600))),
                                    Expanded(flex: 2, child: Text(openedAt,
                                        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                    Expanded(flex: 2, child: Text(closedAt,
                                        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                    Expanded(flex: 1, child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: isOpen ? AppTheme.success.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(isOpen ? 'Open' : 'Closed',
                                          style: TextStyle(
                                              color: isOpen ? AppTheme.success : AppTheme.textSecondary,
                                              fontSize: 12, fontWeight: FontWeight.w600)),
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
        ],
      ),
    );
  }
}

class _PosSessionScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> session;
  final VoidCallback onUpdated;
  const _PosSessionScreen({required this.session, required this.onUpdated});
  @override ConsumerState<_PosSessionScreen> createState() => _PosSessionScreenState();
}

class _PosSessionScreenState extends ConsumerState<_PosSessionScreen> {
  late Map<String, dynamic> _session;
  List<Map<String, dynamic>> _transactions = [];
  List<Map<String, dynamic>> _allProducts = [];
  List<Map<String, dynamic>> _displayProducts = [];
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _cart = [];
  Map<String, dynamic>? _selectedCustomer;
  String _paymentMethod = 'cash';
  final _customPaymentCtrl = TextEditingController();
  double _orderDiscount = 0;
  String _orderDiscountType = 'fixed'; // 'fixed' | 'percent'
  bool _loading = true;
  bool _sessionPanelOpen = true;
  String _search = '';
  final _searchCtrl = TextEditingController();
  final _customerSearchCtrl = TextEditingController();
  bool _showCustomerDropdown = false;
  List<Map<String, dynamic>> _filteredCustomers = [];
  List<Map<String, dynamic>> _posCustomers = [];
  Map<String, dynamic>? _selectedPosCustomer;  // quick POS customer
  Map<String, double> _stockMap = {};  // product_id → qty in stock

  @override void initState() { super.initState(); _session = Map.from(widget.session); _loadData(); }
  @override void dispose() { _searchCtrl.dispose(); _customerSearchCtrl.dispose(); _customPaymentCtrl.dispose(); super.dispose(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _isOpen => _session['status'] == 'open';

  void _showSnack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadData() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final branchId = _session['branch_id'] as String? ?? '';
      final results = await Future.wait([
        client.from('pos_transactions').select('*, customers(shop_name), pos_customers(name)').eq('session_id', _session['id']).order('transacted_at', ascending: false),
        client.from('pos_catalog').select('id, name, sku, price, is_active, product_id, uom_id').eq('org_id', orgId).eq('branch_id', branchId).eq('is_active', true).order('name'),
        client.from('customers').select('id, shop_name, code').eq('org_id', orgId).eq('is_active', true).order('shop_name'),
        client.from('pos_sessions').select('*, branches(name)').eq('id', _session['id']).single(),
        client.from('inventory_stock').select('product_id, quantity').eq('org_id', orgId).eq('branch_id', branchId),
        client.from('pos_customers').select('id, name, phone, cnic').eq('org_id', orgId).eq('branch_id', branchId).order('name'),
      ]);
      final prods = List<Map<String, dynamic>>.from(results[1] as List);
      final stockRows = List<Map<String, dynamic>>.from(results[4] as List);
      final stockMap = <String, double>{for (final s in stockRows) s['product_id'] as String: (s['quantity'] as num?)?.toDouble() ?? 0.0};
      // Embed stock qty into each catalog product
      for (final p in prods) { p['stock_qty'] = stockMap[p['product_id'] as String? ?? ''] ?? 0.0; }
      setState(() {
        _transactions = List<Map<String, dynamic>>.from(results[0] as List);
        _allProducts = prods; _displayProducts = prods;
        _customers = List<Map<String, dynamic>>.from(results[2] as List);
        _session = Map<String, dynamic>.from(results[3] as Map);
        _stockMap = stockMap;
        _posCustomers = List<Map<String, dynamic>>.from(results[5] as List);
        _loading = false;
      });
    } catch (e) { _showSnack('Load error: $e'); setState(() => _loading = false); }
  }

  void _filterProducts(String q) {
    setState(() {
      _search = q;
      _displayProducts = q.isEmpty ? _allProducts : _allProducts.where((p) =>
          (p['name'] as String? ?? '').toLowerCase().contains(q.toLowerCase()) ||
          (p['sku'] as String? ?? '').toLowerCase().contains(q.toLowerCase())).toList();
    });
  }

  void _addToCart(Map<String, dynamic> product) {
    final existing = _cart.indexWhere((c) => c['pos_catalog_id'] == product['id']);
    setState(() {
      if (existing >= 0) {
        _cart[existing]['quantity'] = (_cart[existing]['quantity'] as double) + 1;
      } else {
        _cart.add({
          'pos_catalog_id': product['id'],
          'product_id': product['product_id'],
          'name': product['name'],
          'sku': product['sku'],
          'unit_price': (product['price'] as num?)?.toDouble() ?? 0,
          'uom_id': product['uom_id'],
          'quantity': 1.0,
          'discount': 0.0,
          'discount_type': 'fixed',
          'stock_qty': (product['stock_qty'] as num?)?.toDouble() ?? 0.0,
        });
      }
    });
  }

  double _lineSubtotal(Map<String, dynamic> item) {
    final qty = item['quantity'] as double;
    final price = item['unit_price'] as double;
    final disc = item['discount'] as double;
    final discType = item['discount_type'] as String;
    final discAmt = discType == 'percent' ? price * qty * (disc / 100) : disc;
    return (price * qty) - discAmt;
  }

  double get _cartSubtotal => _cart.fold(0, (s, i) => s + (i['unit_price'] as double) * (i['quantity'] as double));
  double get _cartItemDiscounts => _cart.fold(0, (s, i) {
    final d = i['discount'] as double; final qty = i['quantity'] as double; final price = i['unit_price'] as double;
    return s + (i['discount_type'] == 'percent' ? price * qty * (d / 100) : d);
  });
  double get _orderDiscountAmt => _orderDiscountType == 'percent' ? _cartSubtotal * (_orderDiscount / 100) : _orderDiscount;
  double get _cartTotal => (_cartSubtotal - _cartItemDiscounts - _orderDiscountAmt).clamp(0, double.infinity);
  double get _totalDiscount => _cartItemDiscounts + _orderDiscountAmt;

  Future<void> _checkout() async {
    if (_cart.isEmpty) { _showSnack('Cart is empty'); return; }
    if (_cart.any((i) => i['product_id'] == null)) { _showSnack('Some items have no product link — remove and re-add'); return; }
    // Stock check
    for (final item in _cart) {
      final qty = item['quantity'] as double;
      final stock = (item['stock_qty'] as num?)?.toDouble() ?? 0;
      if (qty > stock) { _showSnack('Insufficient stock for "${item['name']}": ${stock.toStringAsFixed(0)} available'); return; }
    }
    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    final branchId = _session['branch_id'] as String;
    try {
      final client = Supabase.instance.client;
      final txnId = 'post_${DateTime.now().millisecondsSinceEpoch}';
      final now = DateTime.now().toUtc().toIso8601String();
      final cartSnapshot = List<Map<String, dynamic>>.from(_cart);
      final totalAmt = _cartTotal;
      final discountAmt = _totalDiscount;
      await client.from('pos_transactions').insert({
        'id': txnId, 'org_id': orgId, 'session_id': _session['id'],
        'customer_id': _selectedCustomer?['id'],
        'pos_customer_id': _selectedPosCustomer?['id'],
        'total': totalAmt, 'discount': discountAmt,
        'payment_method': _paymentMethod == 'other' ? (_customPaymentCtrl.text.trim().isEmpty ? 'other' : _customPaymentCtrl.text.trim()) : _paymentMethod, 'transaction_type': 'sale',
        'created_by': userId, 'transacted_at': now,
      });
      for (final item in cartSnapshot) {
        final qty = item['quantity'] as double;
        final pid = item['product_id'] as String;
        await client.from('pos_transaction_items').insert({
          'id': 'posti_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'transaction_id': txnId, 'product_id': pid,
          'uom_id': item['uom_id'], 'quantity': qty,
          'unit_price': item['unit_price'], 'discount': item['discount'],
        });
        final existing = await client.from('inventory_stock').select()
            .eq('org_id', orgId!).eq('product_id', pid).eq('branch_id', branchId).maybeSingle();
        if (existing != null) {
          await client.from('inventory_stock').update({
            'quantity': (existing['quantity'] as num).toDouble() - qty,
            'updated_at': now,
          }).eq('id', existing['id']);
        }
        await client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'org_id': orgId, 'product_id': pid, 'branch_id': branchId,
          'uom_id': item['uom_id'], 'quantity': -qty, 'movement_type': 'pos',
          'reference_id': txnId, 'reference_type': 'pos_transaction',
          'moved_at': now, 'created_by': userId,
        });
      }
      setState(() { _cart.clear(); _orderDiscount = 0; _selectedCustomer = null; _selectedPosCustomer = null; _customerSearchCtrl.clear(); _paymentMethod = 'cash'; _customPaymentCtrl.clear(); });
      await _loadData();
      // Show receipt
      if (mounted) {
        final txn = _transactions.firstWhere((t) => t['id'] == txnId, orElse: () => {'id': txnId, 'total': totalAmt, 'discount': discountAmt, 'payment_method': _paymentMethod, 'transacted_at': now, 'customers': _selectedCustomer != null ? {'shop_name': _selectedCustomer!['shop_name']} : (_selectedPosCustomer != null ? {'shop_name': _selectedPosCustomer!['name']} : null)});
        await showDialog(context: context, barrierDismissible: false, builder: (_) => _ReceiptDialog(
          transaction: txn, items: cartSnapshot,
          orgName: ref.read(currentUserProvider)?.orgName ?? 'Opstation',
          branchName: _session['branches']?['name'] as String? ?? '',
          cashierName: ref.read(currentUserProvider)?.name ?? '',
        ));
      }
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _processReturn(Map<String, dynamic> originalTxn, List<Map<String, dynamic>> returnItems) async {
    if (returnItems.isEmpty) { _showSnack('Select at least one item'); return; }
    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    final branchId = _session['branch_id'] as String;
    try {
      final client = Supabase.instance.client;
      final retId = 'posr_${DateTime.now().millisecondsSinceEpoch}';
      final now = DateTime.now().toUtc().toIso8601String();
      double returnTotal = returnItems.fold(0, (s, i) => s + ((i['return_qty'] as double) * (i['unit_price'] as double)));
      await client.from('pos_transactions').insert({
        'id': retId, 'org_id': orgId, 'session_id': _session['id'],
        'customer_id': originalTxn['customer_id'],
        'total': -returnTotal, 'discount': 0,
        'payment_method': originalTxn['payment_method'] ?? 'cash',
        'transaction_type': 'return',
        'reference_transaction_id': originalTxn['id'],
        'created_by': userId, 'transacted_at': now,
      });
      for (final item in returnItems) {
        final qty = item['return_qty'] as double;
        final pid = item['product_id'] as String;
        await client.from('pos_transaction_items').insert({
          'id': 'posti_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'transaction_id': retId, 'product_id': pid,
          'uom_id': item['uom_id'], 'quantity': -qty,
          'unit_price': item['unit_price'], 'discount': 0,
        });
        // Add stock back
        final stock = await client.from('inventory_stock').select()
            .eq('org_id', orgId!).eq('product_id', pid).eq('branch_id', branchId).maybeSingle();
        if (stock != null) {
          await client.from('inventory_stock').update({'quantity': (stock['quantity'] as num).toDouble() + qty, 'updated_at': now}).eq('id', stock['id']);
        } else {
          await client.from('inventory_stock').insert({'id': 'is_${DateTime.now().microsecondsSinceEpoch}', 'org_id': orgId, 'product_id': pid, 'branch_id': branchId, 'quantity': qty});
        }
        await client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'org_id': orgId, 'product_id': pid, 'branch_id': branchId,
          'uom_id': item['uom_id'], 'quantity': qty, 'movement_type': 'adjustment',
          'reference_id': retId, 'reference_type': 'pos_return',
          'moved_at': now, 'created_by': userId,
        });
      }
      _showSnack('Return processed — Rs. ${returnTotal.toStringAsFixed(2)} refunded');
      await _loadData();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _showQuickAddCustomer() async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final cnicCtrl = TextEditingController();
    final orgId = _orgId; final branchId = _session['branch_id'] as String?;
    if (orgId == null || branchId == null) return;
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Quick Add Customer'),
      content: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name *', hintText: 'Customer name'), autofocus: true, textCapitalization: TextCapitalization.words),
        const SizedBox(height: 10),
        TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone', hintText: '03XX-XXXXXXX'), keyboardType: TextInputType.phone),
        const SizedBox(height: 10),
        TextField(controller: cnicCtrl, decoration: const InputDecoration(labelText: 'CNIC (optional)', hintText: 'XXXXX-XXXXXXX-X'), keyboardType: TextInputType.number),
      ])),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Add Customer'))],
    ));
    if (ok != true || nameCtrl.text.trim().isEmpty) return;
    try {
      final id = 'posc_${DateTime.now().millisecondsSinceEpoch}';
      await Supabase.instance.client.from('pos_customers').insert({
        'id': id, 'org_id': orgId, 'branch_id': branchId,
        'name': nameCtrl.text.trim(),
        'phone': phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
        'cnic': cnicCtrl.text.trim().isEmpty ? null : cnicCtrl.text.trim(),
      });
      final newCust = {'id': id, 'name': nameCtrl.text.trim(), 'phone': phoneCtrl.text.trim(), 'cnic': cnicCtrl.text.trim(), '_type': 'pos'};
      setState(() { _posCustomers.add(newCust); _selectedPosCustomer = newCust; _selectedCustomer = null; _customerSearchCtrl.clear(); });
      _showSnack('Customer "${nameCtrl.text.trim()}" added');
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _closeSession() async {
    final cashCtrl = TextEditingController(text: '0');
    final notesCtrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Close Session'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: cashCtrl, decoration: const InputDecoration(labelText: 'Closing Cash', prefixText: 'Rs. '), keyboardType: const TextInputType.numberWithOptions(decimal: true), autofocus: true),
        const SizedBox(height: 12),
        TextField(controller: notesCtrl, decoration: const InputDecoration(labelText: 'Notes (optional)'), maxLines: 2),
      ]),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Close Session'))],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('pos_sessions').update({
        'status': 'closed', 'closed_at': DateTime.now().toUtc().toIso8601String(),
        'closing_cash': double.tryParse(cashCtrl.text.trim()) ?? 0,
        'closed_by': ref.read(currentUserProvider)?.id,
        'notes': notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
      }).eq('id', _session['id']);
      await _loadData();
      _exportSummary();
      widget.onUpdated();
      if (mounted) Navigator.of(context).pop();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _exportSummary() async {
    final orgId = _orgId; if (orgId == null) return;
    final client = Supabase.instance.client;
    final txnIds = _transactions.map((t) => t['id'] as String).toList();
    Map<String, List<Map<String, dynamic>>> itemsByTxn = {};
    if (txnIds.isNotEmpty) {
      try {
        final allItems = await client.from('pos_transaction_items').select('*, products(name, sku)').inFilter('transaction_id', txnIds);
        for (final item in allItems as List) {
          final tid = item['transaction_id'] as String;
          itemsByTxn.putIfAbsent(tid, () => []).add(Map<String, dynamic>.from(item));
        }
      } catch (_) {}
    }
    final sales = _transactions.where((t) => (t['transaction_type'] ?? 'sale') == 'sale').toList();
    final returns = _transactions.where((t) => (t['transaction_type'] ?? 'sale') == 'return').toList();
    double totalSales = 0, totalReturns = 0;
    for (final t in sales) totalSales += (t['total'] as num?)?.toDouble() ?? 0;
    for (final t in returns) totalReturns += ((t['total'] as num?)?.toDouble() ?? 0).abs();
    final openingCash = (_session['opening_cash'] as num?)?.toDouble() ?? 0;
    final closingCash = (_session['closing_cash'] as num?)?.toDouble() ?? 0;
    final cashDiff = totalSales - totalReturns + openingCash - closingCash;  // +ve = cash short, -ve = cash over
    final branch = _session['branches']?['name'] as String? ?? '-';
    final user = ref.read(currentUserProvider);
    final cashier = user?.name ?? user?.id ?? '-';
    final openedAt = _session['opened_at'] != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_session['opened_at'] as String).toLocal()) : '-';
    final closedAt = _session['closed_at'] != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_session['closed_at'] as String).toLocal()) : 'Open';

    String txnRows = '';
    for (final t in sales) {
      final tid = t['id'] as String;
      final time = t['transacted_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : '';
      final customer = (t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String;
      final method = t['payment_method'] as String? ?? '';
      final total = (t['total'] as num?)?.toStringAsFixed(2) ?? '0.00';
      final disc = (t['discount'] as num?)?.toDouble() ?? 0;
      final items = itemsByTxn[tid] ?? [];
      final itemStr = items.map((i) { final q = (i['quantity'] as num?)?.toDouble() ?? 0; final p = (i['unit_price'] as num?)?.toDouble() ?? 0; final d = (i['discount'] as num?)?.toDouble() ?? 0; final n = i['products']?['name'] as String? ?? '-'; return '$n × ${q.toStringAsFixed(0)} @ ${p.toStringAsFixed(2)}${d > 0 ? ' (-${d.toStringAsFixed(2)})' : ''}'; }).join('<br>');
      txnRows += '<tr><td>$time</td><td style="font-size:11px;color:#666">${tid.substring(0, 10)}…</td><td>$customer</td><td style="font-size:11px">$itemStr</td><td>$method</td>${disc > 0 ? '<td style="color:#e67e22">-${disc.toStringAsFixed(2)}</td>' : '<td>-</td>'}<td style="text-align:right;font-weight:bold">$total</td></tr>';
    }
    String retRows = '';
    for (final t in returns) {
      final time = t['transacted_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : '';
      final refId = t['reference_transaction_id'] as String? ?? '-';
      final refShort = refId.length > 10 ? '${refId.substring(0, 10)}…' : refId;
      final total = ((t['total'] as num?)?.toDouble() ?? 0).abs().toStringAsFixed(2);
      final customer = (t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String;
      retRows += '<tr style="background:#fff5f5"><td>$time</td><td>$customer</td><td style="font-size:11px;color:#666">← $refShort</td><td style="text-align:right;color:#e74c3c;font-weight:bold">-$total</td></tr>';
    }

    final htmlContent = '''<!DOCTYPE html><html><head><title>POS Session Summary</title>
<style>
*{box-sizing:border-box}body{font-family:Arial,sans-serif;padding:32px;color:#333;max-width:900px;margin:0 auto}
h1{font-size:24px;margin:0 0 4px}h2{font-size:16px;margin:24px 0 10px;color:#555;border-bottom:2px solid #eee;padding-bottom:6px}
.meta{color:#888;font-size:13px;margin-bottom:20px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin-bottom:24px}
.stat{background:#f8f9fa;padding:14px 16px;border-radius:10px;border:1px solid #e9ecef}
.sl{font-size:11px;color:#888;text-transform:uppercase;letter-spacing:.5px;margin-bottom:4px}
.sv{font-size:20px;font-weight:700;color:#2c3e50}
.sv.green{color:#27ae60}.sv.red{color:#e74c3c}.sv.blue{color:#2980b9}
table{width:100%;border-collapse:collapse;font-size:13px}
th{background:#f1f3f5;padding:9px 12px;text-align:left;font-size:12px;font-weight:600;color:#555}
td{padding:8px 12px;border-bottom:1px solid #f0f0f0;vertical-align:top}
tr:hover td{background:#fafafa}.total-row td{font-weight:700;background:#f8f9fa;font-size:14px}
.badge{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}
.badge-sale{background:#d4edda;color:#155724}.badge-ret{background:#f8d7da;color:#721c24}
@media print{body{padding:16px}h1{font-size:20px}}
</style></head><body>
<h1>POS Session Summary</h1>
<div class="meta">Branch: <b>$branch</b> &nbsp;|&nbsp; Cashier: <b>$cashier</b> &nbsp;|&nbsp; Opened: <b>$openedAt</b> &nbsp;|&nbsp; Closed: <b>$closedAt</b></div>
<div class="stats">
  <div class="stat"><div class="sl">Transactions</div><div class="sv blue">${sales.length}</div></div>
  <div class="stat"><div class="sl">Returns</div><div class="sv red">${returns.length}</div></div>
  <div class="stat"><div class="sl">Total Sales</div><div class="sv green">${totalSales.toStringAsFixed(2)}</div></div>
  <div class="stat"><div class="sl">Total Refunds</div><div class="sv red">${totalReturns.toStringAsFixed(2)}</div></div>
  <div class="stat"><div class="sl">Net Sales</div><div class="sv">${(totalSales - totalReturns).toStringAsFixed(2)}</div></div>
  <div class="stat"><div class="sl">Opening Cash</div><div class="sv">${openingCash.toStringAsFixed(2)}</div></div>
  <div class="stat"><div class="sl">Closing Cash</div><div class="sv">${closingCash.toStringAsFixed(2)}</div></div>
  <div class="stat"><div class="sl">Cash Difference</div><div class="sv ' + (cashDiff <= 0 ? 'green' : 'red') + '">' + (cashDiff > 0 ? '-' : '+') + cashDiff.abs().toStringAsFixed(2) + '</div></div>
</div>
${txnRows.isNotEmpty ? '''<h2>Sales Transactions</h2>
<table><thead><tr><th>Time</th><th>Txn #</th><th>Customer</th><th>Items</th><th>Payment</th><th>Discount</th><th>Total</th></tr></thead>
<tbody>$txnRows
<tr class="total-row"><td colspan="6">TOTAL SALES</td><td style="text-align:right">${totalSales.toStringAsFixed(2)}</td></tr>
</tbody></table>''' : ''}
${retRows.isNotEmpty ? '''<h2>Returns &amp; Refunds</h2>
<table><thead><tr><th>Time</th><th>Customer</th><th>Original Txn</th><th>Refund</th></tr></thead>
<tbody>$retRows
<tr class="total-row"><td colspan="3">TOTAL REFUNDS</td><td style="text-align:right;color:#e74c3c">-${totalReturns.toStringAsFixed(2)}</td></tr>
</tbody></table>''' : ''}
<script>window.onload=function(){window.print();}</script>
</body></html>''';

    final blob = html.Blob([htmlContent], 'text/html');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');  // opens in new tab, auto-prints via window.onload
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(icon: const Icon(Icons.arrow_back, color: AppTheme.textPrimary), onPressed: () { widget.onUpdated(); Navigator.of(context).pop(); }),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_session['session_number'] as String? ?? 'POS Session', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          Text(_session['branches']?['name'] as String? ?? '', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
        actions: [
          if (_isOpen) ...[
            TextButton.icon(icon: const Icon(Icons.reply, size: 18), label: const Text('Return'), onPressed: () => _showReturnDialog(), style: TextButton.styleFrom(foregroundColor: Colors.orange)),
            const SizedBox(width: 4),
            TextButton.icon(icon: const Icon(Icons.summarize_outlined, size: 18), label: const Text('Summary'), onPressed: _exportSummary),
            const SizedBox(width: 4),
            ElevatedButton.icon(icon: const Icon(Icons.power_settings_new, size: 16), label: const Text('Close Session'), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger), onPressed: _closeSession),
          ] else ...[
            TextButton.icon(icon: const Icon(Icons.summarize_outlined, size: 18), label: const Text('Export Summary'), onPressed: _exportSummary),
          ],
          const SizedBox(width: 12),
        ],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator()) : Row(children: [
        // ── Products Panel ─────────────────────────────────────────────
        Expanded(child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search products by name or SKU…',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _search.isNotEmpty ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () { _searchCtrl.clear(); _filterProducts(''); }) : null,
              filled: true, fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
            onChanged: _filterProducts,
          )),
          Expanded(child: _displayProducts.isEmpty
              ? Center(child: Text(_search.isEmpty ? 'No products in catalog for this branch.\nAdd products to the POS catalog first.' : 'No products matching "$_search"', textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSecondary)))
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.85),
                  itemCount: _displayProducts.length,
                  itemBuilder: (_, i) {
                    final p = _displayProducts[i];
                    final inCart = _cart.any((c) => c['pos_catalog_id'] == p['id']);
                    return _ProductCard(product: p, inCart: inCart, isOpen: _isOpen, onTap: _isOpen ? () => _addToCart(p) : null);
                  })),
        ])),
        // ── Cart Panel ─────────────────────────────────────────────────
        Container(
          width: 380,
          decoration: const BoxDecoration(color: Colors.white, border: Border(left: BorderSide(color: AppTheme.border))),
          child: Column(children: [
            // Customer
            Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Customer', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary, letterSpacing: 0.5)),
              const SizedBox(height: 4),
              TextField(
                controller: _customerSearchCtrl,
                enabled: _isOpen,
                decoration: InputDecoration(
                  hintText: _selectedPosCustomer != null ? _selectedPosCustomer!['name'] as String : (_selectedCustomer != null ? _selectedCustomer!['shop_name'] as String : 'Walk-in (optional)'),
                  hintStyle: TextStyle(color: (_selectedPosCustomer ?? _selectedCustomer) != null ? AppTheme.primary : AppTheme.textSecondary, fontWeight: (_selectedPosCustomer ?? _selectedCustomer) != null ? FontWeight.w600 : FontWeight.normal),
                  prefixIcon: Icon(_selectedPosCustomer != null ? Icons.person_pin : Icons.person_outline, size: 18, color: (_selectedPosCustomer ?? _selectedCustomer) != null ? AppTheme.primary : AppTheme.textSecondary),
                  suffixIcon: (_selectedPosCustomer ?? _selectedCustomer) != null ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setState(() { _selectedCustomer = null; _selectedPosCustomer = null; _customerSearchCtrl.clear(); })) : null,
                  isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.border)),
                ),
                onChanged: (q) {
                  final ql = q.toLowerCase();
                  final erpMatches = q.isEmpty ? <Map<String, dynamic>>[] : _customers.where((c) => (c['shop_name'] as String? ?? '').toLowerCase().contains(ql)).take(4).map((c) => {...c, '_type': 'erp'}).toList();
                  final posMatches = q.isEmpty ? <Map<String, dynamic>>[] : _posCustomers.where((c) => (c['name'] as String? ?? '').toLowerCase().contains(ql) || (c['phone'] as String? ?? '').contains(ql)).take(4).map((c) => {...c, '_type': 'pos'}).toList();
                  setState(() { _showCustomerDropdown = q.isNotEmpty; _filteredCustomers = [...posMatches, ...erpMatches]; });
                },
              ),
              if (_showCustomerDropdown)
                Container(margin: const EdgeInsets.only(top: 2), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)]),
                  child: Column(children: [
                    ListTile(dense: true, leading: const Icon(Icons.add_circle, color: AppTheme.primary, size: 20), title: const Text('Quick-add new customer', style: TextStyle(fontSize: 13, color: AppTheme.primary, fontWeight: FontWeight.w600)), onTap: () { setState(() => _showCustomerDropdown = false); _showQuickAddCustomer(); }),
                    if (_filteredCustomers.isNotEmpty) const Divider(height: 1),
                    ..._filteredCustomers.map((cx) {
                      final isPos = cx['_type'] == 'pos';
                      final name = isPos ? cx['name'] as String? ?? '-' : cx['shop_name'] as String? ?? '-';
                      final sub = isPos ? cx['phone'] as String? : cx['code'] as String?;
                      return ListTile(dense: true,
                        leading: Icon(isPos ? Icons.person_pin : Icons.business, size: 18, color: isPos ? Colors.purple : AppTheme.textSecondary),
                        title: Text(name, style: const TextStyle(fontSize: 13)),
                        subtitle: sub != null && sub.isNotEmpty ? Text(sub, style: const TextStyle(fontSize: 11)) : null,
                        trailing: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: isPos ? Colors.purple.withOpacity(0.1) : AppTheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Text(isPos ? 'POS' : 'ERP', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: isPos ? Colors.purple : AppTheme.primary))),
                        onTap: () => setState(() {
                          if (isPos) { _selectedPosCustomer = cx; _selectedCustomer = null; } else { _selectedCustomer = cx; _selectedPosCustomer = null; }
                          _customerSearchCtrl.clear(); _showCustomerDropdown = false;
                        }));
                    }),
                  ])),
            ])),
            // Cart items
            Expanded(child: _cart.isEmpty
                ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.shopping_cart_outlined, size: 48, color: Colors.grey.shade300),
                    const SizedBox(height: 8),
                    Text(_isOpen ? 'Tap a product to add it' : 'Session closed', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                  ]))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    itemCount: _cart.length, separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, i) => _CartItemTile(item: _cart[i], isOpen: _isOpen,
                      onQtyChanged: (v) => setState(() => _cart[i]['quantity'] = v),
                      onDiscountChanged: (d, dt) => setState(() { _cart[i]['discount'] = d; _cart[i]['discount_type'] = dt; }),
                      onRemove: () => setState(() => _cart.removeAt(i)),
                      lineTotal: _lineSubtotal(_cart[i]),
                    ))),
            // Order discount + payment + total
            Container(padding: const EdgeInsets.all(12), decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.border))),
              child: Column(children: [
                // Order-level discount
                Row(children: [
                  const Text('Order Discount', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const Spacer(),
                  SizedBox(width: 80, child: TextField(
                    enabled: _isOpen,
                    decoration: const InputDecoration(hintText: '0', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true), textAlign: TextAlign.right,
                    onChanged: (v) => setState(() => _orderDiscount = double.tryParse(v) ?? 0),
                  )),
                  const SizedBox(width: 6),
                  DropdownButton<String>(value: _orderDiscountType, isDense: true, underline: const SizedBox(),
                    items: const [DropdownMenuItem(value: 'fixed', child: Text('Fixed', style: TextStyle(fontSize: 12))), DropdownMenuItem(value: 'percent', child: Text('%', style: TextStyle(fontSize: 12)))],
                    onChanged: _isOpen ? (v) => setState(() => _orderDiscountType = v!) : null),
                ]),
                const SizedBox(height: 6),
                // Payment method
                Row(children: [
                  const Text('Payment', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const Spacer(),
                  SegmentedButton<String>(
                    segments: const [ButtonSegment(value: 'cash', label: Text('Cash', style: TextStyle(fontSize: 11))), ButtonSegment(value: 'card', label: Text('Card', style: TextStyle(fontSize: 11))), ButtonSegment(value: 'other', label: Text('Other', style: TextStyle(fontSize: 11)))],
                    selected: {_paymentMethod},
                    onSelectionChanged: _isOpen ? (s) => setState(() => _paymentMethod = s.first) : null,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  ),
                ]),
              if (_paymentMethod == 'other') ...[
                const SizedBox(height: 6),
                TextField(
                  controller: _customPaymentCtrl,
                  decoration: const InputDecoration(hintText: 'Specify payment method…', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                  textCapitalization: TextCapitalization.words,
                ),
              ],
                const SizedBox(height: 10),
                // Totals
                if (_totalDiscount > 0) Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Discount', style: TextStyle(fontSize: 12, color: Colors.orange)),
                  Text('- ${_totalDiscount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12, color: Colors.orange, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 4),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Total', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  Text('Rs. ${_cartTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.primary)),
                ]),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, height: 48, child: ElevatedButton.icon(
                  icon: const Icon(Icons.check_circle_outline, size: 20),
                  label: Text(_cart.isEmpty ? 'Add items to checkout' : 'Complete Sale — Rs. ${_cartTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(backgroundColor: _cart.isNotEmpty && _isOpen ? AppTheme.primary : Colors.grey, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  onPressed: _cart.isNotEmpty && _isOpen ? _checkout : null,
                )),
              ])),
          ]),
        ),
        // ── Session Drawer (collapsible) ───────────────────────────────
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: _sessionPanelOpen ? 320 : 40,
          decoration: const BoxDecoration(color: Color(0xFFF8F9FA), border: Border(left: BorderSide(color: AppTheme.border))),
          child: Column(children: [
            // Toggle
            InkWell(
              onTap: () => setState(() => _sessionPanelOpen = !_sessionPanelOpen),
              child: Container(height: 48, padding: const EdgeInsets.symmetric(horizontal: 10), color: Colors.white,
                child: Row(children: [
                  Icon(_sessionPanelOpen ? Icons.chevron_right : Icons.chevron_left, color: AppTheme.textSecondary),
                  if (_sessionPanelOpen) ...[const SizedBox(width: 6), const Text('Session', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))],
                ])),
            ),
            if (_sessionPanelOpen) ...[
              // Stats
              Padding(padding: const EdgeInsets.all(12), child: Column(children: [
                Row(children: [
                  Expanded(child: _SessionStat(label: 'Transactions', value: '${_transactions.where((t) => (t['transaction_type'] ?? 'sale') == 'sale').length}', color: AppTheme.primary)),
                  const SizedBox(width: 8),
                  Expanded(child: _SessionStat(label: 'Returns', value: '${_transactions.where((t) => t['transaction_type'] == 'return').length}', color: Colors.orange)),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _SessionStat(label: 'Sales Total', value: _transactions.where((t) => (t['transaction_type'] ?? 'sale') == 'sale').fold(0.0, (s, t) => s + ((t['total'] as num?)?.toDouble() ?? 0)).toStringAsFixed(2), color: AppTheme.success)),
                  const SizedBox(width: 8),
                  Expanded(child: _SessionStat(label: 'Opening Cash', value: (_session['opening_cash'] as num?)?.toStringAsFixed(2) ?? '0', color: AppTheme.textSecondary)),
                ]),
                const SizedBox(height: 8),
                Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(children: [
                    Icon(_isOpen ? Icons.circle : Icons.circle_outlined, size: 10, color: _isOpen ? Colors.green : Colors.grey),
                    const SizedBox(width: 8),
                    Text(_isOpen ? 'Session Open' : 'Session Closed', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _isOpen ? Colors.green : Colors.grey)),
                    const Spacer(),
                    if (!_isOpen) TextButton(onPressed: _exportSummary, child: const Text('Export', style: TextStyle(fontSize: 11))),
                  ])),
              ])),
              const Divider(height: 1),
              // Transactions list
              Expanded(child: _transactions.isEmpty
                  ? const Center(child: Text('No transactions yet', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)))
                  : ListView.separated(
                      padding: const EdgeInsets.all(8),
                      itemCount: _transactions.length, separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (_, i) {
                        final t = _transactions[i];
                        final isReturn = t['transaction_type'] == 'return';
                        final total = (t['total'] as num?)?.toDouble() ?? 0;
                        final time = t['transacted_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : '';
                        final customer = (t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String;
                        return GestureDetector(
                          onTap: isReturn ? null : () async {
                            try {
                              final ti = await Supabase.instance.client.from('pos_transaction_items').select('*, products(name)').eq('transaction_id', t['id'] as String);
                              String? fn; try { final fr = await Supabase.instance.client.from('app_config').select('value').eq('org_id', _orgId!).eq('key', 'org.voucher_footer_note').maybeSingle(); fn = fr?['value'] as String?; } catch (_) {}
                              final ci = (ti as List).map((i) => {'name': i['products']?['name'] ?? '-', 'quantity': (i['quantity'] as num?)?.toDouble() ?? 0.0, 'unit_price': (i['unit_price'] as num?)?.toDouble() ?? 0.0, 'discount': (i['discount'] as num?)?.toDouble() ?? 0.0, 'discount_type': 'fixed'}).toList();
                              if (mounted) await showDialog(context: context, builder: (_) => _ReceiptDialog(transaction: Map<String, dynamic>.from(t), items: List<Map<String, dynamic>>.from(ci), orgName: ref.read(currentUserProvider)?.orgName ?? 'Opstation', branchName: _session['branches']?['name'] as String? ?? '', cashierName: ref.read(currentUserProvider)?.name ?? '', footerNote: fn));
                            } catch (_) {}
                          },
                          child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(
                            color: isReturn ? Colors.red.shade50 : Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: isReturn ? Colors.red.shade100 : AppTheme.border),
                          ), child: Row(children: [
                            Icon(isReturn ? Icons.reply : Icons.receipt_outlined, size: 16, color: isReturn ? Colors.red : AppTheme.primary),
                            const SizedBox(width: 8),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(customer, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                              Text(time, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                            ])),
                            Text('${isReturn ? '-' : ''}${total.abs().toStringAsFixed(2)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: isReturn ? Colors.red : AppTheme.primary)),
                            if (!isReturn) const Icon(Icons.chevron_right, size: 14, color: AppTheme.textSecondary),
                          ])));
                      })),
            ],
          ]),
        ),
      ]),
    );
  }

  void _showReturnDialog() {
    showDialog(context: context, builder: (_) => _ReturnDialog(
      orgId: _orgId ?? '',
      onProcess: _processReturn,
    ));
  }
}

// ── Receipt Dialog ─────────────────────────────────────────────────────────
class _ReceiptDialog extends StatelessWidget {
  final Map<String, dynamic> transaction;
  final List<Map<String, dynamic>> items;
  final String orgName, branchName, cashierName;
  final String? footerNote;
  const _ReceiptDialog({required this.transaction, required this.items, required this.orgName, required this.branchName, required this.cashierName, this.footerNote});

  @override Widget build(BuildContext context) {
    final total = (transaction['total'] as num?)?.toDouble() ?? 0;
    final discount = (transaction['discount'] as num?)?.toDouble() ?? 0;
    final subtotal = items.fold(0.0, (s, i) => s + ((i['unit_price'] as double) * (i['quantity'] as double)));
    final customer = (transaction['pos_customers']?['name'] ?? transaction['customers']?['shop_name'] ?? 'Walk-in') as String;
    final method = (transaction['payment_method'] as String? ?? 'cash').toUpperCase();
    final ts = transaction['transacted_at'] != null ? DateFormat('d MMM yyyy  HH:mm').format(DateTime.parse(transaction['transacted_at'] as String).toLocal()) : DateFormat('d MMM yyyy  HH:mm').format(DateTime.now());
    return Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(orgName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      Text(branchName, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      const Text('SALES RECEIPT', style: TextStyle(fontSize: 11, letterSpacing: 2, color: AppTheme.textSecondary)),
      const SizedBox(height: 12),
      const Divider(),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('Customer: $customer', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ]),
      const SizedBox(height: 12),
      Container(decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(8)), child: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Row(children: const [
          Expanded(flex: 4, child: Text('Item', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          Expanded(flex: 1, child: Text('Qty', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
          Expanded(flex: 2, child: Text('Price', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
          Expanded(flex: 2, child: Text('Disc', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
          Expanded(flex: 2, child: Text('Total', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
        ])),
        const Divider(height: 1),
        ...items.map((it) {
          final qty = it['quantity'] as double; final price = it['unit_price'] as double;
          final disc = it['discount'] as double; final discType = it['discount_type'] as String? ?? 'fixed';
          final discAmt = discType == 'percent' ? price * qty * (disc / 100) : disc;
          final lt = qty * price - discAmt;
          return Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5), child: Row(children: [
            Expanded(flex: 4, child: Text(it['name'] as String? ?? '-', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
            Expanded(flex: 1, child: Text('x${qty.toStringAsFixed(0)}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: Text(price.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: Text(discAmt > 0 ? '-${discAmt.toStringAsFixed(2)}' : '-', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: discAmt > 0 ? Colors.orange : AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text(lt.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          ]));
        }),
      ])),
      const Divider(),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Subtotal', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        Text(subtotal.toStringAsFixed(2), style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      ]),
      if (discount > 0) ...[
        const SizedBox(height: 2),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Total Discount', style: TextStyle(fontSize: 13, color: Colors.orange)),
          Text('- ${discount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, color: Colors.orange, fontWeight: FontWeight.w600)),
        ]),
      ],
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('TOTAL', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        Text('Rs. ${total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.primary)),
      ]),
      const SizedBox(height: 4),
      Text('Payment: $method', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      Text('Cashier: $cashierName', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontStyle: FontStyle.italic)),
      if (footerNote != null && footerNote!.isNotEmpty) ...[
        const Divider(),
        Text(footerNote!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ],
      const SizedBox(height: 20),
      Row(children: [
        Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print'), onPressed: () {
          final rows = items.map((i) { final q = i['quantity'] as double; final p = i['unit_price'] as double; final d = i['discount'] as double; final dt = i['discount_type'] as String? ?? 'fixed'; final da = dt == 'percent' ? p * q * (d / 100) : d; final lt = q * p - da; final n = i['name'] as String? ?? '-'; return '<tr><td>$n</td><td style="text-align:center">${q.toStringAsFixed(0)}</td><td style="text-align:right">${p.toStringAsFixed(2)}</td><td style="text-align:right;color:${da > 0 ? "#e67e22" : "#999"}">${da > 0 ? "-${da.toStringAsFixed(2)}" : "-"}</td><td style="text-align:right;font-weight:bold">${lt.toStringAsFixed(2)}</td></tr>'; }).join();
          final discRow = discount > 0 ? '<tr><td colspan="4" style="color:#e67e22">Total Discount</td><td style="text-align:right;color:#e67e22">-${discount.toStringAsFixed(2)}</td></tr>' : '';
          final footerHtml = (footerNote != null && footerNote!.isNotEmpty) ? '<p style="text-align:center;color:#888;font-size:11px;border-top:1px dashed #ccc;padding-top:8px;margin-top:8px">$footerNote</p>' : '';
          final content = '<!DOCTYPE html><html><head><title>Receipt</title><style>body{font-family:Arial,sans-serif;padding:20px;max-width:320px;margin:0 auto;font-size:12px}h2,h3{text-align:center;margin:4px 0}table{width:100%;border-collapse:collapse;margin:8px 0}th{background:#f5f5f5;padding:5px 6px;font-size:11px;text-align:left}td{padding:5px 6px;border-bottom:1px solid #eee}.total-row td{font-weight:bold;font-size:13px;border-top:2px solid #333}hr{border:none;border-top:1px dashed #ccc;margin:8px 0}</style></head><body><h2>$orgName</h2><h3 style="font-weight:normal;color:#666">$branchName</h3><p style="text-align:center;margin:4px 0">$ts</p><p style="text-align:center;margin:4px 0">Customer: $customer</p><hr><table><thead><tr><th>Item</th><th style="text-align:center">Qty</th><th style="text-align:right">Price</th><th style="text-align:right">Disc</th><th style="text-align:right">Total</th></tr></thead><tbody>$rows<tr><td colspan="4" style="color:#666">Subtotal</td><td style="text-align:right">${subtotal.toStringAsFixed(2)}</td></tr>$discRow<tr class="total-row"><td colspan="4">TOTAL</td><td style="text-align:right">Rs. ${total.toStringAsFixed(2)}</td></tr></tbody></table><p style="text-align:center">Payment: $method | Cashier: $cashierName</p>$footerHtml<script>window.print()</script></body></html>';
          final blob = html.Blob([content], 'text/html'); final url = html.Url.createObjectUrlFromBlob(blob); html.window.open(url, '_blank');
        })),
        const SizedBox(width: 12),
        Expanded(child: ElevatedButton.icon(icon: const Icon(Icons.add_shopping_cart, size: 16), label: const Text('New Sale'), onPressed: () => Navigator.pop(context))),
      ]),
    ]))));
  }
}


class _ReturnDialog extends StatefulWidget {
  final String orgId;
  final Future<void> Function(Map<String, dynamic>, List<Map<String, dynamic>>) onProcess;
  const _ReturnDialog({required this.orgId, required this.onProcess});
  @override State<_ReturnDialog> createState() => _ReturnDialogState();
}
class _ReturnDialogState extends State<_ReturnDialog> {
  List<Map<String, dynamic>> _transactions = [];
  Map<String, dynamic>? _selectedTxn;
  List<Map<String, dynamic>> _txnItems = [];
  bool _loadingTxns = true;
  bool _loadingItems = false;
  String _q = '';
  DateTime? _dateFrom;
  DateTime? _dateTo;
  final Map<String, bool> _selected = {};
  final Map<String, TextEditingController> _qtyCtrls = {};

  @override void initState() { super.initState(); _loadTransactions(); }
  @override void dispose() { for (final c in _qtyCtrls.values) c.dispose(); super.dispose(); }

  Future<void> _loadTransactions() async {
    setState(() => _loadingTxns = true);
    try {
      // Load ALL sale transactions for this org that haven't been returned
      final txns = await Supabase.instance.client
          .from('pos_transactions')
          .select('*, customers(shop_name), pos_customers(name), pos_sessions(session_number, pos_sessions_branch_id:branches(name))')
          .eq('org_id', widget.orgId)
          .eq('transaction_type', 'sale')
          .order('transacted_at', ascending: false)
          .limit(500);
      // Filter out fully returned transactions
      final returnedIds = await Supabase.instance.client
          .from('pos_transactions')
          .select('reference_transaction_id')
          .eq('org_id', widget.orgId)
          .eq('transaction_type', 'return');
      final Set<String> returned = {for (final r in returnedIds as List) r['reference_transaction_id'] as String? ?? ''};
      setState(() {
        _transactions = (txns as List).map((t) => Map<String, dynamic>.from(t)).where((t) => !returned.contains(t['id'] as String)).toList();
        _loadingTxns = false;
      });
    } catch (e) { setState(() => _loadingTxns = false); }
  }

  Future<void> _loadItems(Map<String, dynamic> txn) async {
    setState(() { _selectedTxn = txn; _loadingItems = true; _txnItems = []; _selected.clear(); _qtyCtrls.forEach((_, c) => c.dispose()); _qtyCtrls.clear(); });
    try {
      final items = await Supabase.instance.client
          .from('pos_transaction_items')
          .select('*, products(name, sku)')
          .eq('transaction_id', txn['id'] as String)
          .gt('quantity', 0);
      setState(() {
        _txnItems = List<Map<String, dynamic>>.from(items);
        for (final it in _txnItems) {
          final id = it['id'] as String;
          _selected[id] = false;
          final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
          _qtyCtrls[id] = TextEditingController(text: qty.toStringAsFixed(0));
        }
        _loadingItems = false;
      });
    } catch (e) { setState(() => _loadingItems = false); }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _q.toLowerCase();
    return _transactions.where((t) {
      final custName = ((t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? '') as String).toLowerCase();
      final txnId = (t['id'] as String? ?? '').toLowerCase();
      final phone = (t['pos_customers']?['phone'] as String? ?? '').toLowerCase();
      final matchSearch = q.isEmpty || custName.contains(q) || txnId.contains(q) || phone.contains(q);
      final ts = t['transacted_at'] != null ? DateTime.parse(t['transacted_at'] as String).toLocal() : null;
      final matchFrom = _dateFrom == null || (ts != null && !ts.isBefore(_dateFrom!));
      final matchTo = _dateTo == null || (ts != null && !ts.isAfter(_dateTo!.add(const Duration(days: 1))));
      return matchSearch && matchFrom && matchTo;
    }).toList();
  }

  @override Widget build(BuildContext context) {
    final filtered = _filtered;
    final selectedItems = _txnItems.where((it) => _selected[it['id']] == true).toList();
    final returnTotal = selectedItems.fold(0.0, (s, it) { final qty = double.tryParse(_qtyCtrls[it['id']]?.text ?? '0') ?? 0; final price = (it['unit_price'] as num?)?.toDouble() ?? 0; return s + qty * price; });
    return Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 800, maxHeight: 600), child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Process Return', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const Spacer(),
        Text('${_transactions.length} returnable orders', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      ]),
      const SizedBox(height: 12),
      // Search + date filter row
      Row(children: [
        Expanded(child: TextField(decoration: const InputDecoration(hintText: 'Search by customer name, phone, transaction ID…', prefixIcon: Icon(Icons.search, size: 18), isDense: true), onChanged: (v) => setState(() => _q = v))),
        const SizedBox(width: 8),
        OutlinedButton.icon(icon: const Icon(Icons.date_range, size: 16), label: Text(_dateFrom != null ? DateFormat('d MMM').format(_dateFrom!) : 'From', style: const TextStyle(fontSize: 12)),
          onPressed: () async { final d = await showDatePicker(context: context, initialDate: _dateFrom ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setState(() => _dateFrom = d); }),
        const SizedBox(width: 4),
        OutlinedButton.icon(icon: const Icon(Icons.date_range, size: 16), label: Text(_dateTo != null ? DateFormat('d MMM').format(_dateTo!) : 'To', style: const TextStyle(fontSize: 12)),
          onPressed: () async { final d = await showDatePicker(context: context, initialDate: _dateTo ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setState(() => _dateTo = d); }),
        if (_dateFrom != null || _dateTo != null) ...[
          const SizedBox(width: 4),
          IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setState(() { _dateFrom = null; _dateTo = null; })),
        ],
      ]),
      const SizedBox(height: 12),
      Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Left: transaction list
        Expanded(child: _loadingTxns ? const Center(child: CircularProgressIndicator())
          : filtered.isEmpty ? Center(child: Text(_transactions.isEmpty ? 'No returnable orders found.' : 'No orders match your search.', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)))
          : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final t = filtered[i]; final sel = _selectedTxn?['id'] == t['id'];
                final total = (t['total'] as num?)?.toDouble() ?? 0;
                final ts = t['transacted_at'] != null ? DateFormat('d MMM yyyy  HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : '';
                final custName = (t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String;
                return ListTile(dense: true, selected: sel, selectedTileColor: AppTheme.primary.withOpacity(0.08),
                  title: Row(children: [
                    Expanded(child: Text(custName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                    Text('Rs. ${total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                  ]),
                  subtitle: Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  onTap: () => _loadItems(t));
              })),
        const SizedBox(width: 16),
        // Right: item selection
        Expanded(child: _selectedTxn == null
            ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.touch_app_outlined, size: 32, color: AppTheme.textSecondary), SizedBox(height: 8), Text('Select a transaction to view items', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))]))
            : _loadingItems ? const Center(child: CircularProgressIndicator())
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Select items to return', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                const SizedBox(height: 8),
                Expanded(child: _txnItems.isEmpty ? const Center(child: Text('No items found', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView(children: _txnItems.map((it) {
                      final id = it['id'] as String;
                      final name = it['products']?['name'] as String? ?? it['name'] as String? ?? '-';
                      final origQty = (it['quantity'] as num?)?.toDouble() ?? 0;
                      final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
                      return CheckboxListTile(dense: true, value: _selected[id] ?? false, onChanged: (v) => setState(() => _selected[id] = v ?? false),
                        title: Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        subtitle: Text('${origQty.toStringAsFixed(0)} × Rs. ${price.toStringAsFixed(2)} = Rs. ${(origQty * price).toStringAsFixed(2)}', style: const TextStyle(fontSize: 11)),
                        secondary: SizedBox(width: 72, child: TextField(
                          controller: _qtyCtrls[id],
                          decoration: InputDecoration(labelText: 'Return qty', isDense: true, filled: true, fillColor: _selected[id] == true ? Colors.orange.withOpacity(0.08) : Colors.grey.withOpacity(0.05)),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          enabled: _selected[id] == true,
                          onChanged: (_) => setState(() {}),
                        )));
                    }).toList())),
                if (selectedItems.isNotEmpty) Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [const Text('Refund Total: ', style: TextStyle(fontWeight: FontWeight.w600)), const Spacer(), Text('Rs. ${returnTotal.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.red, fontSize: 15))])),
              ])),
      ])),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          icon: const Icon(Icons.reply, size: 16),
          label: Text('Process Return${selectedItems.isNotEmpty ? ' — Rs. ${returnTotal.toStringAsFixed(2)}' : ''}'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
          onPressed: selectedItems.isEmpty ? null : () async {
            final retItems = selectedItems.map((it) { final qty = double.tryParse(_qtyCtrls[it['id']]?.text ?? '0') ?? 0; return {...it, 'return_qty': qty}; }).toList();
            Navigator.pop(context);
            await widget.onProcess(_selectedTxn!, retItems);
          }),
      ]),
    ]))));
  }
}


class _ProductCard extends StatelessWidget {
  final Map<String, dynamic> product;
  final bool inCart, isOpen;
  final VoidCallback? onTap;
  const _ProductCard({required this.product, required this.inCart, required this.isOpen, this.onTap});
  @override Widget build(BuildContext context) {
    final price = (product['price'] as num?)?.toDouble() ?? 0;
    final stockQty = (product['stock_qty'] as num?)?.toDouble() ?? 0;
    final blocked = isOpen && stockQty <= 0;
    return GestureDetector(onTap: blocked ? null : onTap, child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: blocked ? const Color(0xFFF5F5F5) : (inCart ? AppTheme.primary.withOpacity(0.06) : Colors.white),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: blocked ? Colors.grey.withOpacity(0.3) : (inCart ? AppTheme.primary.withOpacity(0.4) : AppTheme.border), width: inCart ? 1.5 : 1),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [
          Expanded(child: Text(product['name'] as String? ?? '-', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: inCart ? AppTheme.primary : AppTheme.textPrimary), maxLines: 2, overflow: TextOverflow.ellipsis)),
          if (inCart) const Icon(Icons.check_circle, size: 14, color: AppTheme.primary),
        ]),
        if (product['sku'] != null) Text(product['sku'] as String, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        const Spacer(),
        Row(children: [
          Expanded(child: Text('Rs. ${price.toStringAsFixed(2)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: inCart ? AppTheme.primary : AppTheme.textPrimary))),
          _StockBadge(stockQty: stockQty),
        ]),
        if (!isOpen) const Text('Session closed', style: TextStyle(fontSize: 9, color: AppTheme.textSecondary)),
      ]),
    ));
  }
}

class _CartItemTile extends StatefulWidget {
  final Map<String, dynamic> item;
  final bool isOpen;
  final ValueChanged<double> onQtyChanged;
  final void Function(double, String) onDiscountChanged;
  final VoidCallback onRemove;
  final double lineTotal;
  const _CartItemTile({required this.item, required this.isOpen, required this.onQtyChanged, required this.onDiscountChanged, required this.onRemove, required this.lineTotal});
  @override State<_CartItemTile> createState() => _CartItemTileState();
}
class _CartItemTileState extends State<_CartItemTile> {
  late TextEditingController _qtyCtrl;
  @override void initState() { super.initState(); _qtyCtrl = TextEditingController(text: (widget.item['quantity'] as double).toStringAsFixed(0)); }
  @override void didUpdateWidget(_CartItemTile old) { super.didUpdateWidget(old); final q = (widget.item['quantity'] as double).toStringAsFixed(0); if (_qtyCtrl.text != q) _qtyCtrl.text = q; }
  @override void dispose() { _qtyCtrl.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) {
    final qty = widget.item['quantity'] as double;
    final disc = widget.item['discount'] as double;
    final discType = widget.item['discount_type'] as String;
    return Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Row(children: [
          Expanded(child: Text(widget.item['name'] as String? ?? '-', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          Text('Rs. ${widget.lineTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.primary)),
          const SizedBox(width: 4),
          if (widget.isOpen) GestureDetector(onTap: widget.onRemove, child: const Icon(Icons.close, size: 16, color: AppTheme.textSecondary)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          if (widget.isOpen) GestureDetector(onTap: () { if (qty > 1) widget.onQtyChanged(qty - 1); }, child: Container(width: 24, height: 24, decoration: BoxDecoration(color: AppTheme.border, borderRadius: BorderRadius.circular(4)), child: const Icon(Icons.remove, size: 14))),
          const SizedBox(width: 6),
          SizedBox(width: 48, child: TextField(controller: _qtyCtrl, textAlign: TextAlign.center, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700), decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 4, horizontal: 4)), enabled: widget.isOpen, onSubmitted: (v) { final n = double.tryParse(v); if (n != null && n > 0) widget.onQtyChanged(n); else _qtyCtrl.text = qty.toStringAsFixed(0); })),
          const SizedBox(width: 6),
          if (widget.isOpen) GestureDetector(onTap: () => widget.onQtyChanged(qty + 1), child: Container(width: 24, height: 24, decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Icon(Icons.add, size: 14, color: AppTheme.primary))),
          const Spacer(),
          if (widget.isOpen) ...[
            SizedBox(width: 60, child: TextField(decoration: const InputDecoration(hintText: 'Disc', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4)), keyboardType: const TextInputType.numberWithOptions(decimal: true), controller: TextEditingController(text: disc > 0 ? disc.toStringAsFixed(0) : ''), onChanged: (v) => widget.onDiscountChanged(double.tryParse(v) ?? 0, discType), textAlign: TextAlign.right)),
            const SizedBox(width: 4),
            GestureDetector(onTap: () => widget.onDiscountChanged(disc, discType == 'fixed' ? 'percent' : 'fixed'), child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), decoration: BoxDecoration(color: disc > 0 ? Colors.orange.withOpacity(0.1) : AppTheme.background, borderRadius: BorderRadius.circular(4), border: Border.all(color: AppTheme.border)), child: Text(discType == 'percent' ? '%' : 'Rs', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: disc > 0 ? Colors.orange : AppTheme.textSecondary)))),
          ],
        ]),
      ]));
  }
}

class _SessionStat extends StatelessWidget {
  final String label, value;
  final Color? color;
  const _SessionStat({required this.label, required this.value, this.color});
  @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, letterSpacing: 0.5)),
      const SizedBox(height: 2),
      Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color ?? AppTheme.textPrimary)),
    ]));
}

class _StockBadge extends StatelessWidget {
  final double stockQty;
  const _StockBadge({required this.stockQty});
  @override Widget build(BuildContext context) {
    if (stockQty > 10) return const SizedBox.shrink();
    if (stockQty <= 0) return Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: const Text('OUT', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: AppTheme.danger)));
    return Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Text('${stockQty.toStringAsFixed(0)} left', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.orange)));
  }
}
