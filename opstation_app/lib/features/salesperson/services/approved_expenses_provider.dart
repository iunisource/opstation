import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// My approved and paid reimbursements from the web portal (SQL 479,
/// reimb_my_approved). Newest decision first. Needs a connection.
final approvedExpensesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final r = await Supabase.instance.client.rpc('reimb_my_approved');
  return [for (final e in (r as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
});
