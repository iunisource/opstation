import 'package:supabase_flutter/supabase_flutter.dart';

/// One discount a customer gets on a product (Inventory → Discount Policies).
class CustDiscount {
  final String type; // 'percent' | 'amount' (Rs off per unit)
  final double value;
  final String source; // 'sku' (customer + SKU) | 'group' (discount group)
  const CustDiscount(this.type, this.value, this.source);

  /// The discount as a % of [price] — every sales screen stores line discounts
  /// as a percentage, so a Rs-per-unit policy is converted at the line's price.
  double percentFor(double price) {
    if (type == 'percent') return value.clamp(0, 100).toDouble();
    if (price <= 0) return 0;
    final p = value / price * 100;
    return double.parse(p.clamp(0, 100).toStringAsFixed(4));
  }

  String get label {
    final v = value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();
    final how = type == 'percent' ? '$v%' : 'Rs $v / unit';
    return '$how (${source == 'sku' ? 'customer price' : 'discount group'})';
  }
}

/// Approved, in-date discounts for [customerId], keyed by product id.
/// Customer + SKU policies already win over group ones (resolved on the server).
/// Returns an empty map when there are none or anything fails, so sales screens
/// simply carry on without discounts.
Future<Map<String, CustDiscount>> loadCustomerDiscounts(String? customerId, {DateTime? on}) async {
  if (customerId == null || customerId.isEmpty) return {};
  try {
    final d = on ?? DateTime.now();
    final res = await Supabase.instance.client.rpc('customer_discounts', params: {
      'p_customer': customerId,
      'p_on': '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
    });
    final out = <String, CustDiscount>{};
    if (res is Map) {
      res.forEach((k, v) {
        if (v is Map) {
          final val = (v['value'] as num?)?.toDouble() ?? 0;
          if (val > 0) {
            out['$k'] = CustDiscount('${v['type'] ?? 'percent'}', val, '${v['source'] ?? 'group'}');
          }
        }
      });
    }
    return out;
  } catch (_) {
    return {};
  }
}
