import 'dart:async';
import 'dart:convert';

import '../database/app_database.dart';

/// Visits marked on the Free Route WITHOUT a customer: a tap on "Mark visit"
/// records the phone's GPS point (and, a moment later, the place name).
///
/// They are kept in the phone's config store until they reach the server, so the
/// customer-visit tables — and everything that reads them — stay untouched. On
/// the server they are an ordinary `visits` row with customer_id NULL and
/// skip_reason 'free'. Trip reports (phone and web) list them as visit lines
/// with the place name, and their GPS point counts in the trip's distance.
class FreeVisits {
  FreeVisits._();

  static const _key = 'queue.free_visits';

  /// skip_reason on the server row — what the reports look for.
  static const marker = 'free';

  /// Where the picture of a free visit is stored (bucket opstation-photos), the same
  /// folder scheme as a customer visit's pictures: unique per visit.
  static String photoRemotePath({required String userId, required String userName, required String visitId, required DateTime at}) {
    final safeName = userName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final date = at.toIso8601String().split('T').first;
    return 'visits/$userId/${safeName}_${date}_free_$visitId.jpg';
  }

  /// The value of the server row's photo_paths_json for a free visit [row]: its
  /// picture, or an empty list for a visit without one.
  static String photoPathsJson(Map<String, dynamic> row) {
    final photo = row['photo'];
    return jsonEncode(photo is String && photo.isNotEmpty ? [photo] : const <String>[]);
  }

  // One reader/writer at a time: a visit saved while a sync is running must not
  // be overwritten by the sync's write.
  static Future<void> _chain = Future.value();
  static Future<T> _locked<T>(Future<T> Function() fn) {
    final c = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        c.complete(await fn());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  static Future<List<Map<String, dynamic>>> _read(AppDatabase db) async {
    try {
      final raw = await db.getConfig(_key);
      if (raw == null || raw.isEmpty) return [];
      return [for (final e in jsonDecode(raw) as List) Map<String, dynamic>.from(e as Map)];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _write(AppDatabase db, List<Map<String, dynamic>> rows) =>
      db.setConfig(_key, jsonEncode(rows));

  /// Save a new free visit (not yet on the server).
  static Future<void> add(AppDatabase db, Map<String, dynamic> row) => _locked(() async {
        final rows = await _read(db);
        rows.add({...row, 'synced': false});
        await _write(db, _trimmed(rows));
      });

  // Bounded history: the newest 400 visits are kept (older ones that are fully
  // sent are dropped first), so the store never grows without limit.
  static List<Map<String, dynamic>> _trimmed(List<Map<String, dynamic>> rows) {
    const keep = 400;
    if (rows.length <= keep) return rows;
    final sorted = [...rows]..sort((a, b) => ((b['ts'] as num?) ?? 0).compareTo((a['ts'] as num?) ?? 0));
    final out = <Map<String, dynamic>>[];
    final unsent = [for (final r in sorted) if (r['synced'] != true) r];
    out.addAll(unsent); // never drop a visit that has not reached the server
    for (final r in sorted) {
      if (out.length >= keep) break;
      if (r['synced'] == true) out.add(r);
    }
    return out;
  }

  /// Visits of other people (or of this phone before a reinstall) that the
  /// server sent down: kept so a trip report made on this phone lists them too.
  static Future<void> mergePulled(AppDatabase db, List<Map<String, dynamic>> serverRows) => _locked(() async {
        final rows = await _read(db);
        final have = {for (final r in rows) '${r['id']}'};
        var changed = false;
        for (final s in serverRows) {
          final id = '${s['id']}';
          if (have.contains(id)) continue;
          final ts = DateTime.tryParse('${s['timestamp']}')?.millisecondsSinceEpoch;
          final lat = s['captured_lat'], lng = s['captured_lng'];
          if (ts == null || lat is! num || lng is! num) continue;
          final place = (s['location_name'] as String?)?.trim();
          rows.add({
            'id': id,
            'trip_id': s['trip_id'],
            'org_id': s['org_id'],
            'ts': ts,
            'lat': lat.toDouble(),
            'lng': lng.toDouble(),
            'acc': (s['accuracy_meters'] as num?)?.toDouble(),
            'user_id': s['user_id'],
            'user_name': s['user_name'],
            'user_role': s['user_role'],
            'synced': true,
            if (place != null && place.isNotEmpty) ...{'place': place, 'place_synced': true},
          });
          changed = true;
        }
        if (changed) await _write(db, _trimmed(rows));
      });

  /// This trip's free visits on this phone, oldest first.
  static Future<List<Map<String, dynamic>>> forTrip(AppDatabase db, String tripId) async {
    final rows = await _locked(() => _read(db));
    return [for (final r in rows) if (r['trip_id'] == tripId) r]
      ..sort((a, b) => ((a['ts'] as num?) ?? 0).compareTo((b['ts'] as num?) ?? 0));
  }

  static Future<int> countForTrip(AppDatabase db, String tripId) async => (await forTrip(db, tripId)).length;

  /// Ids of the trips that have at least one free visit.
  static Future<Set<String>> tripIdsWithVisits(AppDatabase db) async {
    final rows = await _locked(() => _read(db));
    return {for (final r in rows) '${r['trip_id']}'};
  }

  /// Send the visits that have not reached the server yet, one at a time, via
  /// [push]. A failure leaves the visit pending for the next sync. Returns how
  /// many were sent.
  static Future<int> pushPending(AppDatabase db, Future<void> Function(Map<String, dynamic> row) push) async {
    final pending = await _locked(() async => [
          for (final r in await _read(db))
            if (r['synced'] != true) r
        ]);
    final sentIds = <String>{};
    for (final r in pending) {
      try {
        await push(r);
        sentIds.add('${r['id']}');
      } catch (_) {
        // offline / trip not on the server yet: stays pending, retried next sync
      }
    }
    if (sentIds.isNotEmpty) {
      await _locked(() async {
        final rows = await _read(db);
        for (final r in rows) {
          if (sentIds.contains('${r['id']}')) r['synced'] = true;
        }
        await _write(db, rows);
      });
    }
    return sentIds.length;
  }

  /// Look up the place name of visits that have none yet (OpenStreetMap, one at
  /// a time — the lookup client keeps to the service's rate limit). At most [max]
  /// per call, only [tripId]'s when given. A failed lookup is retried later.
  /// Returns how many names were found.
  static Future<int> fillPlaces(
    AppDatabase db,
    Future<String?> Function(double lat, double lng) lookup, {
    int max = 4,
    String? tripId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final todo = await _locked(() async => [
          for (final r in await _read(db))
            if (r['place'] == null &&
                (tripId == null || r['trip_id'] == tripId) &&
                now - ((r['place_tried'] as num?)?.toInt() ?? 0) > 120000 &&
                r['lat'] is num &&
                r['lng'] is num)
              r
        ]);
    final found = <String, String>{};
    final tried = <String>{};
    for (final r in todo.take(max)) {
      String? name;
      try {
        name = await lookup((r['lat'] as num).toDouble(), (r['lng'] as num).toDouble());
      } catch (_) {}
      if (name != null && name.trim().isNotEmpty) {
        found['${r['id']}'] = name.trim();
      } else {
        tried.add('${r['id']}');
      }
    }
    if (found.isNotEmpty || tried.isNotEmpty) {
      await _locked(() async {
        final rows = await _read(db);
        for (final r in rows) {
          final id = '${r['id']}';
          if (found.containsKey(id)) {
            r['place'] = found[id];
          } else if (tried.contains(id)) {
            r['place_tried'] = DateTime.now().millisecondsSinceEpoch;
          }
        }
        await _write(db, rows);
      });
    }
    return found.length;
  }

  /// Send place names for visits that are already on the server.
  static Future<int> pushPlaces(AppDatabase db, Future<void> Function(String id, String name) push) async {
    final todo = await _locked(() async => [
          for (final r in await _read(db))
            if (r['synced'] == true && r['place'] != null && r['place_synced'] != true) r
        ]);
    final sent = <String>{};
    for (final r in todo) {
      try {
        await push('${r['id']}', '${r['place']}');
        sent.add('${r['id']}');
      } catch (_) {}
    }
    if (sent.isNotEmpty) {
      await _locked(() async {
        final rows = await _read(db);
        for (final r in rows) {
          if (sent.contains('${r['id']}')) r['place_synced'] = true;
        }
        await _write(db, rows);
      });
    }
    return sent.length;
  }
}
