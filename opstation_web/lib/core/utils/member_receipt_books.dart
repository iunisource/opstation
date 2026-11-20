import 'package:supabase_flutter/supabase_flutter.dart';

import 'receipt_book_rules.dart';

/// A person's issued receipt books, each with every slip that is accounted for:
/// used on a collection (by anyone), cancelled, or cleared with a reason.
///
/// Returns an empty list when the person has no book, and null when the books
/// cannot be read (no permission, offline): the callers then keep the old
/// number-sequence check, exactly as before.
Future<List<BookSlips>?> loadMemberBooks({required String orgId, required String userId}) async {
  try {
    final db = Supabase.instance.client;
    final raw = await db
        .rpc('receipt_books_status', params: {'p_org': orgId, 'p_user': userId})
        .timeout(const Duration(seconds: 8));
    final rows = List<Map<String, dynamic>>.from(raw as List);
    if (rows.isEmpty) return const [];

    final cleared = <String, Set<int>>{};
    try {
      final cs = await db
          .from('receipt_slip_checks')
          .select('book_id, serial')
          .eq('org_id', orgId)
          .eq('kind', 'unrecorded')
          .inFilter('book_id', [for (final r in rows) '${r['id']}'])
          .timeout(const Duration(seconds: 8));
      for (final c in cs) {
        (cleared['${c['book_id']}'] ??= <int>{}).add((c['serial'] as num).toInt());
      }
    } catch (_) {}

    Set<int> serials(dynamic list) => {
          for (final e in (list as List? ?? const []))
            if (e is Map && e['serial'] is num) (e['serial'] as num).toInt()
        };
    return [
      for (final r in rows)
        BookSlips(
          start: (r['start_no'] as num).toInt(),
          end: (r['end_no'] as num).toInt(),
          prefix: ('${r['prefix'] ?? ''}'.trim().isEmpty) ? null : '${r['prefix']}'.trim().toUpperCase(),
          accounted: {...serials(r['used']), ...serials(r['cancelled']), ...(cleared['${r['id']}'] ?? const <int>{})},
        ),
    ];
  } catch (_) {
    return null;
  }
}

/// What the missing-receipts check needs: is the receipt-books flow ON for the
/// company, and — when it is — this person's books.
class ReceiptCheckData {
  const ReceiptCheckData(this.flowOn, this.books);

  /// null = the setting could not be read (the old check is used, as before).
  final bool? flowOn;

  /// Read only when the flow is ON. null = could not be read.
  final List<BookSlips>? books;

  bool get usesBooks => flowOn == true;

  /// The flow is ON but the books could not be read: nothing is claimed.
  bool get unavailable => flowOn == true && books == null;
}

/// Reads the flow setting (app_config: org.receipt_books_flow) and, when it is ON,
/// the person's books. The flow is either ON or OFF: ON means every salesperson has
/// books (the app refuses entries without one), OFF means no book is checked.
Future<ReceiptCheckData> loadReceiptCheck({required String orgId, required String userId}) async {
  bool? on;
  try {
    final row = await Supabase.instance.client
        .from('app_config')
        .select('value')
        .eq('org_id', orgId)
        .eq('key', 'org.receipt_books_flow')
        .maybeSingle()
        .timeout(const Duration(seconds: 8));
    on = row != null && '${row['value']}' == 'true';
  } catch (_) {
    on = null;
  }
  if (on != true) return ReceiptCheckData(on, null);
  return ReceiptCheckData(true, await loadMemberBooks(orgId: orgId, userId: userId));
}
