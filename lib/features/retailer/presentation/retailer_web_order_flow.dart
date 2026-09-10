import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/format/money.dart';

/// Opens the retailer web ordering flow (browse -> cart -> place order), the
/// same server RPCs the mobile app uses (retailer_my_products /
/// retailer_place_order / scheme offers). Returns true if an order was placed.
Future<bool?> showRetailerOrderFlow(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Dialog.fullscreen(child: _RetailerOrderFlow()),
  );
}

class _RetailerOrderFlow extends ConsumerStatefulWidget {
  const _RetailerOrderFlow();
  @override
  ConsumerState<_RetailerOrderFlow> createState() => _RetailerOrderFlowState();
}

class _RetailerOrderFlowState extends ConsumerState<_RetailerOrderFlow> {
  bool _loading = true;
  bool _placing = false;
  bool _loadingOffers = false;
  String _q = '';
  List<Map<String, dynamic>> _products = [];
  final Map<String, Map<String, dynamic>> _cart = {}; // productId -> {product, qty}

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client.rpc('retailer_my_products');
      final list = (res as List?) ?? [];
      if (!mounted) return;
      setState(() {
        _products = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  double _price(Map p) => (p['selling_price'] as num?)?.toDouble() ?? 0;
  double get _total => _cart.values
      .fold(0.0, (s, l) => s + _price(l['product'] as Map) * (l['qty'] as double));
  int get _count => _cart.length;

  void _setQty(Map<String, dynamic> p, double qty) {
    final id = p['id'] as String;
    setState(() {
      if (qty <= 0) {
        _cart.remove(id);
      } else {
        _cart[id] = {'product': p, 'qty': qty};
      }
    });
  }

  Future<void> _placeOrder() async {
    if (_cart.isEmpty || _placing) return;
    setState(() => _placing = true);
    try {
      final items = [
        for (final l in _cart.values)
          {'product_id': (l['product'] as Map)['id'], 'qty': l['qty']},
      ];
      await Supabase.instance.client
          .rpc('retailer_place_order', params: {'p_items': items});
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _placing = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not place the order. Please try again.')));
      }
    }
  }

  Future<void> _showOffers() async {
    if (_loadingOffers) return;
    setState(() => _loadingOffers = true);
    List<Map<String, dynamic>> offers = [];
    try {
      // Cart-aware when there are lines; otherwise all active offers.
      if (_cart.isNotEmpty) {
        final items = [
          for (final l in _cart.values)
            {
              'product_id': (l['product'] as Map)['id'],
              'qty': l['qty'],
              'unit_price': _price(l['product'] as Map),
            },
        ];
        final res = await Supabase.instance.client
            .rpc('retailer_suggest_schemes', params: {'p_items': items});
        if (res is List) {
          offers = [for (final s in res) Map<String, dynamic>.from(s as Map)];
        }
      } else {
        final res =
            await Supabase.instance.client.rpc('retailer_active_offers');
        if (res is List) {
          offers = [for (final s in res) Map<String, dynamic>.from(s as Map)];
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _loadingOffers = false);
    await showDialog(
      context: context,
      builder: (_) => _OffersDialog(offers: offers, cartAware: _cart.isNotEmpty),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ql = _q.trim().toLowerCase();
    final visible = ql.isEmpty
        ? _products
        : _products.where((p) {
            final n = '${p['name'] ?? ''}'.toLowerCase();
            final s = '${p['sku'] ?? ''}'.toLowerCase();
            return n.contains(ql) || s.contains(ql);
          }).toList();

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Place Order'),
        leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(false)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _q = v),
                  decoration: InputDecoration(
                    hintText: 'Search products…',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              Expanded(
                child: _products.isEmpty
                    ? const Center(
                        child: Text('No products available to you yet.',
                            style: TextStyle(color: AppTheme.textSecondary)))
                    : Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 900),
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            itemCount: visible.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final p = visible[i];
                              final id = p['id'] as String;
                              final qty =
                                  (_cart[id]?['qty'] as double?) ?? 0;
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                child: Row(children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('${p['name'] ?? ''}',
                                            style: const TextStyle(
                                                fontSize: 14.5,
                                                fontWeight: FontWeight.w600)),
                                        if ('${p['sku'] ?? ''}'.isNotEmpty)
                                          Text('${p['sku']}',
                                              style: const TextStyle(
                                                  fontSize: 11.5,
                                                  color:
                                                      AppTheme.textSecondary)),
                                        Text('Rs ${money(_price(p))}',
                                            style: const TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                                color: AppTheme.primary)),
                                      ],
                                    ),
                                  ),
                                  _Stepper(
                                    qty: qty,
                                    onAdd: () => _setQty(p, qty + 1),
                                    onSub: () => _setQty(p, qty - 1),
                                    onType: () => _askQty(p, qty),
                                  ),
                                ]),
                              );
                            },
                          ),
                        ),
                      ),
              ),
              _bottomBar(),
            ]),
    );
  }

  Future<void> _askQty(Map<String, dynamic> p, double current) async {
    final ctrl = TextEditingController(
        text: current > 0 ? current.toStringAsFixed(0) : '');
    final v = await showDialog<double>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${p['name'] ?? ''}', style: const TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Quantity'),
          onSubmitted: (s) => Navigator.pop(c, double.tryParse(s.trim()) ?? 0),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () =>
                  Navigator.pop(c, double.tryParse(ctrl.text.trim()) ?? 0),
              child: const Text('Set')),
        ],
      ),
    );
    if (v != null) _setQty(p, v);
  }

  Widget _bottomBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppTheme.border)),
      ),
      padding: EdgeInsets.fromLTRB(
          16, 10, 16, 10 + MediaQuery.of(context).padding.bottom),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Row(children: [
            OutlinedButton.icon(
              onPressed: _loadingOffers ? null : _showOffers,
              icon: _loadingOffers
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.local_offer_outlined, size: 18),
              label: const Text('Available offers'),
            ),
            const Spacer(),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('$_count item${_count == 1 ? '' : 's'}',
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
              Text('Rs ${money(_total)}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(width: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
              ),
              onPressed: (_cart.isEmpty || _placing) ? null : _placeOrder,
              child: _placing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Confirm Order',
                      style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  final double qty;
  final VoidCallback onAdd, onSub, onType;
  const _Stepper(
      {required this.qty,
      required this.onAdd,
      required this.onSub,
      required this.onType});

  @override
  Widget build(BuildContext context) {
    if (qty <= 0) {
      return OutlinedButton(
          onPressed: onAdd, child: const Icon(Icons.add, size: 18));
    }
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
            icon: const Icon(Icons.remove, size: 18), onPressed: onSub),
        InkWell(
          onTap: onType,
          child: Container(
            constraints: const BoxConstraints(minWidth: 34),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Text(qty.toStringAsFixed(0),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary)),
          ),
        ),
        IconButton(icon: const Icon(Icons.add, size: 18), onPressed: onAdd),
      ]),
    );
  }
}

class _OffersDialog extends StatelessWidget {
  final List<Map<String, dynamic>> offers;
  final bool cartAware;
  const _OffersDialog({required this.offers, required this.cartAware});

  String _benefit(Map<String, dynamic> s) {
    double d(dynamic v) => (v as num?)?.toDouble() ?? 0;
    switch (s['type'] as String?) {
      case 'foc':
        final ft = (s['free_text'] as String?)?.trim() ?? '';
        final fq = d(s['free_total']);
        // active-offers shape carries a ready 'benefit' string; suggest shape has free_total
        final b = (s['benefit'] as String?)?.trim();
        if (b != null && b.isNotEmpty) return b;
        return ft.isNotEmpty
            ? 'Get ${fq.toStringAsFixed(0)} free • $ft'
            : 'Get ${fq.toStringAsFixed(0)} free';
      case 'qty_slab':
        return (s['benefit'] as String?)?.trim().isNotEmpty == true
            ? s['benefit'] as String
            : 'Discount Rs ${money(d(s['discount_total']))}';
      case 'combo':
        final ft = (s['free_text'] as String?)?.trim() ?? '';
        return ft.isNotEmpty ? 'Combo: $ft' : 'Combo offer';
      case 'invoice_discount':
        final p = d(s['invoice_percent']);
        return '${p.toStringAsFixed(p % 1 == 0 ? 0 : 1)}% off invoice';
      case 'promo_price':
        return 'Special promo price';
      default:
        return (s['benefit'] as String?) ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Available offers'),
      content: SizedBox(
        width: 420,
        child: offers.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('No offers available for your current cart.',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final s in offers)
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${s['name'] ?? ''}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800)),
                          if ('${s['description'] ?? ''}'.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text('${s['description']}',
                                  style: const TextStyle(
                                      fontSize: 12.5,
                                      color: AppTheme.textSecondary)),
                            ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppTheme.success.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(_benefit(s),
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.success)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
