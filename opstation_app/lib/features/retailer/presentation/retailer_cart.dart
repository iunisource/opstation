import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A line the retailer has put in the cart.
///
/// Price is carried for DISPLAY only. It is never sent to the server — that
/// would let a crafted client dictate what it pays. `retailer_place_order`
/// re-resolves price, UOM and brand entitlement from the database, so the only
/// thing the client is trusted with is {product_id, qty}.
class CartLine {
  final String productId;
  final String name;
  final String? sku;
  final String? subGroup;
  final double price;
  final double qty;

  const CartLine({
    required this.productId,
    required this.name,
    required this.price,
    required this.qty,
    this.sku,
    this.subGroup,
  });

  double get lineTotal => price * qty;

  CartLine copyWith({double? qty}) => CartLine(
        productId: productId,
        name: name,
        sku: sku,
        subGroup: subGroup,
        price: price,
        qty: qty ?? this.qty,
      );
}

class CartNotifier extends Notifier<Map<String, CartLine>> {
  @override
  Map<String, CartLine> build() => {};

  void setQty(CartLine line, double qty) {
    final next = Map<String, CartLine>.from(state);
    if (qty <= 0) {
      next.remove(line.productId);
    } else {
      next[line.productId] = line.copyWith(qty: qty);
    }
    state = next;
  }

  void add(CartLine line) {
    final cur = state[line.productId]?.qty ?? 0;
    setQty(line, cur + 1);
  }

  void decrement(CartLine line) {
    final cur = state[line.productId]?.qty ?? 0;
    setQty(line, cur - 1);
  }

  void remove(String productId) {
    final next = Map<String, CartLine>.from(state)..remove(productId);
    state = next;
  }

  void clear() => state = {};
}

final cartProvider =
    NotifierProvider<CartNotifier, Map<String, CartLine>>(CartNotifier.new);

/// Derived, never stored — same principle as sales_orders, which has no total
/// column and computes order value from its lines everywhere in the system.
final cartTotalProvider = Provider<double>((ref) {
  final cart = ref.watch(cartProvider);
  return cart.values.fold<double>(0, (s, l) => s + l.lineTotal);
});

final cartCountProvider = Provider<int>((ref) {
  return ref.watch(cartProvider).length;
});
