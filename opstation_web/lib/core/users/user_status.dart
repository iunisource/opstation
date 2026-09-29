import 'package:supabase_flutter/supabase_flutter.dart';

/// Activate / deactivate / archive users through the server functions from
/// 289_user_deactivate_sticky_archive.sql. Those are the ONLY way a
/// deactivated or archived user can be restored — a plain row update (old app
/// versions re-syncing, upserts) can no longer bring them back.
///
/// Returns null on success, or a short error message.

bool _missingFn(Object e) {
  final s = e.toString().toLowerCase();
  return s.contains('could not find the function') ||
      s.contains('does not exist') ||
      s.contains('pgrst202');
}

String _short(Object e) {
  final s = e.toString();
  final m = RegExp(r'message: ([^,]+)').firstMatch(s);
  return (m?.group(1) ?? s.split('\n').first).trim();
}

Future<String?> setUserActive(String userId, bool active) async {
  final c = Supabase.instance.client;
  try {
    await c.rpc('set_user_active', params: {'p_user': userId, 'p_active': active});
    return null;
  } catch (e) {
    if (!_missingFn(e)) return _short(e);
    // Migration not run yet — plain update (not sticky until it is).
    try {
      await c.from('users').update({'is_active': active}).eq('id', userId);
      return null;
    } catch (e2) {
      return _short(e2);
    }
  }
}

Future<String?> setUserArchived(String userId, bool archived) async {
  try {
    await Supabase.instance.client
        .rpc('set_user_archived', params: {'p_user': userId, 'p_archived': archived});
    return null;
  } catch (e) {
    if (_missingFn(e)) {
      return 'Archiving needs the database update — run 289_user_deactivate_sticky_archive.sql';
    }
    return _short(e);
  }
}

bool isArchivedUser(Map<String, dynamic> u) => u['is_archived'] == true;
