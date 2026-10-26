import 'package:supabase_flutter/supabase_flutter.dart';

/// Road distance (km) for each leg between consecutive [points] (lat, lng),
/// from the `route-distances` server function (Google Directions, saved per
/// trip). Null when it isn't available — the caller then uses straight lines.
Future<List<double>?> roadLegsKm(String? orgId, List<List<double>> points) async {
  if (orgId == null || orgId.isEmpty || points.length < 2) return null;
  try {
    final res = await Supabase.instance.client.functions
        .invoke('route-distances', body: {'orgId': orgId, 'points': points})
        .timeout(const Duration(seconds: 45));
    final data = res.data;
    if (data is Map && data['legs'] is List) {
      final legs = [for (final e in data['legs'] as List) (e as num).toDouble()];
      if (legs.length == points.length - 1) return legs;
    }
  } catch (_) {}
  return null;
}
