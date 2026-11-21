import 'dart:convert';

import '../database/app_database.dart';

/// A GPS point taken when a job starts or ends.
class DeliveryLocation {
  const DeliveryLocation(this.lat, this.lng, {this.accuracy, this.name});

  final double lat;
  final double lng;
  final double? accuracy;

  /// The place name ("Johar Town, Lahore"), once it has been looked up; null before that.
  final String? name;
}

/// Where a driver's job started and where it ended (the return location), like a
/// salesperson's route start and end. Kept in the phone's config store (the delivery
/// table has no columns for it) and sent to the server's deliveries table when it has
/// start_lat, start_lng, end_lat and end_lng; the driver report uses them for the
/// distance from the start to the first stop and from the last stop back.
class DeliveryLocations {
  DeliveryLocations._();

  static String _key(String id) => 'delivery.loc.$id';

  static Future<Map<String, dynamic>> _read(AppDatabase db, String id) async {
    try {
      final raw = await db.getConfig(_key(id));
      if (raw == null || raw.isEmpty) return {};
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static DeliveryLocation? _loc(Map<String, dynamic> m, String p) {
    final lat = m['${p}Lat'], lng = m['${p}Lng'];
    if (lat is! num || lng is! num) return null;
    final name = '${m['${p}Name'] ?? ''}'.trim();
    return DeliveryLocation(lat.toDouble(), lng.toDouble(), accuracy: (m['${p}Acc'] as num?)?.toDouble(), name: name.isEmpty ? null : name);
  }

  static Future<({DeliveryLocation? start, DeliveryLocation? end})> read(AppDatabase db, String id) async {
    final m = await _read(db, id);
    return (start: _loc(m, 's'), end: _loc(m, 'e'));
  }

  /// Saves the start (or end) point of the job. A later save of the same point replaces it.
  static Future<void> save(AppDatabase db, String id, {required bool isStart, required double lat, required double lng, double? accuracy}) async {
    final m = await _read(db, id);
    final p = isStart ? 's' : 'e';
    m['${p}Lat'] = lat;
    m['${p}Lng'] = lng;
    m.remove('${p}Name'); // a new position: its name is looked up afresh
    if (accuracy != null) m['${p}Acc'] = accuracy;
    await db.setConfig(_key(id), jsonEncode(m));
  }

  /// Gives a recorded point its place name (looked up after it was recorded). A point that was
  /// replaced in the meantime (a new position) loses the old name, so the name is only kept when
  /// the point is still the one it was looked up for.
  static Future<void> saveName(AppDatabase db, String id, {required bool isStart, required String name, required double lat, required double lng}) async {
    final n = name.trim();
    if (n.isEmpty) return;
    final m = await _read(db, id);
    final p = isStart ? 's' : 'e';
    if (m['${p}Lat'] != lat || m['${p}Lng'] != lng) return;
    m['${p}Name'] = n;
    await db.setConfig(_key(id), jsonEncode(m));
  }

  /// The columns of the server's deliveries row (only the points that exist, and their names).
  static Map<String, dynamic> serverColumns(DeliveryLocation? start, DeliveryLocation? end) => {
        if (start != null) ...{'start_lat': start.lat, 'start_lng': start.lng},
        if (end != null) ...{'end_lat': end.lat, 'end_lng': end.lng},
        if (start?.name != null) 'start_place': start!.name,
        if (end?.name != null) 'end_place': end!.name,
      };

  /// A delivery row pulled from the server: fills in the points this phone does not have
  /// (another phone, or a reinstall). The phone's own points are never replaced.
  static Future<void> mergePulled(AppDatabase db, Map<String, dynamic> serverRow) async {
    final id = '${serverRow['id']}';
    final m = await _read(db, id);
    var changed = false;
    for (final p in const ['s', 'e']) {
      final col = p == 's' ? 'start' : 'end';
      final lat = serverRow['${col}_lat'], lng = serverRow['${col}_lng'];
      if (lat is num && lng is num && m['${p}Lat'] is! num) {
        m['${p}Lat'] = lat.toDouble();
        m['${p}Lng'] = lng.toDouble();
        changed = true;
      }
      // The server's place name, when this phone has the point but not its name.
      final place = '${serverRow['${col}_place'] ?? ''}'.trim();
      if (place.isNotEmpty && m['${p}Lat'] is num && '${m['${p}Name'] ?? ''}'.trim().isEmpty) {
        m['${p}Name'] = place;
        changed = true;
      }
    }
    if (changed) await db.setConfig(_key(id), jsonEncode(m));
  }
}
