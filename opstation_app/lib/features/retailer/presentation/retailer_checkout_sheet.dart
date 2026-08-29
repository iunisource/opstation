import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import 'retailer_browse_screen.dart';
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
  bool _loadingSchemes = false;
  List<Map<String, dynamic>> _cartOffers = [];

  @override
  void initState() {
    super.initState();
    _loadCartOffers();
  }

  /// The offers this exact cart qualifies for — shown inline on the review so
  /// the shopkeeper sees the FOC/discount they're getting, not just a button.
  Future<void> _loadCartOffers() async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) return;
    try {
      final items = [
        for (final l in cart.values)
          {'product_id': l.productId, 'qty': l.qty, 'unit_price': l.price},
      ];
      final res = await Supabase.instance.client
          .rpc('retailer_suggest_schemes', params: {'p_items': items});
      if (res is List && mounted) {
        setState(() =>
            _cartOffers = [for (final s in res) Map<String, dynamic>.from(s as Map)]);
      }
    } catch (_) {
      // No offers / engine off — leave the banner hidden.
    }
  }

  String _cartOfferBenefit(T t, Map<String, dynamic> s) {
    double d(dynamic v) => (v as num?)?.toDouble() ?? 0;
    switch (s['type'] as String?) {
      case 'foc':
        final ft = (s['free_text'] as String?)?.trim() ?? '';
        final fq = d(s['free_total']);
        return ft.isNotEmpty
            ? '${t.free}: ${fq.toStringAsFixed(0)} • $ft'
            : '${t.free}: ${fq.toStringAsFixed(0)}';
      case 'combo':
        final ft = (s['free_text'] as String?)?.trim() ?? '';
        return ft.isNotEmpty ? '${t.free}: $ft' : t.free;
      case 'qty_slab':
        return '${t.discount}: ${rs(d(s['discount_total']))}';
      case 'invoice_discount':
        final p = d(s['invoice_percent']);
        return '${t.discount}: ${p.toStringAsFixed(p % 1 == 0 ? 0 : 1)}%';
      case 'promo_price':
        return t.specialPrice;
      default:
        return '';
    }
  }

  Widget _offersBanner(T t) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.success.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.success.withValues(alpha: 0.4)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.card_giftcard, size: 16, color: AppColors.successDark),
            const SizedBox(width: 6),
            Text(t.offersOnOrder,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.successDark)),
          ]),
          for (final s in _cartOffers)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((s['name'] as String?) ?? '',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                  Text(_cartOfferBenefit(t, s),
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.successDark)),
                ],
              ),
            ),
        ]),
      );

  /// All active offers for the org (same list the web shows), each measured
  /// against the current cart so the shopkeeper sees how close they are — e.g.
  /// "add 4 more of X to unlock" — instead of only seeing an offer once it has
  /// already been met. Tapping one jumps to that product in the catalogue.
  Future<void> _showSchemes(T t) async {
    if (_loadingSchemes) return;
    setState(() => _loadingSchemes = true);
    List<Map<String, dynamic>> offers = [];
    try {
      final res =
          await Supabase.instance.client.rpc('retailer_active_offers');
      if (res is List) {
        offers = [for (final s in res) Map<String, dynamic>.from(s as Map)];
      }
    } catch (_) {
      // Engine off / not deployed — treat as "no offers".
    }
    if (!mounted) return;
    setState(() => _loadingSchemes = false);
    final cart = ref.read(cartProvider);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => RetailerLocaleScope(
        child: Builder(
          builder: (_) => _SchemesSheet(
            offers: offers,
            cart: cart,
            onJump: _jumpToOffer,
          ),
        ),
      ),
    );
  }

  /// Close the offers sheet + the checkout sheet and land on the offer's
  /// product in the (already-open) browse screen so the shopkeeper can top up
  /// to the qualifying quantity.
  void _jumpToOffer(String? productName) {
    final nav = Navigator.of(context);
    if (productName != null && productName.trim().isNotEmpty) {
      ref.read(browseSearchProvider.notifier).state = productName.trim();
    }
    nav.pop(); // offers sheet
    nav.pop(false); // checkout sheet -> reveals browse
  }

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
                        if (_cartOffers.isNotEmpty) _offersBanner(t),
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
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      onPressed: (cart.isEmpty || _loadingSchemes)
                          ? null
                          : () => _showSchemes(t),
                      icon: _loadingSchemes
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.local_offer_outlined, size: 17),
                      label: Text(t.availableOffers),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: AppColors.primary,
                        side: BorderSide(color: AppColors.primary.withValues(alpha: 0.4)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
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

/// Active offers measured against the current cart: each shows its benefit and
/// how close the cart is (qualified, or "add N more of X"). Tapping jumps to
/// the product so the shopkeeper can top up.
class _SchemesSheet extends StatelessWidget {
  final List<Map<String, dynamic>> offers;
  final Map<String, CartLine> cart;
  final void Function(String? productName) onJump;
  const _SchemesSheet(
      {required this.offers, required this.cart, required this.onJump});

  IconData _icon(String? type) {
    switch (type) {
      case 'foc':
      case 'combo':
        return Icons.card_giftcard_outlined;
      case 'promo_price':
        return Icons.sell_outlined;
      default:
        return Icons.percent_outlined;
    }
  }

  // (statusText, qualified). qualified drives the green vs amber pill.
  (String, bool) _status(T t, Map<String, dynamic> s) {
    final tqty = (s['trigger_qty'] as num?)?.toDouble();
    final tpid = s['trigger_product_id'] as String?;
    final pname = (s['trigger_product_name'] as String?)?.trim() ?? '';
    if (tqty == null || tqty <= 0) return ('', false);
    if (tpid != null) {
      final have = cart[tpid]?.qty ?? 0;
      if (have >= tqty) return (t.qualified, true);
      return (t.addMore(tqty - have, pname), false);
    }
    final any = cart.values.any((l) => l.qty >= tqty);
    if (any) return (t.qualified, true);
    return (t.addAny(tqty), false);
  }

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.92,
      builder: (_, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(t.availableOffers,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: offers.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.local_offer_outlined,
                          size: 40, color: AppColors.textSecondaryLight),
                      const SizedBox(height: 12),
                      Text(t.noOffers,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textSecondaryLight)),
                    ]),
                  ),
                )
              : ListView(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  children: [
                    for (final s in offers)
                      Builder(builder: (_) {
                        final st = _status(t, s);
                        final statusText = st.$1;
                        final ok = st.$2;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Material(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () =>
                                  onJump(s['trigger_product_name'] as String?),
                              child: Container(
                                padding: const EdgeInsets.all(13),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border:
                                      Border.all(color: AppColors.borderLight),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 38,
                                      height: 38,
                                      decoration: BoxDecoration(
                                        color: AppColors.primary
                                            .withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Icon(_icon(s['type'] as String?),
                                          color: AppColors.primary, size: 20),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text((s['name'] as String?) ?? '',
                                              style: const TextStyle(
                                                  fontSize: 14.5,
                                                  fontWeight: FontWeight.w800)),
                                          if (((s['benefit'] as String?) ?? '')
                                              .trim()
                                              .isNotEmpty) ...[
                                            const SizedBox(height: 3),
                                            Text((s['benefit'] as String).trim(),
                                                style: TextStyle(
                                                    fontSize: 12.5,
                                                    fontWeight: FontWeight.w700,
                                                    color: AppColors.primary)),
                                          ],
                                          if (statusText.isNotEmpty) ...[
                                            const SizedBox(height: 6),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 9,
                                                      vertical: 4),
                                              decoration: BoxDecoration(
                                                color: (ok
                                                        ? AppColors.success
                                                        : AppColors.warning)
                                                    .withValues(alpha: 0.14),
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                      ok
                                                          ? Icons
                                                              .check_circle_outline
                                                          : Icons
                                                              .add_shopping_cart,
                                                      size: 13,
                                                      color: ok
                                                          ? AppColors.successDark
                                                          : AppColors
                                                              .warningDark),
                                                  const SizedBox(width: 5),
                                                  Flexible(
                                                    child: Text(statusText,
                                                        style: TextStyle(
                                                            fontSize: 12,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                            color: ok
                                                                ? AppColors
                                                                    .successDark
                                                                : AppColors
                                                                    .warningDark)),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Icon(Icons.chevron_right,
                                        size: 20,
                                        color: AppColors.textSecondaryLight),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    const SizedBox(height: 10),
                    Text(t.offersNote,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 11.5, color: AppColors.textSecondaryLight)),
                    const SizedBox(height: 8),
                  ],
                ),
        ),
      ]),
    );
  }
}
