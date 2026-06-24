import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Field Orders review queue. Salespeople submit orders from the mobile app;
/// an admin reviews here, may edit qty / remove / add lines, then Approves
/// (-> a draft Sales Order via approve_field_order) or Rejects.
class ErpFieldOrdersScreen extends ConsumerStatefulWidget {
  const ErpFieldOrdersScreen({super.key});
  @override
  ConsumerState<ErpFieldOrdersScreen> createState() => _ErpFieldOrdersScreenState();
}

class _ErpFieldOrdersScreenState extends ConsumerState<ErpFieldOrdersScreen> {
  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _userId => ref.read(currentUserProvider)?.id;

  String _filter = 'submitted';
  bool _loading = true, _saving = false;
  List<Map<String, dynamic>> _orders = [];
  final Map<String, String> _custNames = {};
  final Map<String, String> _spNames = {};
  // product catalog: id -> {name, selling_price, base_uom_id}
  final Map<String, Map<String, dynamic>> _products = {};

  Map<String, dynamic>? _selected;          // the order open for review
  List<Map<String, dynamic>> _lines = [];    // editable line list

  @override
  void initState() {
    super.initState();
    _loadProducts();
    _loadOrders();
  }

  Future<void> _loadProducts() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final p = await Supabase.instance.client.from('products')
          .select('id, name, sku, base_uom_id, selling_price')
          .eq('org_id', orgId).eq('is_active', true).order('name').limit(10000);
      for (final r in p as List) {
        _products[r['id'] as String] = {
          'name': r['name'], 'sku': r['sku'],
          'selling_price': (r['selling_price'] as num?)?.toDouble() ?? 0,
          'base_uom_id': r['base_uom_id'],
        };
      }
    } catch (_) {}
  }

  Future<void> _loadOrders() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final orders = List<Map<String, dynamic>>.from(await client.from('field_orders')
          .select('*').eq('org_id', orgId).eq('status', _filter)
          .order('submitted_at', ascending: false));
      final custIds = orders.map((o) => o['customer_id'] as String?).whereType<String>().toSet().toList();
      final spIds = orders.map((o) => o['salesperson_id'] as String?).whereType<String>().toSet().toList();
      if (custIds.isNotEmpty) {
        final cs = await client.from('customers').select('id, shop_name').inFilter('id', custIds);
        for (final c in cs as List) { _custNames[c['id'] as String] = (c['shop_name'] as String?) ?? '—'; }
      }
      if (spIds.isNotEmpty) {
        final us = await client.from('users').select('id, name').inFilter('id', spIds);
        for (final u in us as List) { _spNames[u['id'] as String] = (u['name'] as String?) ?? '—'; }
      }
      setState(() { _orders = orders; _loading = false; });
    } catch (e) { _snack('Load error: $e'); setState(() => _loading = false); }
  }

  Future<void> _openOrder(Map<String, dynamic> o) async {
    setState(() { _selected = o; _lines = []; });
    try {
      final items = await Supabase.instance.client.from('field_order_items')
          .select('*').eq('field_order_id', o['id'] as String);
      setState(() {
        _lines = (items as List).map((r) {
          final pid = r['product_id'] as String;
          final p = _products[pid] ?? const {};
          return <String, dynamic>{
            'id': r['id'], 'product_id': pid, 'uom_id': r['uom_id'] ?? p['base_uom_id'],
            'quantity': (r['quantity'] as num?)?.toDouble() ?? 0,
            'price_at_submit': (r['price_at_submit'] as num?)?.toDouble(),
            'name': p['name'] ?? pid, 'price': (p['selling_price'] as double?) ?? 0,
          };
        }).toList();
      });
    } catch (e) { _snack('Could not load lines: $e'); }
  }

  double get _total => _lines.fold(0.0, (s, l) => s + ((l['quantity'] as double) * (l['price'] as double)));

  void _addLine() {
    final searchCtrl = TextEditingController();
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
      final q = searchCtrl.text.trim().toLowerCase();
      final matches = _products.entries.where((e) {
        if (q.isEmpty) return true;
        final n = (e.value['name'] as String? ?? '').toLowerCase();
        final s = (e.value['sku'] as String? ?? '').toLowerCase();
        return n.contains(q) || s.contains(q);
      }).take(40).toList();
      return AlertDialog(
        title: const Text('Add Product'),
        content: SizedBox(width: 460, height: 460, child: Column(children: [
          TextField(controller: searchCtrl, autofocus: true, onChanged: (_) => setLocal(() {}),
            decoration: const InputDecoration(hintText: 'Search name or SKU…', prefixIcon: Icon(Icons.search), isDense: true)),
          const SizedBox(height: 8),
          Expanded(child: ListView.builder(itemCount: matches.length, itemBuilder: (_, i) {
            final e = matches[i];
            final price = (e.value['selling_price'] as double?) ?? 0;
            final already = _lines.any((l) => l['product_id'] == e.key);
            return ListTile(dense: true,
              title: Text(e.value['name'] as String? ?? e.key, style: const TextStyle(fontSize: 13)),
              subtitle: Text('${e.value['sku'] ?? ''}  ·  Rs. ${price.toStringAsFixed(2)}', style: const TextStyle(fontSize: 11)),
              trailing: already ? const Icon(Icons.check, size: 16, color: AppTheme.success) : const Icon(Icons.add, size: 18),
              onTap: already ? null : () {
                setState(() => _lines.add({
                  'id': 'foi_${DateTime.now().microsecondsSinceEpoch}',
                  'product_id': e.key, 'uom_id': e.value['base_uom_id'],
                  'quantity': 1.0, 'price_at_submit': price,
                  'name': e.value['name'] ?? e.key, 'price': price,
                }));
                Navigator.pop(ctx);
              });
          })),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      );
    }));
  }

  Future<void> _approve() async {
    final o = _selected; if (o == null) return;
    if (_lines.isEmpty) { _snack('Add at least one line before approving'); return; }
    if (_lines.any((l) => (l['quantity'] as double) <= 0)) { _snack('Every line needs a quantity above zero'); return; }
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Approve order?'),
      content: Text('This creates a draft Sales Order for ${_custNames[o['customer_id']] ?? 'this customer'} with ${_lines.length} line(s), priced at current rates. You can finalise and lock it in Sales Orders.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Approve')),
      ]));
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final foId = o['id'] as String;
      // persist the (possibly edited) lines: replace all items for this order
      await client.from('field_order_items').delete().eq('field_order_id', foId);
      await client.from('field_order_items').insert(_lines.map((l) => {
        'id': l['id'], 'field_order_id': foId, 'product_id': l['product_id'],
        'uom_id': l['uom_id'], 'quantity': l['quantity'], 'price_at_submit': l['price_at_submit'],
      }).toList());
      final soId = await client.rpc('approve_field_order', params: {'p_id': foId, 'p_user': _userId});
      final soNum = await client.from('sales_orders').select('voucher_number').eq('id', soId as String).maybeSingle();
      if (!mounted) return;
      setState(() { _saving = false; _selected = null; });
      _snack('Approved — draft ${soNum?['voucher_number'] ?? 'Sales Order'} created');
      _loadOrders();
    } catch (e) { _snack('Approve failed: $e'); setState(() => _saving = false); }
  }

  Future<void> _reject() async {
    final o = _selected; if (o == null) return;
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Reject order?'),
      content: TextField(controller: reasonCtrl, autofocus: true, maxLines: 3,
        decoration: const InputDecoration(hintText: 'Reason (optional)')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
          onPressed: () => Navigator.pop(ctx, true), child: const Text('Reject')),
      ]));
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('reject_field_order',
          params: {'p_id': o['id'], 'p_user': _userId, 'p_reason': reasonCtrl.text.trim()});
      if (!mounted) return;
      setState(() { _saving = false; _selected = null; });
      _snack('Order rejected');
      _loadOrders();
    } catch (e) { _snack('Reject failed: $e'); setState(() => _saving = false); }
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Field Orders', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      const Text('Orders submitted by salespeople from the field. Review, adjust, then approve into a draft Sales Order.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      const SizedBox(height: 14),
      Row(children: [
        for (final f in const ['submitted', 'approved', 'rejected'])
          Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
            label: Text(f[0].toUpperCase() + f.substring(1)),
            selected: _filter == f,
            onSelected: (_) { setState(() { _filter = f; _selected = null; }); _loadOrders(); })),
        const Spacer(),
        IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _loadOrders),
      ]),
      const SizedBox(height: 12),
      Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 380, child: _queueList()),
        const SizedBox(width: 16),
        Expanded(child: _reviewPanel()),
      ])),
    ]));
  }

  Widget _queueList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_orders.isEmpty) return Center(child: Text('No $_filter orders', style: const TextStyle(color: AppTheme.textSecondary)));
    return ListView.separated(
      itemCount: _orders.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final o = _orders[i];
        final sel = _selected?['id'] == o['id'];
        final when = o['submitted_at'] != null ? DateFormat('d MMM, HH:mm').format(DateTime.parse(o['submitted_at'] as String).toLocal()) : '';
        return InkWell(onTap: () => _openOrder(o), borderRadius: BorderRadius.circular(10), child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: sel ? AppTheme.primary.withOpacity(0.06) : Colors.white,
            borderRadius: BorderRadius.circular(10), border: Border.all(color: sel ? AppTheme.primary.withOpacity(0.4) : AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_custNames[o['customer_id']] ?? 'Customer', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('By ${_spNames[o['salesperson_id']] ?? '—'}  ·  $when', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            if ((o['notes'] as String?)?.isNotEmpty == true) ...[
              const SizedBox(height: 4),
              Text(o['notes'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic, color: AppTheme.textSecondary)),
            ],
          ]),
        ));
      },
    );
  }

  Widget _reviewPanel() {
    final o = _selected;
    if (o == null) {
      return Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
        child: const Center(child: Text('Select an order to review', style: TextStyle(color: AppTheme.textSecondary))));
    }
    final readOnly = _filter != 'submitted';
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_custNames[o['customer_id']] ?? 'Customer', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('Submitted by ${_spNames[o['salesperson_id']] ?? '—'}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ])),
          if (!readOnly) OutlinedButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('Add Product'), onPressed: _addLine),
        ])),
        const Divider(height: 1),
        Expanded(child: _lines.isEmpty
          ? const Center(child: Text('No lines', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _lines.length,
              separatorBuilder: (_, __) => const Divider(height: 14),
              itemBuilder: (_, i) {
                final l = _lines[i];
                final qty = l['quantity'] as double;
                final price = l['price'] as double;
                return Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l['name'] as String, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    Text('Rs. ${price.toStringAsFixed(2)} each', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ])),
                  if (readOnly)
                    Text('× ${qty.toStringAsFixed(0)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))
                  else ...[
                    IconButton(icon: const Icon(Icons.remove_circle_outline, size: 20), onPressed: qty <= 1 ? null : () => setState(() => l['quantity'] = qty - 1)),
                    SizedBox(width: 46, child: Text(qty.toStringAsFixed(0), textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
                    IconButton(icon: const Icon(Icons.add_circle_outline, size: 20), onPressed: () => setState(() => l['quantity'] = qty + 1)),
                  ],
                  SizedBox(width: 92, child: Text('Rs. ${(qty * price).toStringAsFixed(2)}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                  if (!readOnly) IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger), onPressed: () => setState(() => _lines.removeAt(i))),
                ]);
              },
            )),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          Text('Total (at current prices)', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const Spacer(),
          Text('Rs. ${_total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.primary)),
        ])),
        if (!readOnly) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Row(children: [
          Expanded(child: OutlinedButton.icon(style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger, side: const BorderSide(color: AppTheme.danger)),
            icon: const Icon(Icons.close, size: 18), label: const Text('Reject'), onPressed: _saving ? null : _reject)),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: ElevatedButton.icon(
            icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check, size: 18),
            label: Text(_saving ? 'Working…' : 'Approve → Draft SO'),
            onPressed: _saving ? null : _approve)),
        ])),
        if (readOnly && o['reject_reason'] != null) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Text('Rejected: ${o['reject_reason']}', style: const TextStyle(fontSize: 12, color: AppTheme.danger))),
      ]),
    );
  }
}
