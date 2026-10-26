import 'package:supabase_flutter/supabase_flutter.dart';

import 'google_directions_service.dart';

/// Road distance (km) per leg from the `route-distances` server function —
/// the same saved result the web reports use, so app and web show the same
/// distance for a trip. Null if unavailable (offline, not deployed …).
Future<List<double>?> serverRoadLegsKm(String? orgId, List<DirectionsPoint> points) async {
  if (orgId == null || orgId.isEmpty || points.length < 2) return null;
  try {
    final res = await Supabase.instance.client.functions
        .invoke('route-distances', body: {
          'orgId': orgId,
          'points': [for (final p in points) [p.lat, p.lng]],
        })
        .timeout(const Duration(seconds: 45));
    final data = res.data;
    if (data is Map && data['legs'] is List) {
      final legs = [for (final e in data['legs'] as List) (e as num).toDouble()];
      if (legs.length == points.length - 1) return legs;
    }
  } catch (_) {}
  return null;
}
