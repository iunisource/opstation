// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:supabase_flutter/supabase_flutter.dart';

/// Why a user ended up back on the login screen, and whether this computer's
/// clock is wrong — so a "logged out after 5 seconds" problem shows its reason.
class SessionDiagnostics {
  SessionDiagnostics._();

  static const _reasonKey = 'opstation.logout_reason';

  /// Set while the user (or the app on purpose) is signing out, so that sign-out
  /// is not reported as an unexpected one.
  static bool intentionalSignOut = false;

  /// Remember that the session ended without the user pressing Log out.
  static void recordUnexpectedSignOut() {
    if (intentionalSignOut) return;
    try {
      html.window.localStorage[_reasonKey] = '${DateTime.now().toIso8601String()}|session_ended';
    } catch (_) {}
  }

  /// Returns the stored unexpected-logout time (within the last hour), once.
  static DateTime? takeUnexpectedSignOut() {
    try {
      final v = html.window.localStorage.remove(_reasonKey);
      if (v == null) return null;
      final at = DateTime.tryParse(v.split('|').first);
      if (at == null || DateTime.now().difference(at) > const Duration(hours: 1)) return null;
      return at;
    } catch (_) {
      return null;
    }
  }

  /// How far this computer's clock is from the server's (positive = computer is
  /// ahead). Null if the server could not be reached.
  static Future<Duration?> clockSkew() async {
    try {
      final t0 = DateTime.now().toUtc();
      final res = await Supabase.instance.client.rpc('server_now');
      final t1 = DateTime.now().toUtc();
      final server = DateTime.tryParse('$res')?.toUtc();
      if (server == null) return null;
      final mid = t0.add(Duration(microseconds: t1.difference(t0).inMicroseconds ~/ 2));
      return mid.difference(server);
    } catch (_) {
      return null;
    }
  }

  /// "3 hours 12 min ahead" / "45 min behind".
  static String describe(Duration skew) {
    final ahead = !skew.isNegative;
    final a = skew.abs();
    final parts = <String>[
      if (a.inDays > 0) '${a.inDays} day${a.inDays == 1 ? '' : 's'}',
      if (a.inHours % 24 > 0) '${a.inHours % 24} h',
      if (a.inMinutes % 60 > 0 || a.inHours == 0) '${a.inMinutes % 60} min',
    ];
    return '${parts.join(' ')} ${ahead ? 'ahead' : 'behind'}';
  }
}
