import 'package:supabase_flutter/supabase_flutter.dart';

/// The organisation's clock format (Admin Settings → "24-hour time",
/// org.time_24h). OFF (default) = 12-hour "2:30 PM"; ON = 24-hour "14:30".
class OrgTimeFormat {
  static bool use24 = false;
  static String? _loadedFor;

  /// Reads the org's setting once per org. Never throws.
  static Future<void> load(String? orgId, {bool force = false}) async {
    if (orgId == null || (!force && _loadedFor == orgId)) return;
    try {
      final r = await Supabase.instance.client.from('app_config').select('value')
          .eq('org_id', orgId).eq('key', 'org.time_24h').limit(1);
      use24 = (r as List).isNotEmpty && '${r.first['value']}'.trim() == 'true';
      _loadedFor = orgId;
    } catch (_) {}
  }
}

/// A DateFormat pattern with its time part in the org's format:
/// "d MMM yyyy, HH:mm" ⇄ "d MMM yyyy, h:mm a". Dates are left as they are.
String orgTime(String pattern) {
  if (OrgTimeFormat.use24) {
    return pattern
        .replaceAll(RegExp(r'h{1,2}:mm:ss a'), 'HH:mm:ss')
        .replaceAll(RegExp(r'h{1,2}:mm a'), 'HH:mm');
  }
  return pattern.replaceAll('HH:mm:ss', 'h:mm:ss a').replaceAll('HH:mm', 'h:mm a');
}
