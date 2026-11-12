import 'package:supabase_flutter/supabase_flutter.dart';

/// Voids are a back-office operation: a voided journal entry and the
/// reversal that cancels it are left out of ledgers (they net to zero on the
/// same date, so balances are unchanged). True for either half of the pair:
///   • JV void (SQL 325): original is_voided / reversed_by, reversal reverses_id
///   • document void (SQL 295): original reversed_by, reversal reference_type 'void'
bool isVoidPair(Map h) =>
    h['is_voided'] == true ||
    (h['reversed_by'] != null && '${h['reversed_by']}'.isNotEmpty) ||
    (h['reverses_id'] != null && '${h['reverses_id']}'.isNotEmpty) ||
    h['reference_type'] == 'void';

/// Of the given journal entry ids (or entry numbers when [byNumber]), the ones
/// that are part of a void pair. Never throws — returns an empty set on error.
Future<Set<String>> voidPairKeys(String orgId, Iterable<String> keys, {bool byNumber = false}) async {
  final list = keys.where((k) => k.isNotEmpty).toSet().toList();
  if (list.isEmpty) return {};
  final out = <String>{};
  try {
    final col = byNumber ? 'entry_number' : 'id';
    for (var i = 0; i < list.length; i += 150) {
      final chunk = list.sublist(i, i + 150 > list.length ? list.length : i + 150);
      final rows = await Supabase.instance.client
          .from('journal_entries')
          .select()
          .eq('org_id', orgId)
          .inFilter(col, chunk);
      for (final r in rows as List) {
        if (isVoidPair(r as Map)) out.add('${r[col]}');
      }
    }
  } catch (_) {}
  return out;
}
