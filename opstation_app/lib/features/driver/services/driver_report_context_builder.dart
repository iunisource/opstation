import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/config/maps_config.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/services/google_directions_service.dart';
import '../../../core/utils/delivery_locations.dart';
import '../../dispatch/models/delivery.dart';
import '../../reports/services/nominatim_client.dart';

class DriverReportContext {
  final Delivery delivery;

  /// ALL stops in sequence order (not just delivered).
  final List<DeliveryStop> orderedStops;

  /// Distance per leg. Index 0 = start point to first stop.
  /// Index N = stop[N-1] to stop[N].
  /// Last extra entry = last stop to end point (return leg).
  final List<double> distanceKm;

  /// Return leg distance (last stop to delivery end point).
  final double returnDistanceKm;

  final double totalDistanceKm;
  final bool usedGoogle;

  /// Reverse geocoded start address (nullable).
  final String? startAddress;

  /// Reverse geocoded end address (nullable).
  final String? endAddress;

  /// Where the job started and ended (the return location), as recorded by the driver's phone;
  /// null when it was not recorded (older jobs, or no GPS fix at the time).
  final DeliveryLocation? startPoint;
  final DeliveryLocation? endPoint;

  const DriverReportContext({
    required this.delivery,
    required this.orderedStops,
    required this.distanceKm,
    required this.returnDistanceKm,
    required this.totalDistanceKm,
    required this.usedGoogle,
    this.startAddress,
    this.endAddress,
    this.startPoint,
    this.endPoint,
  });

  /// The distance of each stop that has a GPS point (delivered, with its position), by stop id:
  /// from the previous point (the start for the first stop, when it was recorded).
  Map<String, double> get legKmByStop {
    final out = <String, double>{};
    var i = 0;
    for (final s in orderedStops) {
      if (s.status == DeliveryStopStatus.delivered && s.capturedLat != null && s.capturedLng != null) {
        if (i < distanceKm.length) out[s.id] = distanceKm[i];
        i++;
      }
    }
    return out;
  }
}

/// Splits the consecutive leg distances of a job's route into the per-stop distances
/// and the way back. The points are [start?], stop 1 ... stop n, [return?]; [legs] are
/// the distances between neighbours (so one fewer than the points).
class DriverLegs {
  const DriverLegs(this.distances, this.returnKm);

  /// One per stop: the distance from the previous point (the start for the first stop).
  final List<double> distances;

  /// Last stop to the return location; 0 when the job has no return location.
  final double returnKm;

  static DriverLegs split({
    required int stopCount,
    required bool hasStart,
    required bool hasEnd,
    required List<double> legs,
  }) {
    final off = hasStart ? 1 : 0;
    double leg(int k) => (k >= 0 && k < legs.length) ? legs[k] : 0.0;
    return DriverLegs(
      [
        for (var i = 0; i < stopCount; i++) i == 0 ? (hasStart ? leg(0) : 0.0) : leg(off + i - 1),
      ],
      (hasEnd && stopCount > 0) ? leg(off + stopCount - 1) : 0.0,
    );
  }
}

class DriverReportContextBuilder {
  final Ref _ref;
  DriverReportContextBuilder(this._ref);

  Future<DriverReportContext> build(Delivery delivery) async {
    final nomi = _ref.read(nominatimClientProvider);

    // All stops in sequence order regardless of status.
    final ordered = List<DeliveryStop>.from(delivery.stops)
      ..sort((a, b) => a.sequence.compareTo(b.sequence));

    // Delivered stops with GPS — used for distance calculation.
    final gpsStops = ordered
        .where((s) =>
            s.status == DeliveryStopStatus.delivered &&
            s.capturedLat != null &&
            s.capturedLng != null)
        .toList();

    // Where the job started and where it ended (the return location), when the driver's
    // phone recorded them; the first / last stop stand in for them otherwise.
    final locs = await DeliveryLocations.read(_ref.read(appDatabaseProvider), delivery.id);

    // Reverse geocode start + end addresses in parallel.
    String? startAddress;
    String? endAddress;
    final delivery_ = delivery;
    await Future.wait([
      if (delivery_.startedAt != null)
        () async {
          final p = locs.start;
          if (p != null) {
            startAddress = await nomi.reverseGeocode(p.lat, p.lng);
          } else if (gpsStops.isNotEmpty) {
            startAddress = await nomi.reverseGeocode(
              gpsStops.first.capturedLat!,
              gpsStops.first.capturedLng!,
            );
          }
        }(),
      if (delivery_.completedAt != null)
        () async {
          final p = locs.end;
          if (p != null) {
            endAddress = await nomi.reverseGeocode(p.lat, p.lng);
          } else if (gpsStops.isNotEmpty) {
            endAddress = await nomi.reverseGeocode(
              gpsStops.last.capturedLat!,
              gpsStops.last.capturedLng!,
            );
          }
        }(),
    ]);

    if (gpsStops.isEmpty) {
      return DriverReportContext(
        delivery: delivery,
        orderedStops: ordered,
        distanceKm: const [],
        returnDistanceKm: 0,
        totalDistanceKm: 0,
        usedGoogle: false,
        startAddress: startAddress,
        endAddress: endAddress,
        startPoint: locs.start,
        endPoint: locs.end,
      );
    }

    // The route: [start] -> stops -> [return location].
    final points = [
      if (locs.start != null) DirectionsPoint(locs.start!.lat, locs.start!.lng),
      for (final s in gpsStops) DirectionsPoint(s.capturedLat!, s.capturedLng!),
      if (locs.end != null) DirectionsPoint(locs.end!.lat, locs.end!.lng),
    ];

    bool usedGoogle = false;
    List<double>? googleLegs;
    if (MapsConfig.hasKey && points.length >= 2) {
      googleLegs = await GoogleDirectionsService.getLegsKm(points);
      if (googleLegs != null) usedGoogle = true;
    }

    final legs = <double>[
      for (var k = 0; k + 1 < points.length; k++)
        (googleLegs != null && k < googleLegs.length)
            ? googleLegs[k]
            : _haversineKm(points[k].lat, points[k].lng, points[k + 1].lat, points[k + 1].lng),
    ];
    final split = DriverLegs.split(
      stopCount: gpsStops.length,
      hasStart: locs.start != null,
      hasEnd: locs.end != null,
      legs: legs,
    );
    final distances = split.distances;
    final returnKm = split.returnKm;

    final total = distances.fold<double>(0, (s, d) => s + d) + returnKm;

    return DriverReportContext(
      delivery: delivery,
      orderedStops: ordered,
      distanceKm: distances,
      returnDistanceKm: returnKm,
      totalDistanceKm: total,
      usedGoogle: usedGoogle,
      startAddress: startAddress,
      endAddress: endAddress,
      startPoint: locs.start,
      endPoint: locs.end,
    );
  }

  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const earthKm = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthKm * c;
  }

  double _rad(double deg) => deg * (pi / 180.0);
}

final driverReportContextBuilderProvider =
    Provider<DriverReportContextBuilder>(
        (ref) => DriverReportContextBuilder(ref));
