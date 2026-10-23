import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/app_database.dart';
import 'geo_utils.dart';

/// An extra location of a customer (SQL 409), e.g. "Godown". The customer's
/// own latitude / longitude is always "Main".
class CustomerExtraLocation {
  final String id;
  final String customerId;
  final String name;
  final double lat;
  final double lng;
  const CustomerExtraLocation(this.id, this.customerId, this.name, this.lat, this.lng);

  Map<String, dynamic> toJson() => {'id': id, 'c': customerId, 'n': name, 'la': lat, 'lo': lng};
  static CustomerExtraLocation? fromJson(Map<String, dynamic> m) {
    final la = (m['la'] as num?)?.toDouble(), lo = (m['lo'] as num?)?.toDouble();
    if (la == null || lo == null || m['c'] == null) return null;
    return CustomerExtraLocation('${m['id']}', '${m['c']}', '${m['n'] ?? ''}', la, lo);
  }
}

/// The nearest of a customer's locations to a point.
class NearestLocation {
  final double distanceMeters;
  /// null = Main (the customer's own location).
  final String? name;
  const NearestLocation(this.distanceMeters, this.name);
}

/// Phone-side copy of every customer's extra locations. Fetched from the
/// server with the routes and kept on the phone for offline use, so visits are
/// verified against all of a customer's locations even without signal.
class CustomerLocations {
  CustomerLocations._();

  static const _cacheKey = 'cache.customer_locations';
  static Map<String, List<CustomerExtraLocation>> _byCustomer = {};
  static bool _loaded = false;

  /// Reads the copy saved on the phone (once per app run).
  static Future<void> ensureLoaded(AppDatabase db) async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await db.getConfig(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final list = <CustomerExtraLocation>[];
      for (final e in (jsonDecode(raw) as List)) {
        final l = CustomerExtraLocation.fromJson(Map<String, dynamic>.from(e as Map));
        if (l != null) list.add(l);
      }
      _set(list);
    } catch (_) {}
  }

  /// Fetches the org's extra locations from the server and saves them on the
  /// phone. A failure keeps the last saved copy.
  static Future<void> refresh(AppDatabase db, String orgId) async {
    try {
      final all = <CustomerExtraLocation>[];
      const page = 1000;
      for (var from = 0;; from += page) {
        final rows = await Supabase.instance.client
            .from('customer_locations')
            .select('id, customer_id, name, latitude, longitude')
            .eq('org_id', orgId)
            .order('id')
            .range(from, from + page - 1);
        final list = rows as List;
        for (final r in list) {
          final m = Map<String, dynamic>.from(r as Map);
          final la = (m['latitude'] as num?)?.toDouble(), lo = (m['longitude'] as num?)?.toDouble();
          if (la == null || lo == null) continue;
          all.add(CustomerExtraLocation('${m['id']}', '${m['customer_id']}', '${m['name'] ?? ''}', la, lo));
        }
        if (list.length < page) break;
      }
      _loaded = true;
      _set(all);
      await db.setConfig(_cacheKey, jsonEncode([for (final l in all) l.toJson()]));
    } catch (_) {
      // Table not there yet / offline — keep what the phone has.
      await ensureLoaded(db);
    }
  }

  static void _set(List<CustomerExtraLocation> all) {
    final m = <String, List<CustomerExtraLocation>>{};
    for (final l in all) {
      (m[l.customerId] ??= []).add(l);
    }
    for (final v in m.values) {
      v.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    _byCustomer = m;
  }

  /// Replace one customer's list right after an admin changes it.
  static Future<void> replaceFor(AppDatabase db, String customerId, List<CustomerExtraLocation> list) async {
    final m = Map<String, List<CustomerExtraLocation>>.from(_byCustomer);
    if (list.isEmpty) {
      m.remove(customerId);
    } else {
      m[customerId] = list;
    }
    _byCustomer = m;
    try {
      await db.setConfig(_cacheKey, jsonEncode([for (final v in m.values) for (final l in v) l.toJson()]));
    } catch (_) {}
  }

  static List<CustomerExtraLocation> of(String customerId) => _byCustomer[customerId] ?? const [];

  /// True when the customer has any location at all (Main or extra).
  static bool hasAny(String customerId, double? mainLat, double? mainLng) =>
      (mainLat != null && mainLng != null) || of(customerId).isNotEmpty;

  /// The customer's location nearest to [lat], [lng]; null when it has none.
  static NearestLocation? nearest(String customerId, double? mainLat, double? mainLng, double lat, double lng) {
    NearestLocation? best;
    if (mainLat != null && mainLng != null) {
      best = NearestLocation(GeoUtils.distanceMeters(mainLat, mainLng, lat, lng), null);
    }
    for (final l in of(customerId)) {
      final d = GeoUtils.distanceMeters(l.lat, l.lng, lat, lng);
      if (best == null || d < best.distanceMeters) best = NearestLocation(d, l.name);
    }
    return best;
  }

  /// Name of the extra location a verified visit was at ("" for Main / unknown).
  static String visitLocationName(String customerId, double? mainLat, double? mainLng, double? lat, double? lng) {
    if (lat == null || lng == null || of(customerId).isEmpty) return '';
    return nearest(customerId, mainLat, mainLng, lat, lng)?.name ?? '';
  }
}
