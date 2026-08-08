import 'package:intl/intl.dart';

/// Central money formatting for Opstation.
///
///   money(100000)      -> "100,000"
///   money(100000.5)    -> "100,000.50"
///   money(1234567.25)  -> "1,234,567.25"
///   money(-2500)       -> "-2,500"
///   money(null)        -> "0"
///
/// Rules: always group thousands with commas; drop the decimals when the
/// amount is whole; keep exactly 2 decimals when a real fraction exists.
final NumberFormat _whole = NumberFormat('#,##0');
final NumberFormat _frac = NumberFormat('#,##0.00');

/// Number only (no currency label) — table cells, chips, totals.
String money(num? v) {
  final n = ((v ?? 0) * 100).round() / 100.0; // round to 2dp -> kill float noise
  return n == n.roundToDouble() ? _whole.format(n) : _frac.format(n);
}

/// With the "Rs. " prefix — standalone amounts.
String moneyRs(num? v) => 'Rs. ${money(v)}';

/// Drop-in replacement for a `NumberFormat('#,##0.00')` money field:
/// change the field type/initializer to `MoneyFmt()` and every existing
/// `.format(x)` call keeps working but now formats via [money].
class MoneyFmt {
  const MoneyFmt();
  String format(num? v) => money(v);
}
