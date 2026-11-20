import '../search/text_search.dart';

/// The Delivery Orders list filter: search text, the supervision pills (only when the
/// supervise flow is on) and the status pill. One place decides what is in the list,
/// so the number on a status pill is exactly what you get when you tap it.
class DoListFilter {
  const DoListFilter({this.status = 'all', this.search = '', this.supFlow = false, this.sup = 'all'});

  /// all | saved | partially_delivered | invoiced | cancelled
  final String status;
  final String search;

  /// Supervise flow on: the supervision pills apply.
  final bool supFlow;

  /// all | yes | no
  final String sup;

  /// Search and supervision, everything except the status pill.
  bool passesBase(Map<String, dynamic> o) {
    final hay = '${o['voucher_number'] ?? ''} ${o['sales_orders']?['voucher_number'] ?? ''} ${o['customers']?['shop_name'] ?? ''}';
    if (!matchesQuery(hay, search)) return false;
    if (supFlow && sup != 'all') {
      final supervised = o['supervised_at'] != null;
      if (sup == 'yes' && !supervised) return false;
      if (sup == 'no' && (supervised || o['is_voided'] == true)) return false;
    }
    return true;
  }

  bool matches(Map<String, dynamic> o) => passesBase(o) && (status == 'all' || o['status'] == status);

  List<Map<String, dynamic>> apply(List<Map<String, dynamic>> rows) => rows.where(matches).toList();

  /// How many rows the list would show if the status pill [value] were chosen.
  int countFor(List<Map<String, dynamic>> rows, String value) =>
      rows.where((o) => passesBase(o) && (value == 'all' || o['status'] == value)).length;
}
