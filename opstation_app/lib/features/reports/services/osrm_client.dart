import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../admin_settings/providers/org_settings_controller.dart';

/// Lightweight point for OSRM requests.
class OsrmPoint {
  final double lat;
  final double lng;
  const OsrmPoint(this.lat, this.lng);

  @override
  String toString() => '$lng,$lat'; // OSRM expects lng,lat
}

/// Client for the OSRM routing service. Default endpoint is the free
/// public demo (router.project-osrm.org) — rate-limited, no SLA.
///
/// Swappable via OrgSettings.osrmBaseUrl (admin setting).
class OsrmClient {
  final Ref _ref;
  OsrmClient(this._ref);

  Future<String> _baseUrl() async {
    final s = await _ref.read(orgSettingsProvider.future);
    return s.osrmBaseUrl;
  }

  /// Road distance between two points in kilometres. Returns null on
  /// network error / rate-limit / malformed response. Callers should
  /// fall back to Haversine.
  Future<double?> roadDistanceKm(OsrmPoint a, OsrmPoint b) async {
    if (a.lat == b.lat && a.lng == b.lng) return 0.0;
    try {
      final base = await _baseUrl();
      final uri = Uri.parse(
          '$base/route/v1/driving/$a;$b?overview=false&alternatives=false&steps=false');
      final resp = await http.get(uri).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (body['code'] != 'Ok') return null;
      final routes = body['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) return null;
      final distMeters = (routes.first['distance'] as num?)?.toDouble();
      return distMeters == null ? null : distMeters / 1000.0;
    } catch (_) {
      return null;
    }
  }

  /// Convenience: distances for a sequence of points, returning a list
  /// with length = points.length - 1. Nulls in the result mean that
  /// segment failed; the caller can fall back per-segment.
  Future<List<double?>> sequenceKm(List<OsrmPoint> points) async {
    if (points.length < 2) return const [];
    final out = <double?>[];
    for (int i = 0; i < points.length - 1; i++) {
      out.add(await roadDistanceKm(points[i], points[i + 1]));
    }
    return out;
  }
}

final osrmClientProvider = Provider<OsrmClient>((ref) => OsrmClient(ref));
