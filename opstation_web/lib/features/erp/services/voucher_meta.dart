import 'package:supabase_flutter/supabase_flutter.dart';

/// Lightweight helper to fetch shared voucher meta (salesperson, creator,
/// org-wide footer note) used by every voucher PDF and detail screen.
class VoucherMeta {
  final String? salespersonName;
  final String? preparedBy;
  final String? footerNote;

  VoucherMeta({this.salespersonName, this.preparedBy, this.footerNote});

  static Future<VoucherMeta> fetch({
    required String orgId,
    String? customerId,
    String? createdById,
  }) async {
    final client = Supabase.instance.client;

    // Run all three lookups concurrently for snappy detail load.
    final results = await Future.wait<dynamic>([
      _salespersonFor(client, customerId),
      _userNameFor(client, createdById),
      _footerNoteFor(client, orgId),
    ]);

    return VoucherMeta(
      salespersonName: results[0] as String?,
      preparedBy: results[1] as String?,
      footerNote: results[2] as String?,
    );
  }

  // customer → route_stops → route_assignments → users(role='salesperson')
  static Future<String?> _salespersonFor(SupabaseClient c, String? customerId) async {
    if (customerId == null) return null;
    try {
      final stops = await c.from('route_stops').select('route_id').eq('customer_id', customerId).limit(50);
      if ((stops as List).isEmpty) return null;
      final routeIds = stops.map((s) => (s as Map)['route_id'] as String).toSet().toList();
      if (routeIds.isEmpty) return null;
      final assigns = await c.from('route_assignments').select('user_id').inFilter('route_id', routeIds.cast<Object>());
      if ((assigns as List).isEmpty) return null;
      final userIds = assigns.map((a) => (a as Map)['user_id'] as String).toSet().toList();
      if (userIds.isEmpty) return null;
      final users = await c.from('users').select('name').inFilter('id', userIds.cast<Object>()).eq('role', 'salesperson').limit(5);
      if ((users as List).isEmpty) return null;
      return users.map((u) => (u as Map)['name'] as String).join(', ');
    } catch (_) { return null; }
  }

  static Future<String?> _userNameFor(SupabaseClient c, String? userId) async {
    if (userId == null) return null;
    try {
      final u = await c.from('users').select('name').eq('id', userId).maybeSingle();
      return u?['name'] as String?;
    } catch (_) { return null; }
  }

  static Future<String?> _footerNoteFor(SupabaseClient c, String orgId) async {
    try {
      final cfg = await c.from('app_config').select('value').eq('org_id', orgId).eq('key', 'org.voucher_footer_note').maybeSingle();
      final v = cfg?['value'] as String?;
      return (v != null && v.trim().isNotEmpty) ? v.trim() : null;
    } catch (_) { return null; }
  }
}
