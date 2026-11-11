// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;

import '../permissions/permission_registry.dart';

/// Screens a user opened recently, kept in this browser only (per user).
/// Feeds "Jump back in" on the home page. Only real ERP screens from the
/// permission registry are kept, so home, login and settings never show up.
class RecentScreens {
  RecentScreens._();
  static const _max = 8;
  static String _key(String userId) => 'opstation.recent.$userId';

  static void record(String? userId, String path) {
    if (userId == null || userId.isEmpty) return;
    if (!kRouteToPerm.containsKey(path)) return;
    try {
      final list = read(userId).where((e) => e.path != path).toList();
      list.insert(0, RecentScreen(path, DateTime.now()));
      html.window.localStorage[_key(userId)] = jsonEncode([
        for (final e in list.take(_max)) {'p': e.path, 't': e.at.millisecondsSinceEpoch},
      ]);
    } catch (_) {}
  }

  static List<RecentScreen> read(String? userId) {
    if (userId == null || userId.isEmpty) return [];
    try {
      final raw = html.window.localStorage[_key(userId)];
      if (raw == null || raw.isEmpty) return [];
      return [
        for (final m in (jsonDecode(raw) as List))
          if (m is Map && kRouteToPerm.containsKey(m['p']))
            RecentScreen('${m['p']}', DateTime.fromMillisecondsSinceEpoch((m['t'] as num).toInt())),
      ];
    } catch (_) {
      return [];
    }
  }
}

class RecentScreen {
  final String path;
  final DateTime at;
  const RecentScreen(this.path, this.at);
}
