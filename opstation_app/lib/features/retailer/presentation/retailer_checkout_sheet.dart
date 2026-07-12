import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import 'retailer_cart.dart';
import 'retailer_home_screen.dart';
import 'retailer_orders_screen.dart';
import 'retailer_shell.dart';

/// Order review + submit.
///
/// NOTE the RetailerLocaleScope wrapper. showModalBottomSheet pushes a NEW
/// ROUTE, which does not inherit the InheritedWidget from the screen that
/// opened it — so without this the sheet silently fell back to English while
/// the rest of the app was in Urdu. Any retailer surface pushed as its own
/// route needs its own scope.
///
/// There is deliberately NO branch picker. Which branch an order belongs to is
/// a system-level assignment (customer_branches), not a decision to put in front
/// of a shopkeeper; retailer_place_order resolves it, falling back to the org's
/// branch when none is assigned.
class RetailerCheckoutSheet extends ConsumerStatefulWidget {
  const RetailerCheckoutSheet({super.key});

  @override
  ConsumerState<RetailerCheckoutSheet> createState() =>
      _RetailerCheckoutSheetState();
}

class _RetailerCheckoutSheetState extends ConsumerState<RetailerCheckoutSheet> {
  bool _saving = false;

  Future<void> _submit(T t) async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) return;
    setState(() => _saving = true);
    try {
      // Only {product_id, qty} crosses the wire. Price, UOM, brand entitlement
      // and branch are all resolved server-side by retailer_place_order.
      final items = [
        for (final l in cart.values) {'product_id': l.productId, 'qty': l.qty},
      ];
      await Supabase.instance.client
          .rpc('retailer_place_order', params: {'p_items': items});
      ref.read(cartProvider.notifier).clear();
      ref.invalidate(retailerOrdersProvider);
      ref.invalidate(retailerAgingProvider);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.orderFailed)));
    }
  }

  double _d(dynamic v) => (v as num?)?.toDouble() ?? 0;

  @override
  Widget build(BuildContext context) {
    return RetailerLocaleScope(
      child: Builder(builder: (context) {
        final t = T.of(context);
        final cart = ref.watch(cartProvider);
        final total = ref.watch(cartTotalProvider);
        final aging = ref.watch(retailerAgingProvider).valueOrNull;

        final outstanding = _d(aging?['total']);
        final limit = _d(aging?['credit_limit']);
        // Projective: warn on what the account will look like once this order is
        // billed, not merely where it stands today.
        final overLimit = limit > 0 && (outstanding + total) > limit;

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          maxChildSize: 0.95,
          builder: (_, scroll) => Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(t.reviewOrder,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: cart.isEmpty
                  ? Center(
                      child: Text(t.cartEmpty,
                          style:
                              TextStyle(color: AppColors.textSecondaryLight)))
                  : ListView(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      children: [
                        for (final l in cart.values)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(l.name,
                                        style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600)),
                                    Text(
                                      '${l.qty.toStringAsFixed(0)} × ${rs(l.price)}',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color:
                                              AppColors.textSecondaryLight),
                                    ),
                                  ],
                                ),
                              ),
                              Text(rs(l.lineTotal),
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700)),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: Icon(Icons.close,
                                    size: 17,
                                    color: AppColors.textSecondaryLight),
                                tooltip: t.remove,
                                onPressed: () => ref
                                    .read(cartProvider.notifier)
                                    .remove(l.productId),
                              ),
                            ]),
                          ),
                        const Divider(height: 22),
                        if (overLimit)
                          Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(13),
                            decoration: BoxDecoration(
                              color: Colors.amber.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: Colors.amber.withValues(alpha: 0.5)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.warning_amber_rounded,
                                    color: Colors.amber.shade900, size: 19),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(t.overLimitBody,
                                      style: const TextStyle(
                                          fontSize: 12.5, height: 1.35)),
                                ),
                              ],
                            ),
                          ),
                        Text(t.priceNote,
                            style: TextStyle(
                                fontSize: 11.5,
                                color: AppColors.textSecondaryLight)),
                      ],
                    ),
            ),
            const Divider(height: 1),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Column(children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(t.total,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      Text(rs(total),
                          style: const TextStyle(
                              fontSize: 19, fontWeight: FontWeight.w800)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed:
                          (cart.isEmpty || _saving) ? null : () => _submit(t),
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13)),
                      ),
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text(t.confirmOrder,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        );
      }),
    );
  }
}
