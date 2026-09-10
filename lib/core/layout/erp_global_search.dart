import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

/// Opens the global search overlay. [can] is the same route-permission check
/// the navigation menu uses, so a category only appears (and is only queried)
/// when the user is allowed to see it.
Future<void> showGlobalSearch(
  BuildContext context, {
  required String orgId,
  required bool Function(String route) can,
}) {
  return showDialog(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _GlobalSearchDialog(orgId: orgId, can: can),
  );
}

class _Hit {
  final String title;
  final String? subtitle;
  final String route; // where tapping navigates
  final IconData icon;
  const _Hit(this.title, this.subtitle, this.route, this.icon);
}

class _Cat {
  final String label;
  final IconData icon;
  final List<String> permRoutes; // visible if ANY is permitted
  final Future<List<_Hit>> Function(String q, String nav) run;
  const _Cat(this.label, this.icon, this.permRoutes, this.run);
}

class _GlobalSearchDialog extends StatefulWidget {
  final String orgId;
  final bool Function(String route) can;
  const _GlobalSearchDialog({required this.orgId, required this.can});

  @override
  State<_GlobalSearchDialog> createState() => _GlobalSearchDialogState();
}

class _GlobalSearchDialogState extends State<_GlobalSearchDialog> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  String _q = '';
  // results keyed by category label, in category order
  final List<MapEntry<_Cat, List<_Hit>>> _results = [];

  SupabaseClient get _c => Supabase.instance.client;

  late final List<_Cat> _cats = [
    // Tapping a product opens its LEDGER (movement history), preselected — the
    // most useful "what happened to this item" view. Falls back to the Products
    // screen if the user can't reach the ledger.
    _Cat('Products', Icons.inventory_2_outlined, const ['/erp/inventory-ledger', '/erp/products'], (q, nav) async {
      final r = await _c.from('products').select('id,name,sku').eq('org_id', widget.orgId)
          .or('name.ilike.%$q%,sku.ilike.%$q%').limit(6);
      return (r as List).map((e) => _Hit(
        (e['name'] ?? '').toString(),
        (e['sku'] ?? '').toString().isEmpty ? null : 'SKU ${e['sku']}',
        '$nav?focus=${e['id']}', Icons.inventory_2_outlined)).toList();
    }),
    _Cat('Customers', Icons.store_outlined, const ['/erp/customer-ledger', '/customers', '/erp/sales-invoices'], (q, nav) async {
      final r = await _c.from('customers').select('id,shop_name,code').eq('org_id', widget.orgId)
          .or('shop_name.ilike.%$q%,code.ilike.%$q%').limit(6);
      return (r as List).map((e) => _Hit(
        (e['shop_name'] ?? '').toString(),
        (e['code'] ?? '').toString().isEmpty ? null : (e['code']).toString(),
        '$nav?focus=${e['id']}', Icons.store_outlined)).toList();
    }),
    _Cat('Suppliers', Icons.local_shipping_outlined, const ['/erp/supplier-ledger', '/erp/suppliers'], (q, nav) async {
      final r = await _c.from('suppliers').select('id,name').eq('org_id', widget.orgId)
          .ilike('name', '%$q%').limit(6);
      return (r as List).map((e) => _Hit((e['name'] ?? '').toString(), null, '$nav?focus=${e['id']}', Icons.local_shipping_outlined)).toList();
    }),
    _Cat('Sales Invoices', Icons.receipt_outlined, const ['/erp/sales-invoices'], (q, nav) async {
      final r = await _c.from('sales_invoices').select('id,voucher_number,voucher_date,grand_total')
          .eq('org_id', widget.orgId).ilike('voucher_number', '%$q%')
          .order('voucher_date', ascending: false).limit(6);
      return (r as List).map((e) => _Hit(
        (e['voucher_number'] ?? '').toString(),
        [if (e['voucher_date'] != null) e['voucher_date'].toString(),
         if (e['grand_total'] != null) 'Rs ${e['grand_total']}'].join('  •  '),
        '$nav?focus=${e['id']}', Icons.receipt_outlined)).toList();
    }),
    _Cat('Purchase Invoices', Icons.receipt_long_outlined, const ['/erp/purchase-invoices'], (q, nav) async {
      final r = await _c.from('purchase_invoices').select('id,voucher_number,voucher_date')
          .eq('org_id', widget.orgId).ilike('voucher_number', '%$q%')
          .order('voucher_date', ascending: false).limit(6);
      return (r as List).map((e) => _Hit(
        (e['voucher_number'] ?? '').toString(),
        e['voucher_date']?.toString(), '$nav?focus=${e['id']}', Icons.receipt_long_outlined)).toList();
    }),
    _voucherCat('Sales Orders', Icons.request_quote_outlined, '/erp/sales', 'sales_orders'),
    _voucherCat('Delivery Orders', Icons.local_shipping_outlined, '/erp/delivery-orders', 'delivery_orders'),
    _voucherCat('Purchase Orders', Icons.shopping_cart_outlined, '/erp/purchase', 'purchase_orders'),
    _voucherCat('GRNs', Icons.move_to_inbox_outlined, '/erp/grn', 'purchase_grns'),
    _voucherCat('Purchase Returns', Icons.assignment_return_outlined, '/erp/purchase-return-vouchers', 'purchase_return_invoices'),
    _voucherCat('Stock Transfers', Icons.swap_horiz_outlined, '/erp/stock-transfers', 'stock_transfers', dateCol: 'transfer_date'),
    _voucherCat('Production', Icons.precision_manufacturing_outlined, '/manufacturing/production-voucher', 'production_vouchers'),
  ];

  /// Voucher categories all share the same shape: match voucher_number, newest
  /// first, deep-link with ?focus=<id>.
  _Cat _voucherCat(String label, IconData icon, String route, String table,
      {String dateCol = 'voucher_date'}) {
    return _Cat(label, icon, [route], (q, nav) async {
      final r = await _c.from(table).select('id,voucher_number,$dateCol')
          .eq('org_id', widget.orgId).ilike('voucher_number', '%$q%')
          .order(dateCol, ascending: false).limit(6);
      return (r as List).map((e) => _Hit(
        (e['voucher_number'] ?? '').toString(),
        e[dateCol]?.toString(), '$nav?focus=${e['id']}', icon)).toList();
    });
  }

  String _navFor(_Cat cat) => cat.permRoutes.firstWhere(widget.can, orElse: () => cat.permRoutes.first);

  void _onChanged(String raw) {
    _debounce?.cancel();
    final q = raw.replaceAll(RegExp(r'[%,()]'), ' ').trim();
    _debounce = Timer(const Duration(milliseconds: 280), () => _search(q));
  }

  Future<void> _search(String q) async {
    setState(() { _q = q; });
    if (q.length < 2) { setState(() { _results.clear(); _loading = false; }); return; }
    setState(() => _loading = true);

    final active = _cats.where((c) => c.permRoutes.any(widget.can)).toList();
    final lists = await Future.wait(active.map((c) async {
      try { return await c.run(q, _navFor(c)); } catch (_) { return <_Hit>[]; }
    }));

    if (!mounted || _q != q) return;
    final out = <MapEntry<_Cat, List<_Hit>>>[];
    for (var i = 0; i < active.length; i++) {
      if (lists[i].isNotEmpty) out.add(MapEntry(active[i], lists[i]));
    }
    setState(() { _results..clear()..addAll(out); _loading = false; });
  }

  void _go(String route) { Navigator.of(context).pop(); context.go(route); }

  @override
  void dispose() { _debounce?.cancel(); _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final total = _results.fold<int>(0, (s, e) => s + e.value.length);
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 80, left: 16, right: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
            child: Row(children: [
              const Icon(Icons.search, size: 20, color: AppTheme.textSecondary),
              const SizedBox(width: 10),
              Expanded(child: TextField(
                controller: _ctrl, autofocus: true, onChanged: _onChanged,
                decoration: const InputDecoration(
                  border: InputBorder.none, isDense: true,
                  hintText: 'Search products, customers, suppliers, vouchers, entries…'),
                style: const TextStyle(fontSize: 15),
              )),
              if (_loading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.of(context).pop()),
            ]),
          ),
          const Divider(height: 1),
          Flexible(child: _body(total)),
        ]),
      ),
    );
  }

  Widget _body(int total) {
    if (_q.length < 2) {
      return const Padding(padding: EdgeInsets.all(28),
        child: Text('Type at least 2 characters to search. Only the areas you have access to are searched.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)));
    }
    if (!_loading && total == 0) {
      return Padding(padding: const EdgeInsets.all(28),
        child: Text('No matches for “$_q”.', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)));
    }
    return ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
      for (final entry in _results) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(children: [
            Icon(entry.key.icon, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(entry.key.label.toUpperCase(),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: AppTheme.textSecondary)),
          ]),
        ),
        for (final h in entry.value)
          InkWell(
            onTap: () => _go(h.route),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(children: [
                Icon(h.icon, size: 18, color: AppTheme.primary),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(h.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
                  if (h.subtitle != null && h.subtitle!.isNotEmpty)
                    Text(h.subtitle!, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                ])),
                const Icon(Icons.north_east, size: 14, color: AppTheme.textSecondary),
              ]),
            ),
          ),
      ],
    ]);
  }
}
