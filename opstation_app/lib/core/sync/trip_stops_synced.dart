import 'package:shared_preferences/shared_preferences.dart';

/// Trips whose full shop list is confirmed on the server. Recent trips not in
/// this set get their shop list re-sent on the next sync until it lands.
class TripStopsSynced {
  static const _key = 'trip_stops_synced_v1';
  static Set<String>? _cache;

  static Future<Set<String>> _load() async {
    if (_cache != null) return _cache!;
    try {
      final p = await SharedPreferences.getInstance();
      _cache = (p.getStringList(_key) ?? const <String>[]).toSet();
    } catch (_) {
      _cache = <String>{};
    }
    return _cache!;
  }

  static Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = _cache!.toList();
      // keep it small: the newest 300 ids are plenty (only 2 days are retried)
      await p.setStringList(_key, list.length > 300 ? list.sublist(list.length - 300) : list);
    } catch (_) {}
  }

  static Future<bool> isSynced(String tripId) async => (await _load()).contains(tripId);

  static Future<void> mark(String tripId) async {
    final s = await _load();
    s.remove(tripId);
    s.add(tripId);
    await _save();
  }

  static Future<void> unmark(String tripId) async {
    final s = await _load();
    if (s.remove(tripId)) await _save();
  }
}
