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
  List<Map<String, dynamic>> _warehouses = [];
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
          .select('*, warehouses(name)')
          .eq('org_id', orgId)
          .order('opened_at', ascending: false)
          .limit(20);
      final warehouses = await client
          .from('warehouses')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      final activeList = (sessions as List).where((s) =>
          s['status'] == 'open' && s['opened_by'] == userId).toList();
      setState(() {
        _sessions = List<Map<String, dynamic>>.from(sessions);
        _warehouses = List<Map<String, dynamic>>.from(warehouses);
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
    String? warehouseId;
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
                value: warehouseId,
                decoration: const InputDecoration(labelText: 'Warehouse *'),
                hint: const Text('Select warehouse'),
                items: _warehouses.map((w) => DropdownMenuItem(
                    value: w['id'] as String,
                    child: Text(w['name'] as String))).toList(),
                onChanged: (v) => setS(() => warehouseId = v),
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
                if (warehouseId == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Select a warehouse')));
                  return;
                }
                final orgId = ref.read(currentUserProvider)?.orgId;
                final userId = ref.read(currentUserProvider)?.id;
                try {
                  await Supabase.instance.client.from('pos_sessions').insert({
                    'id': 'poss_${DateTime.now().millisecondsSinceEpoch}',
                    'org_id': orgId,
                    'warehouse_id': warehouseId,
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
                  'Active session open — ${_activeSession!['warehouses']?['name'] ?? ''}',
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
                      Expanded(flex: 2, child: Text('Warehouse', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
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
                                    Expanded(flex: 2, child: Text(s['warehouses']?['name'] as String? ?? '-',
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
  @override
  ConsumerState<_PosSessionScreen> createState() => _PosSessionScreenState();
}

class _PosSessionScreenState extends ConsumerState<_PosSessionScreen> {
  late Map<String, dynamic> _session;
  List<Map<String, dynamic>> _transactions = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _uoms = [];
  bool _loading = true;

  // Cart
  final List<Map<String, dynamic>> _cart = [];
  String? _selectedCustomerId;
  String _paymentMethod = 'cash';
  double _cartDiscount = 0;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _loadData();
  }

  Future<void> _loadData() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    try {
      final client = Supabase.instance.client;
      final txns = await client
          .from('pos_transactions')
          .select('*, customers(shop_name)')
          .eq('session_id', _session['id'])
          .order('transacted_at', ascending: false);
      final products = await client
          .from('products')
          .select('id, name, sku, selling_price, base_uom_id, uoms(abbreviation)')
          .eq('org_id', orgId!)
          .eq('is_active', true)
          .order('name');
      final uoms = await client.from('uoms').select().eq('org_id', orgId).order('name');
      final sessionRes = await client
          .from('pos_sessions')
          .select('*, warehouses(name)')
          .eq('id', _session['id'])
          .single();
      setState(() {
        _transactions = List<Map<String, dynamic>>.from(txns);
        _products = List<Map<String, dynamic>>.from(products);
        _uoms = List<Map<String, dynamic>>.from(uoms);
        _session = sessionRes;
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

  void _addToCart(Map<String, dynamic> product) {
    final existing = _cart.indexWhere((c) => c['product_id'] == product['id']);
    setState(() {
      if (existing >= 0) {
        _cart[existing]['quantity'] = (_cart[existing]['quantity'] as double) + 1;
      } else {
        _cart.add({
          'product_id': product['id'],
          'name': product['name'],
          'sku': product['sku'],
          'unit_price': (product['selling_price'] as num?)?.toDouble() ?? 0,
          'uom_id': product['base_uom_id'],
          'uom_abbr': product['uoms']?['abbreviation'] ?? '',
          'quantity': 1.0,
          'discount': 0.0,
        });
      }
    });
  }

  double get _cartTotal {
    double total = 0;
    for (final item in _cart) {
      total += ((item['quantity'] as double) * (item['unit_price'] as double)) -
          (item['discount'] as double);
    }
    return total - _cartDiscount;
  }

  Future<void> _checkout() async {
    if (_cart.isEmpty) { _showSnack('Cart is empty'); return; }
    final orgId = ref.read(currentUserProvider)?.orgId;
    final userId = ref.read(currentUserProvider)?.id;
    final warehouseId = _session['warehouse_id'] as String;
    try {
      final client = Supabase.instance.client;
      final txnId = 'post_${DateTime.now().millisecondsSinceEpoch}';
      await client.from('pos_transactions').insert({
        'id': txnId,
        'org_id': orgId,
        'session_id': _session['id'],
        'customer_id': _selectedCustomerId,
        'total': _cartTotal,
        'discount': _cartDiscount,
        'payment_method': _paymentMethod,
        'created_by': userId,
      });
      for (final item in _cart) {
        final qty = item['quantity'] as double;
        await client.from('pos_transaction_items').insert({
          'id': 'posti_${DateTime.now().millisecondsSinceEpoch}_${item['product_id'].toString().substring(0, 4)}',
          'transaction_id': txnId,
          'product_id': item['product_id'],
          'uom_id': item['uom_id'],
          'quantity': qty,
          'unit_price': item['unit_price'],
          'discount': item['discount'],
        });
        // Deduct from stock
        await client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().millisecondsSinceEpoch}_${item['product_id'].toString().substring(0, 4)}',
          'org_id': orgId,
          'product_id': item['product_id'],
          'warehouse_id': warehouseId,
          'uom_id': item['uom_id'],
          'quantity': -qty,
          'movement_type': 'pos',
          'reference_id': txnId,
          'reference_type': 'pos_transaction',
          'moved_at': DateTime.now().toUtc().toIso8601String(),
          'created_by': userId,
        });
        final existing = await client
            .from('inventory_stock')
            .select()
            .eq('org_id', orgId!)
            .eq('product_id', item['product_id'] as String)
            .eq('warehouse_id', warehouseId)
            .maybeSingle();
        if (existing != null) {
          final newQty = (existing['quantity'] as num).toDouble() - qty;
          await client.from('inventory_stock').update({
            'quantity': newQty,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', existing['id']);
        }
      }
      setState(() {
        _cart.clear();
        _cartDiscount = 0;
        _selectedCustomerId = null;
        _paymentMethod = 'cash';
      });
      _showSnack('Sale completed — ${_cartTotal.toStringAsFixed(2)}');
      _loadData();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _closeSession() async {
    final cashCtrl = TextEditingController(text: '0');
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Close Session'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Enter closing cash amount:'),
          const SizedBox(height: 12),
          TextField(
            controller: cashCtrl,
            decoration: const InputDecoration(labelText: 'Closing Cash'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Close Session')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client.from('pos_sessions').update({
        'status': 'closed',
        'closed_at': DateTime.now().toUtc().toIso8601String(),
        'closing_cash': double.tryParse(cashCtrl.text.trim()) ?? 0,
      }).eq('id', _session['id']);
      _showSnack('Session closed');
      widget.onUpdated();
      if (mounted) Navigator.of(context).pop();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    final isOpen = _session['status'] == 'open';
    double sessionTotal = 0;
    for (final t in _transactions) {
      sessionTotal += (t['total'] as num?)?.toDouble() ?? 0;
    }
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('POS Session', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text(_session['warehouses']?['name'] as String? ?? '',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w400)),
        ]),
        actions: [
          if (isOpen)
            TextButton(
              onPressed: _closeSession,
              style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
              child: const Text('Close Session'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Row(children: [
              // Left: Product grid + cart
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Products', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    Expanded(
                      flex: 2,
                      child: GridView.builder(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 2.5,
                        ),
                        itemCount: _products.length,
                        itemBuilder: (_, i) {
                          final p = _products[i];
                          return InkWell(
                            onTap: isOpen ? () => _addToCart(p) : null,
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: AppTheme.border),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(p['name'] as String? ?? '',
                                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                  Text('${(p['selling_price'] as num?)?.toStringAsFixed(2) ?? '0'} / ${p['uoms']?['abbreviation'] ?? ''}',
                                      style: const TextStyle(color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Cart', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Expanded(
                      flex: 3,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: Column(children: [
                          Expanded(
                            child: _cart.isEmpty
                                ? const Center(child: Text('Tap a product to add to cart',
                                    style: TextStyle(color: AppTheme.textSecondary)))
                                : ListView.separated(
                                    padding: const EdgeInsets.all(8),
                                    itemCount: _cart.length,
                                    separatorBuilder: (_, __) => const Divider(height: 1),
                                    itemBuilder: (_, i) {
                                      final item = _cart[i];
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                                        child: Row(children: [
                                          Expanded(child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(item['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                                              Text('${item['unit_price']} / ${item['uom_abbr']}',
                                                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                            ],
                                          )),
                                          Row(children: [
                                            IconButton(
                                              icon: const Icon(Icons.remove_circle_outline, size: 20),
                                              onPressed: () => setState(() {
                                                if ((item['quantity'] as double) <= 1) {
                                                  _cart.removeAt(i);
                                                } else {
                                                  _cart[i]['quantity'] = (item['quantity'] as double) - 1;
                                                }
                                              }),
                                            ),
                                            Text('${(item['quantity'] as double).toInt()}',
                                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                                            IconButton(
                                              icon: const Icon(Icons.add_circle_outline, size: 20),
                                              onPressed: () => setState(() {
                                                _cart[i]['quantity'] = (item['quantity'] as double) + 1;
                                              }),
                                            ),
                                          ]),
                                          SizedBox(
                                            width: 70,
                                            child: Text(
                                              ((item['quantity'] as double) * (item['unit_price'] as double)).toStringAsFixed(2),
                                              textAlign: TextAlign.end,
                                              style: const TextStyle(fontWeight: FontWeight.w700),
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.close, size: 16, color: AppTheme.danger),
                                            onPressed: () => setState(() => _cart.removeAt(i)),
                                          ),
                                        ]),
                                      );
                                    }),
                          ),
                          if (_cart.isNotEmpty) ...[
                            const Divider(height: 1),
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(children: [
                                Row(children: [
                                  const Text('Payment:'),
                                  const SizedBox(width: 12),
                                  DropdownButton<String>(
                                    value: _paymentMethod,
                                    items: const [
                                      DropdownMenuItem(value: 'cash', child: Text('Cash')),
                                      DropdownMenuItem(value: 'card', child: Text('Card')),
                                      DropdownMenuItem(value: 'bank_transfer', child: Text('Bank Transfer')),
                                      DropdownMenuItem(value: 'credit', child: Text('Credit')),
                                    ],
                                    onChanged: isOpen ? (v) => setState(() => _paymentMethod = v!) : null,
                                  ),
                                ]),
                                const SizedBox(height: 8),
                                Row(children: [
                                  const Spacer(),
                                  Text('Total: ${_cartTotal.toStringAsFixed(2)}',
                                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                                ]),
                                const SizedBox(height: 8),
                                if (isOpen)
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      onPressed: _checkout,
                                      style: ElevatedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(vertical: 14)),
                                      child: const Text('Complete Sale', style: TextStyle(fontSize: 16)),
                                    ),
                                  ),
                              ]),
                            ),
                          ],
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
              // Right: Session info + transactions
              Container(
                width: 320,
                color: Colors.white,
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: isOpen ? AppTheme.success.withOpacity(0.05) : Colors.grey.withOpacity(0.05),
                      border: const Border(bottom: BorderSide(color: AppTheme.border)),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Container(
                          width: 8, height: 8,
                          decoration: BoxDecoration(
                            color: isOpen ? AppTheme.success : AppTheme.textSecondary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(isOpen ? 'Session Open' : 'Session Closed',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: isOpen ? AppTheme.success : AppTheme.textSecondary)),
                      ]),
                      const SizedBox(height: 12),
                      _SessionStat(label: 'Transactions', value: '${_transactions.length}'),
                      const SizedBox(height: 4),
                      _SessionStat(label: 'Session Total', value: sessionTotal.toStringAsFixed(2)),
                      const SizedBox(height: 4),
                      _SessionStat(label: 'Opening Cash', value: (_session['opening_cash'] as num?)?.toStringAsFixed(2) ?? '0'),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Transactions', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                    ),
                  ),
                  Expanded(
                    child: _transactions.isEmpty
                        ? const Center(child: Text('No transactions yet.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)))
                        : ListView.separated(
                            itemCount: _transactions.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final t = _transactions[i];
                              final time = t['transacted_at'] != null
                                  ? DateFormat('HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal())
                                  : '';
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                child: Row(children: [
                                  Expanded(child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(t['customers']?['shop_name'] as String? ?? 'Walk-in',
                                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                      Text('${t['payment_method']} · $time',
                                          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                    ],
                                  )),
                                  Text((t['total'] as num?)?.toStringAsFixed(2) ?? '0',
                                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                                ]),
                              );
                            }),
                  ),
                ]),
              ),
            ]),
    );
  }
}

class _SessionStat extends StatelessWidget {
  final String label;
  final String value;
  const _SessionStat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
    ]);
  }
}
