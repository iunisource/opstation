import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/auth_controller.dart';

/// Can this user delete Intelligence items (placement surveys, competitor
/// spottings)? Master admins always; with Admin Settings → "Users can delete
/// Intelligence items" ON, also the users picked there. The database checks
/// the same rule, so this only decides whether to show the delete button.
Future<bool> canDeleteIntel(WebUser? user) async {
  if (user == null) return false;
  final role = user.role;
  if (role == WebUserRole.masterAdmin || role == WebUserRole.superAdmin) return true;
  final orgId = user.orgId;
  if (orgId == null) return false;
  try {
    final rows = await Supabase.instance.client.from('app_config').select('key, value').eq('org_id', orgId)
        .inFilter('key', ['org.intel_delete_access', 'org.intel_delete_users']);
    var on = false;
    var ids = <String>{};
    for (final r in rows) {
      if (r['key'] == 'org.intel_delete_access') on = '${r['value']}' == 'true';
      if (r['key'] == 'org.intel_delete_users') {
        ids = '${r['value'] ?? ''}'.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
      }
    }
    return on && ids.contains(user.id);
  } catch (_) {
    return false;
  }
}

/// Plain message for a failed delete.
String intelDeleteError(Object e) {
  final m = e.toString();
  if (m.contains('PGRST202') || m.contains('Could not find the function')) {
    return 'This option isn\'t set up yet — run update 417 first.';
  }
  if (m.contains('not allowed')) return 'You are not allowed to delete Intelligence items.';
  return 'Could not delete. Please try again.';
}
