import 'dart:math';

import '../../core/utils/route_distances.dart';

/// Everything the Driver Trip Summary of a job (deliveries and pickups) needs: the job,
/// its stops, the distance of every leg, and the start and end places.
class DriverJobReportContext {
  const DriverJobReportContext({
    required this.delivery,
    required this.stops,
    required this.distanceKm,
    required this.returnDistanceKm,
    required this.totalDistanceKm,
    required this.usedGoogle,
    this.startAddress,
    this.endAddress,
    this.startPoint,
    this.endPoint,
  });

  final Map<String, dynamic> delivery;

  /// ALL stops in sequence order (not only the delivered ones).
  final List<Map<String, dynamic>> stops;

  /// One distance per stop that has a GPS point (delivered, with its captured position), in order:
  /// from the previous point (the start for the first stop, when the job's start was recorded).
  final List<double> distanceKm;

  /// Last stop back to the return location; 0 when the job has none.
  final double returnDistanceKm;
  final double totalDistanceKm;
  final bool usedGoogle;

  /// The place names of the start and the end (the recorded point's, else the first / last stop's).
  final String? startAddress;
  final String? endAddress;

  /// Where the job started and ended (the return location), [lat, lng], as recorded by the driver's
  /// phone; null when it was not recorded (older jobs, or no GPS fix at the time).
  final List<double>? startPoint;
  final List<double>? endPoint;

  /// The distance of each stop that has a GPS point, by stop id: from the previous point (the start
  /// for the first stop, when it was recorded).
  Map<String, double> get legKmByStop {
    final out = <String, double>{};
    var i = 0;
    for (final s in stops) {
      if (DriverJobReport.hasGps(s)) {
        if (i < distanceKm.length) out['${s['id']}'] = distanceKm[i];
        i++;
      }
    }
    return out;
  }
}

/// Splits the consecutive leg distances of a job's route into the per-stop distances and the
/// way back. The points are [start?], stop 1 ... stop n, [return?]; [legs] are the distances
/// between neighbours (one fewer than the points). Same rule as the driver's phone.
class DriverJobLegs {
  const DriverJobLegs(this.distances, this.returnKm);

  final List<double> distances;
  final double returnKm;

  static DriverJobLegs split({
    required int stopCount,
    required bool hasStart,
    required bool hasEnd,
    required List<double> legs,
  }) {
    final off = hasStart ? 1 : 0;
    double leg(int k) => (k >= 0 && k < legs.length) ? legs[k] : 0.0;
    return DriverJobLegs(
      [for (var i = 0; i < stopCount; i++) i == 0 ? (hasStart ? leg(0) : 0.0) : leg(off + i - 1)],
      (hasEnd && stopCount > 0) ? leg(off + stopCount - 1) : 0.0,
    );
  }
}

typedef RoadLegs = Future<List<double>?> Function(String? orgId, List<List<double>> points);
typedef PlaceLookup = Future<String?> Function(double lat, double lng, DateTime until);

class DriverJobReport {
  DriverJobReport._();

  /// The stops in sequence order.
  static List<Map<String, dynamic>> orderedStops(List<Map<String, dynamic>> stops) =>
      [...stops]..sort((a, b) => ((a['sequence'] as num?) ?? 0).compareTo((b['sequence'] as num?) ?? 0));

  /// A stop that counts for the distance: delivered (or picked up) with the position it was marked at.
  static bool hasGps(Map<String, dynamic> s) =>
      s['status'] == 'delivered' && s['captured_lat'] is num && s['captured_lng'] is num;

  static double? _num(Object? v) => v is num ? v.toDouble() : null;

  static Future<DriverJobReportContext> build({
    required Map<String, dynamic> delivery,
    required List<Map<String, dynamic>> stops,
    String? orgId,
    RoadLegs? roadLegs,
    PlaceLookup? placeLookup,
  }) async {
    final ordered = orderedStops(stops);
    final gps = [for (final s in ordered) if (hasGps(s)) s];

    // Where the job started and ended (the return location), when the driver's phone recorded
    // them (deliveries.start_lat ... end_lng); the first / last stop stand in for them otherwise.
    final sLat = _num(delivery['start_lat']), sLng = _num(delivery['start_lng']);
    final eLat = _num(delivery['end_lat']), eLng = _num(delivery['end_lng']);
    final hasStart = sLat != null && sLng != null;
    final hasEnd = eLat != null && eLng != null;

    final lookup = placeLookup; // the page passes the shared place-name lookup; null = no names
    // The free lookup can be slow; the person waits for the report anyway, so it gets time.
    final until = DateTime.now().add(const Duration(seconds: 25));
    // A name the driver's phone already looked up and saved with the point (deliveries.start_place / end_place).
    String? stored(Object? v) {
      final t = '${v ?? ''}'.trim();
      return t.isEmpty ? null : t;
    }

    Future<String?> place(double lat, double lng) async {
      try {
        if (lookup != null) return await lookup(lat, lng, until);
      } catch (_) {}
      return null;
    }

    String? startAddress, endAddress;
    await Future.wait([
      if (delivery['started_at'] != null)
        () async {
          if (hasStart) {
            startAddress = stored(delivery['start_place']) ?? await place(sLat, sLng);
          } else if (gps.isNotEmpty) {
            startAddress = await place((gps.first['captured_lat'] as num).toDouble(), (gps.first['captured_lng'] as num).toDouble());
          }
        }(),
      if (delivery['completed_at'] != null)
        () async {
          if (hasEnd) {
            endAddress = stored(delivery['end_place']) ?? await place(eLat, eLng);
          } else if (gps.isNotEmpty) {
            endAddress = await place((gps.last['captured_lat'] as num).toDouble(), (gps.last['captured_lng'] as num).toDouble());
          }
        }(),
    ]);

    if (gps.isEmpty) {
      return DriverJobReportContext(
        delivery: delivery,
        stops: ordered,
        distanceKm: const [],
        returnDistanceKm: 0,
        totalDistanceKm: 0,
        usedGoogle: false,
        startAddress: startAddress,
        endAddress: endAddress,
        startPoint: hasStart ? [sLat, sLng] : null,
        endPoint: hasEnd ? [eLat, eLng] : null,
      );
    }

    // The route: [start] -> stops -> [return location].
    final points = <List<double>>[
      if (hasStart) [sLat, sLng],
      for (final s in gps) [(s['captured_lat'] as num).toDouble(), (s['captured_lng'] as num).toDouble()],
      if (hasEnd) [eLat, eLng],
    ];
    List<double>? road;
    if (points.length >= 2) {
      try {
        road = await (roadLegs ?? roadLegsKm)(orgId, points);
      } catch (_) {}
    }
    final legs = <double>[
      for (var k = 0; k + 1 < points.length; k++)
        (road != null && k < road.length) ? road[k] : _haversineKm(points[k][0], points[k][1], points[k + 1][0], points[k + 1][1]),
    ];
    final split = DriverJobLegs.split(stopCount: gps.length, hasStart: hasStart, hasEnd: hasEnd, legs: legs);
    return DriverJobReportContext(
      delivery: delivery,
      stops: ordered,
      distanceKm: split.distances,
      returnDistanceKm: split.returnKm,
      totalDistanceKm: split.distances.fold<double>(0, (s, d) => s + d) + split.returnKm,
      usedGoogle: road != null,
      startAddress: startAddress,
      endAddress: endAddress,
      startPoint: hasStart ? [sLat, sLng] : null,
      endPoint: hasEnd ? [eLat, eLng] : null,
    );
  }

  static double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const earthKm = 6371.0;
    double rad(double d) => d * pi / 180.0;
    final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) + cos(rad(lat1)) * cos(rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    return earthKm * 2 * atan2(sqrt(a), sqrt(1 - a));
  }
}
