import 'package:supabase_flutter/supabase_flutter.dart';

/// Tells the database which organization THIS tab is working in. Every query
/// and RPC from this tab carries an `x-org-id` header, which the server's
/// current_user_org_id() honours (290_org_per_tab.sql) when the login is a
/// member of that org. So two tabs — or the web app and the phone — can each
/// work in a different org without re-scoping one another.
void applyOrgHeader(String? orgId) {
  try {
    final headers = Supabase.instance.client.rest.headers;
    if (orgId == null || orgId.isEmpty) {
      headers.remove('x-org-id');
    } else {
      headers['x-org-id'] = orgId;
    }
  } catch (_) {}
}
