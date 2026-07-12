import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import '../retailer_auth_controller.dart';
import 'retailer_cart.dart';
import 'retailer_checkout_sheet.dart';
import 'retailer_shell.dart';

/// Products this retailer may order.
///
/// The join to `retailer_brands` is the same entitlement rule the server
/// enforces in `retailer_place_order`. Doing it here too is not duplication for
/// its own sake — it means the retailer never SEES a product they cannot order,
/// rather than seeing it and being refused at checkout. The server check remains
/// the actual boundary; this one is courtesy.
final retailerProductsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final me = ref.watch(retailerAuthControllerProvider).valueOrNull;
  if (me == null) return [];
  final client = Supabase.instance.client;

  final brands = await client
      .from('retailer_brands')
      .select('sub_group')
      .eq('customer_id', me.customerId);
  final subs = [
    for (final b in brands as List)
      if ((b['sub_group'] as String?)?.isNotEmpty == true) b['sub_group'] as String
  ];
  if (subs.isEmpty) return [];

  final rows = await client
      .from('products')
      .select('id, name, sku, product_sub_group, selling_price')
      .eq('org_id', me.orgId)
      .eq('is_active', true)
      .inFilter('product_sub_group', subs)
      .order('name');
  return [for (final r in rows as List) Map<String, dynamic>.from(r as Map)];
});

class RetailerBrowseScreen extends ConsumerStatefulWidget {
  const RetailerBrowseScreen({super.key});

  @override
  ConsumerState<RetailerBrowseScreen> createState() =>
      _RetailerBrowseScreenState();
}

class _RetailerBrowseScreenState extends ConsumerState<RetailerBrowseScreen> {
  final _searchCtrl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(retailerProductsProvider);
    final cart = ref.watch(cartProvider);
    final count = ref.watch(cartCountProvider);
    final total = ref.watch(cartTotalProvider);

    return RetailerLocaleScope(
      child: Builder(builder: (context) {
        final t = T.of(context);
        return Scaffold(
          appBar: AppBar(title: Text(t.placeOrder)),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  hintText: t.searchProducts,
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => Center(
                    child: Text(t.somethingWentWrong,
                        style:
                            TextStyle(color: AppColors.textSecondaryLight))),
                data: (rows) {
                  if (rows.isEmpty) {
                    return _empty(t.noProducts, Icons.inventory_2_outlined);
                  }
                  final ql = _q.trim().toLowerCase();
                  final visible = ql.isEmpty
                      ? rows
                      : rows.where((p) {
                          final n = '${p['name'] ?? ''}'.toLowerCase();
                          final s = '${p['sku'] ?? ''}'.toLowerCase();
                          return n.contains(ql) || s.contains(ql);
                        }).toList();
                  if (visible.isEmpty) {
                    return _empty(t.noMatches, Icons.search_off);
                  }
                  return ListView.separated(
                    padding: EdgeInsets.only(bottom: count > 0 ? 96 : 12),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 14),
                    itemBuilder: (_, i) {
                      final p = visible[i];
                      final pid = p['id'] as String;
                      final price =
                          (p['selling_price'] as num?)?.toDouble() ?? 0;
                      final line = CartLine(
                        productId: pid,
                        name: '${p['name'] ?? ''}',
                        sku: p['sku'] as String?,
                        subGroup: p['product_sub_group'] as String?,
                        price: price,
                        qty: 1,
                      );
                      final qty = cart[pid]?.qty ?? 0;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        child: Row(children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${p['name'] ?? ''}',
                                    style: const TextStyle(
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 2),
                                Text(
                                  [
                                    if ('${p['sku'] ?? ''}'.isNotEmpty)
                                      '${p['sku']}',
                                    if ('${p['product_sub_group'] ?? ''}'
                                        .isNotEmpty)
                                      '${p['product_sub_group']}',
                                  ].join('  •  '),
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: AppColors.textSecondaryLight),
                                ),
                                const SizedBox(height: 3),
                                Text(rs(price),
                                    style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.primary)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          _Stepper(
                            qty: qty,
                            onAdd: () =>
                                ref.read(cartProvider.notifier).add(line),
                            onSub: () => ref
                                .read(cartProvider.notifier)
                                .decrement(line),
                          ),
                        ]),
                      );
                    },
                  );
                },
              ),
            ),
          ]),
          bottomNavigationBar: count == 0
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                    child: SizedBox(
                      height: 56,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () => showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          showDragHandle: true,
                          builder: (_) => const RetailerCheckoutSheet(),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '$count ${count == 1 ? t.item : t.items}',
                              style: const TextStyle(
                                  fontSize: 14.5, fontWeight: FontWeight.w700),
                            ),
                            Row(children: [
                              Text(rs(total),
                                  style: const TextStyle(
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(width: 8),
                              const Icon(Icons.arrow_forward, size: 18),
                            ]),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        );
      }),
    );
  }

  Widget _empty(String msg, IconData icon) => ListView(children: [
        const SizedBox(height: 110),
        Center(
          child: Column(children: [
            Icon(icon, size: 40, color: AppColors.textSecondaryLight),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(msg,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondaryLight)),
            ),
          ]),
        ),
      ]);
}

class _Stepper extends StatelessWidget {
  final double qty;
  final VoidCallback onAdd;
  final VoidCallback onSub;
  const _Stepper({required this.qty, required this.onAdd, required this.onSub});

  @override
  Widget build(BuildContext context) {
    if (qty <= 0) {
      return OutlinedButton(
        onPressed: onAdd,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 38),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: const Icon(Icons.add, size: 20),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove, size: 18),
          onPressed: onSub,
        ),
        SizedBox(
          width: 26,
          child: Text(
            qty.toStringAsFixed(0),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add, size: 18),
          onPressed: onAdd,
        ),
      ]),
    );
  }
}
