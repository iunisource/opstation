import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'pending_lookups.dart';

/// What the server returns for the legs of a route; replaced in tests.
@visibleForTesting
Future<dynamic> Function(String orgId, List<List<double>> points)? roadLegsInvoker;

final Map<String, List<double>> _legCache = {};
final _legInflight = PendingLookups<List<double>?>();

@visibleForTesting
void clearRoadLegsCache() {
  _legCache.clear();
}

/// Road distance (km) for each leg between consecutive [points] (lat, lng),
/// from the `route-distances` server function (Google Directions, saved per
/// trip). Null when it isn't available — the caller then uses straight lines.
///
/// The answer is remembered for this session: printing the same report again (or two reports that
/// share a route) does not ask the server again. A failed or unavailable answer is not remembered,
/// so the next print tries again.
Future<List<double>?> roadLegsKm(String? orgId, List<List<double>> points) {
  if (orgId == null || orgId.isEmpty || points.length < 2) return Future.value(null);
  final key = '$orgId|${[for (final p in points) '${p[0].toStringAsFixed(5)},${p[1].toStringAsFixed(5)}'].join(';')}';
  final hit = _legCache[key];
  if (hit != null) return Future.value(List<double>.of(hit));
  final job = _legInflight.run(key, () => _fetch(orgId, points).then((r) {
        if (r != null) {
          if (_legCache.length >= 200) _legCache.remove(_legCache.keys.first);
          _legCache[key] = r;
        }
        return r;
      }));
  return job.then((r) => r == null ? null : List<double>.of(r));
}

Future<List<double>?> _fetch(String orgId, List<List<double>> points) async {
  try {
    final invoker = roadLegsInvoker;
    final dynamic data;
    if (invoker != null) {
      data = await invoker(orgId, points);
    } else {
      final res = await Supabase.instance.client.functions
          .invoke('route-distances', body: {'orgId': orgId, 'points': points})
          .timeout(const Duration(seconds: 45));
      data = res.data;
    }
    if (data is Map && data['legs'] is List) {
      final legs = [for (final e in data['legs'] as List) (e as num).toDouble()];
      if (legs.length == points.length - 1) return legs;
    }
  } catch (_) {}
  return null;
}
