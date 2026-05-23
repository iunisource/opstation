import 'dart:developer' as developer;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Lightweight helper to fetch shared voucher meta (salesperson, creator,
/// org-wide footer note) used by every voucher PDF and detail screen.
class VoucherMeta {
  final String? salespersonName;
  final String? preparedBy;
  final String? footerNote;

  VoucherMeta({this.salespersonName, this.preparedBy, this.footerNote});

  static void _log(String msg) => developer.log(msg, name: 'VoucherMeta');

  static Future<VoucherMeta> fetch({
    required String orgId,
    String? customerId,
    String? createdById,
  }) async {
    final client = Supabase.instance.client;
    _log('fetch: orgId=$orgId customerId=$customerId createdById=$createdById');
    final results = await Future.wait<dynamic>([
      _salespersonFor(client, customerId),
      _userNameFor(client, createdById),
      _footerNoteFor(client, orgId),
    ]);
    final m = VoucherMeta(
      salespersonName: results[0] as String?,
      preparedBy: results[1] as String?,
      footerNote: results[2] as String?,
    );
    _log('result: sp=${m.salespersonName} prep=${m.preparedBy} hasFooter=${m.footerNote != null}');
    return m;
  }

  /// Resolve a customer's salesperson via:
  ///   customer → route_stops → route_assignments → users
  /// Prefers users with role='salesperson' (case-insensitive); falls back to
  /// any assigned user if no matching role is found. Each step is logged.
  static Future<String?> _salespersonFor(SupabaseClient c, String? customerId) async {
    if (customerId == null) { _log('sp: no customerId, skipping'); return null; }
    try {
      // 1) route_stops for this customer
      final stopsRaw = await c.from('route_stops')
          .select('route_id').eq('customer_id', customerId).limit(50);
      final stops = (stopsRaw as List).cast<Map>();
      _log('sp: route_stops found=${stops.length}');
      if (stops.isEmpty) return null;
      final routeIds = stops.map((s) => s['route_id'] as String).toSet().toList();
      _log('sp: routes=$routeIds');

      // 2) route_assignments for these routes
      final assignsRaw = await c.from('route_assignments')
          .select('user_id, route_id').inFilter('route_id', routeIds.cast<Object>());
      final assigns = (assignsRaw as List).cast<Map>();
      _log('sp: assignments found=${assigns.length}');
      if (assigns.isEmpty) return null;
      final userIds = assigns.map((a) => a['user_id'] as String).toSet().toList();
      _log('sp: userIds=$userIds');

      // 3) users — fetch WITHOUT role filter so we can see what's there
      final usersRaw = await c.from('users')
          .select('id, name, role').inFilter('id', userIds.cast<Object>());
      final users = (usersRaw as List).cast<Map>();
      final summary = users.map((u) => '${u['name']}=${u['role']}').join(', ');
      _log('sp: users found=${users.length} -> $summary');
      if (users.isEmpty) return null;

      // Prefer salesperson, case-insensitive; else any assigned user.
      final salespeople = users.where((u) =>
          ((u['role'] as String?) ?? '').toLowerCase() == 'salesperson').toList();
      final chosen = salespeople.isNotEmpty ? salespeople : users;
      final names = chosen
          .map((u) => (u['name'] as String?) ?? '')
          .where((n) => n.trim().isNotEmpty)
          .toSet()
          .toList();
      _log('sp: chosen names=$names');
      if (names.isEmpty) return null;
      return names.join(', ');
    } catch (e, st) {
      _log('sp: error $e\n$st');
      return null;
    }
  }

  static Future<String?> _userNameFor(SupabaseClient c, String? userId) async {
    if (userId == null) return null;
    try {
      final u = await c.from('users').select('name').eq('id', userId).maybeSingle();
      return u?['name'] as String?;
    } catch (e) {
      _log('preparedBy: error $e');
      return null;
    }
  }

  static Future<String?> _footerNoteFor(SupabaseClient c, String orgId) async {
    if (orgId.isEmpty) return null;
    try {
      final cfg = await c.from('app_config')
          .select('value').eq('org_id', orgId).eq('key', 'org.voucher_footer_note').maybeSingle();
      final v = cfg?['value'] as String?;
      return (v != null && v.trim().isNotEmpty) ? v.trim() : null;
    } catch (e) {
      _log('footerNote: error $e');
      return null;
    }
  }
}
