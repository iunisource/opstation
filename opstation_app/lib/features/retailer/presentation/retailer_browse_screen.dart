import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import 'retailer_cart.dart';
import 'retailer_checkout_sheet.dart';
import 'retailer_shell.dart';

/// Products this retailer may order.
///
/// MUST go through `retailer_my_products()` (SECURITY DEFINER), not a direct
/// query on products/retailer_brands: RLS on those tables is written for staff,
/// so a retailer's PostgREST read returns ZERO ROWS silently — which is exactly
/// how a retailer with three brands tagged saw "no products available".
final retailerProductsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await Supabase.instance.client.rpc('retailer_my_products');
  if (res is! List) return [];
  return [for (final r in res) Map<String, dynamic>.from(r as Map)];
});

/// Brand logos + the org's "show images" switch, in one call.
///
/// Images are OFF by default. With thousands of products and few photos, turning
/// them on prematurely gives a wall of grey placeholders — worse than the honest
/// text list. So the admin flips this only once the catalogue is worth showing,
/// and every widget below falls back to text when an image is missing.
final retailerCatalogMetaProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  try {
    final res = await Supabase.instance.client.rpc('retailer_catalog_meta');
    if (res is Map) return Map<String, dynamic>.from(res);
  } catch (_) {}
  return {'show_images': false, 'brands': {}};
});

/// Brand-first browse. A retailer tagged to several brands thinks in brands
/// ("what Paklite LED do I need?"), not in one flat 340-item list — so pick the
/// brand, then the products within it. With a single brand we skip the picker
/// entirely rather than make them tap through a list of one.
class RetailerBrowseScreen extends ConsumerStatefulWidget {
  const RetailerBrowseScreen({super.key});

  @override
  ConsumerState<RetailerBrowseScreen> createState() =>
      _RetailerBrowseScreenState();
}

class _RetailerBrowseScreenState extends ConsumerState<RetailerBrowseScreen> {
  final _searchCtrl = TextEditingController();
  String _q = '';
  String? _brand; // null = brand list; '' = all brands

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Tap the number to type an exact quantity — a shopkeeper ordering 60 units
  /// should not have to press + sixty times.
  Future<void> _askQty(CartLine line, double current, T t) async {
    final ctrl =
        TextEditingController(text: current > 0 ? current.toStringAsFixed(0) : '');
    final v = await showDialog<double>(
      context: context,
      builder: (c) => RetailerLocaleScope(
        child: Builder(builder: (c2) {
          final tt = T.of(c2);
          return AlertDialog(
            title: Text(line.name, style: const TextStyle(fontSize: 15)),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                labelText: tt.quantity,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onSubmitted: (s) =>
                  Navigator.pop(c, double.tryParse(s.trim()) ?? 0),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: Text(tt.cancel)),
              ElevatedButton(
                onPressed: () => Navigator.pop(
                    c, double.tryParse(ctrl.text.trim()) ?? 0),
                child: Text(tt.done),
              ),
            ],
          );
        }),
      ),
    );
    if (v != null) ref.read(cartProvider.notifier).setQty(line, v);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(retailerProductsProvider);
    final meta = ref.watch(retailerCatalogMetaProvider).valueOrNull;
    final showImages = meta?['show_images'] == true;
    final brandLogos = Map<String, dynamic>.from(
        (meta?['brands'] as Map?) ?? const {});
    final cart = ref.watch(cartProvider);
    final count = ref.watch(cartCountProvider);
    final total = ref.watch(cartTotalProvider);

    return RetailerLocaleScope(
      child: Builder(builder: (context) {
        final t = T.of(context);
        return Scaffold(
          appBar: AppBar(
            title: Text(_brand == null || _brand!.isEmpty
                ? t.placeOrder
                : _brand!),
            leading: _brand != null
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => setState(() {
                      _brand = null;
                      _q = '';
                      _searchCtrl.clear();
                    }),
                  )
                : null,
          ),
          body: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) => Center(
                child: Text(t.somethingWentWrong,
                    style: TextStyle(color: AppColors.textSecondaryLight))),
            data: (rows) {
              if (rows.isEmpty) {
                return _empty(t.noProducts, Icons.inventory_2_outlined);
              }
              final brands = <String>{
                for (final p in rows)
                  if ('${p['product_sub_group'] ?? ''}'.isNotEmpty)
                    p['product_sub_group'] as String
              }.toList()
                ..sort();

              // One brand: no point making them choose from a list of one.
              if (_brand == null && brands.length == 1) {
                _brand = brands.first;
              }
              if (_brand == null) {
                return _brandList(brands, rows, t, brandLogos);
              }
              return _productList(rows, cart, t, showImages);
            },
          ),
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
                        onPressed: () async {
                          final ok = await showModalBottomSheet<bool>(
                            context: context,
                            isScrollControlled: true,
                            showDragHandle: true,
                            builder: (_) => const RetailerCheckoutSheet(),
                          );
                          if (ok == true && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(t.orderPlaced)));
                            Navigator.of(context).pop();
                          }
                        },
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('$count ${count == 1 ? t.item : t.items}',
                                style: const TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w700)),
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

  Widget _brandList(List<String> brands, List<Map<String, dynamic>> rows, T t,
      Map<String, dynamic> logos) {
    final counts = <String, int>{};
    for (final p in rows) {
      final b = '${p['product_sub_group'] ?? ''}';
      if (b.isNotEmpty) counts[b] = (counts[b] ?? 0) + 1;
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
      children: [
        Text(t.chooseBrand,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondaryLight)),
        const SizedBox(height: 12),
        for (final b in brands)
          Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
            ),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              leading: _BrandLogo(url: logos[b] as String?),
              title: Text(b,
                  style: const TextStyle(
                      fontSize: 15.5, fontWeight: FontWeight.w700)),
              subtitle: Text('${counts[b] ?? 0} ${t.products}',
                  style: TextStyle(
                      fontSize: 12, color: AppColors.textSecondaryLight)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => _brand = b),
            ),
          ),
        const SizedBox(height: 4),
        TextButton.icon(
          icon: const Icon(Icons.apps, size: 18),
          label: Text(t.allBrands),
          onPressed: () => setState(() => _brand = ''),
        ),
      ],
    );
  }

  Widget _productList(List<Map<String, dynamic>> rows,
      Map<String, CartLine> cart, T t, bool showImages) {
    final inBrand = (_brand == null || _brand!.isEmpty)
        ? rows
        : rows.where((p) => p['product_sub_group'] == _brand).toList();
    final ql = _q.trim().toLowerCase();
    final visible = ql.isEmpty
        ? inBrand
        : inBrand.where((p) {
            final n = '${p['name'] ?? ''}'.toLowerCase();
            final s = '${p['sku'] ?? ''}'.toLowerCase();
            return n.contains(ql) || s.contains(ql);
          }).toList();

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        child: TextField(
          controller: _searchCtrl,
          onChanged: (v) => setState(() => _q = v),
          decoration: InputDecoration(
            hintText: t.searchProducts,
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      Expanded(
        child: visible.isEmpty
            ? _empty(t.noMatches, Icons.search_off)
            : ListView.separated(
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: visible.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, indent: 14),
                itemBuilder: (_, i) {
                  final p = visible[i];
                  final pid = p['id'] as String;
                  final price = (p['selling_price'] as num?)?.toDouble() ?? 0;
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
                      if (showImages) ...[
                        _ProductThumb(url: p['image_url'] as String?),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${p['name'] ?? ''}',
                                style: const TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            if ('${p['sku'] ?? ''}'.isNotEmpty)
                              Text('${p['sku']}',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: AppColors.textSecondaryLight)),
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
                        onAdd: () => ref.read(cartProvider.notifier).add(line),
                        onSub: () =>
                            ref.read(cartProvider.notifier).decrement(line),
                        onTapQty: () => _askQty(line, qty, t),
                      ),
                    ]),
                  );
                },
              ),
      ),
    ]);
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
  final VoidCallback onTapQty;
  const _Stepper({
    required this.qty,
    required this.onAdd,
    required this.onSub,
    required this.onTapQty,
  });

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
        // Tappable: type an exact quantity instead of pressing + repeatedly.
        InkWell(
          onTap: onTapQty,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            constraints: const BoxConstraints(minWidth: 34),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Text(
              qty.toStringAsFixed(0),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: AppColors.primary,
                decoration: TextDecoration.underline,
                decorationColor: AppColors.primary.withValues(alpha: 0.4),
              ),
            ),
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

/// Brand mark on the brand picker. Falls back to a tinted icon — a brand with no
/// logo should still look like a considered row, not a broken one.
class _BrandLogo extends StatelessWidget {
  final String? url;
  const _BrandLogo({this.url});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      width: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: url == null
            ? AppColors.primary.withValues(alpha: 0.10)
            : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: url == null
            ? null
            : Border.all(color: Colors.black.withValues(alpha: 0.08)),
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null
          ? Icon(Icons.sell_outlined, color: AppColors.primary, size: 21)
          : Image.network(url!,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  Icon(Icons.sell_outlined, color: AppColors.primary, size: 21)),
    );
  }
}

/// Product thumbnail, shown only when the admin has switched images on.
class _ProductThumb extends StatelessWidget {
  final String? url;
  const _ProductThumb({this.url});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      width: 52,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null
          ? Icon(Icons.inventory_2_outlined,
              size: 20, color: AppColors.textSecondaryLight)
          : Image.network(url!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Icon(Icons.inventory_2_outlined,
                  size: 20, color: AppColors.textSecondaryLight)),
    );
  }
}
