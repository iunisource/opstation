import 'package:supabase_flutter/supabase_flutter.dart';

/// Lightweight helper to fetch shared voucher meta (salesperson, creator,
/// org-wide footer note) used by every voucher PDF and detail screen.
///
/// In addition to the resolved values, [diagnostic] explains *why* the
/// salesperson lookup returned null so the UI can show it to admins.
class VoucherMeta {
  final String? salespersonName;
  final String? preparedBy;
  final String? footerNote;
  final String? purchaseFooterNote;
  // Per-voucher-type sales footer overrides. Each falls back to [footerNote]
  // (the generic org.voucher_footer_note) when blank, so orgs that never set a
  // per-type note keep exactly their current footer.
  final String? soFooterNote;
  final String? doFooterNote;
  final String? siFooterNote;
  final String? diagnostic;

  VoucherMeta({this.salespersonName, this.preparedBy, this.footerNote, this.purchaseFooterNote, this.soFooterNote, this.doFooterNote, this.siFooterNote, this.diagnostic});

  static String? _pick(String? specific, String? fallback) {
    final s = specific?.trim();
    if (s != null && s.isNotEmpty) return s;
    final f = fallback?.trim();
    return (f != null && f.isNotEmpty) ? f : null;
  }

  /// Footer to print on a Sales Order (its own note, else the default).
  String? get soFooter => _pick(soFooterNote, footerNote);

  /// Footer to print on a Delivery Order (its own note, else the default).
  String? get doFooter => _pick(doFooterNote, footerNote);

  /// Footer to print on a Sales Invoice (its own note, else the default).
  String? get siFooter => _pick(siFooterNote, footerNote);

  // Plain print() rather than developer.log so messages show in browser console
  // even in release builds.
  static void _log(String msg) {
    // ignore: avoid_print
    print('[VoucherMeta] $msg');
  }

  static Future<VoucherMeta> fetch({
    required String orgId,
    String? customerId,
    String? createdById,
  }) async {
    final client = Supabase.instance.client;
    _log('fetch orgId=$orgId customerId=$customerId createdById=$createdById');
    final spResult = await _salespersonFor(client, customerId);
    final results = await Future.wait<dynamic>([
      _userNameFor(client, createdById),
      _footerNoteFor(client, orgId),
      _purchaseFooterNoteFor(client, orgId),
      _configValue(client, orgId, 'org.footer_note_so'),
      _configValue(client, orgId, 'org.footer_note_do'),
      _configValue(client, orgId, 'org.footer_note_si'),
    ]);
    final m = VoucherMeta(
      salespersonName: spResult.name,
      diagnostic: spResult.diagnostic,
      preparedBy: results[0] as String?,
      footerNote: results[1] as String?,
      purchaseFooterNote: results[2] as String?,
      soFooterNote: results[3] as String?,
      doFooterNote: results[4] as String?,
      siFooterNote: results[5] as String?,
    );
    _log('result sp=${m.salespersonName} diag=${m.diagnostic} prep=${m.preparedBy} hasFooter=${m.footerNote != null}');
    return m;
  }

  static Future<_SpResult> _salespersonFor(SupabaseClient c, String? customerId) async {
    if (customerId == null || customerId.isEmpty) {
      return _SpResult(null, 'No customer id on voucher');
    }
    try {
      // 1) customer → routes
      final stopsRaw = await c.from('route_stops')
          .select('route_id').eq('customer_id', customerId).limit(50);
      final stops = (stopsRaw as List).cast<Map>();
      _log('sp route_stops for $customerId -> ${stops.length}');
      if (stops.isEmpty) {
        return _SpResult(null, 'Customer not on any route');
      }
      final routeIds = stops.map((s) => s['route_id'] as String).toSet().toList();

      // 2) routes → users
      final assignsRaw = await c.from('route_assignments')
          .select('user_id, route_id').inFilter('route_id', routeIds.cast<Object>());
      final assigns = (assignsRaw as List).cast<Map>();
      _log('sp assignments -> ${assigns.length} (routes ${routeIds.length})');
      if (assigns.isEmpty) {
        return _SpResult(null, 'Route has no assigned salesperson');
      }
      final userIds = assigns.map((a) => a['user_id'] as String).toSet().toList();

      // 3) user names — no role filter so RLS / role-string mismatches don't
      //                 silently hide the result.
      final usersRaw = await c.from('users')
          .select('id, name, role').inFilter('id', userIds.cast<Object>());
      final users = (usersRaw as List).cast<Map>();
      _log('sp users -> ${users.length}: ${users.map((u) => '${u['name']}=${u['role']}').join(", ")}');
      if (users.isEmpty) {
        return _SpResult(null, 'User row not readable (check RLS)');
      }

      // Prefer salesperson, case-insensitive.
      final salespeople = users.where((u) =>
          ((u['role'] as String?) ?? '').toLowerCase() == 'salesperson').toList();
      final chosen = salespeople.isNotEmpty ? salespeople : users;
      final names = chosen
          .map((u) => (u['name'] as String?) ?? '')
          .where((n) => n.trim().isNotEmpty)
          .toSet()
          .toList();
      if (names.isEmpty) {
        return _SpResult(null, 'Assigned user has no name');
      }
      return _SpResult(names.join(', '), null);
    } catch (e) {
      _log('sp error $e');
      return _SpResult(null, 'Lookup failed: $e');
    }
  }

  static Future<String?> _userNameFor(SupabaseClient c, String? userId) async {
    if (userId == null) return null;
    try {
      final u = await c.from('users').select('name').eq('id', userId).maybeSingle();
      return u?['name'] as String?;
    } catch (e) {
      _log('preparedBy error $e');
      return null;
    }
  }

  /// Generic single-key reader for org-scoped app_config string values.
  /// Returns the trimmed value, or null when missing/blank.
  static Future<String?> _configValue(SupabaseClient c, String orgId, String key) async {
    if (orgId.isEmpty) return null;
    try {
      final row = await c.from('app_config').select('value')
          .eq('org_id', orgId).eq('key', key).maybeSingle();
      final v = row?['value'] as String?;
      return (v != null && v.trim().isNotEmpty) ? v.trim() : null;
    } catch (_) { return null; }
  }

  static Future<String?> _purchaseFooterNoteFor(SupabaseClient c, String orgId) async {
    try {
      final row = await c.from('app_config').select('value')
          .eq('org_id', orgId).eq('key', 'org.purchase_footer_note').maybeSingle();
      return row?['value'] as String?;
    } catch (_) { return null; }
  }

  static Future<String?> _footerNoteFor(SupabaseClient c, String orgId) async {
    if (orgId.isEmpty) return null;
    try {
      final cfg = await c.from('app_config').select('value')
          .eq('org_id', orgId).eq('key', 'org.voucher_footer_note').maybeSingle();
      final v = cfg?['value'] as String?;
      return (v != null && v.trim().isNotEmpty) ? v.trim() : null;
    } catch (e) {
      _log('footerNote error $e');
      return null;
    }
  }
}

class _SpResult {
  final String? name;
  final String? diagnostic;
  _SpResult(this.name, this.diagnostic);
}
