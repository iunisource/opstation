import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/config/maps_config.dart';
import '../../../core/services/google_directions_service.dart';
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

  const DriverReportContext({
    required this.delivery,
    required this.orderedStops,
    required this.distanceKm,
    required this.returnDistanceKm,
    required this.totalDistanceKm,
    required this.usedGoogle,
    this.startAddress,
    this.endAddress,
  });
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

    // Reverse geocode start + end addresses in parallel.
    String? startAddress;
    String? endAddress;
    final delivery_ = delivery;
    await Future.wait([
      if (delivery_.startedAt != null)
        () async {
          // We don't have start GPS on delivery — use first stop GPS as proxy
          if (gpsStops.isNotEmpty) {
            startAddress = await nomi.reverseGeocode(
              gpsStops.first.capturedLat!,
              gpsStops.first.capturedLng!,
            );
          }
        }(),
      if (delivery_.completedAt != null)
        () async {
          if (gpsStops.isNotEmpty) {
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
      );
    }

    // Build point sequence for Google Directions.
    final allPoints = [
      for (final s in gpsStops)
        DirectionsPoint(s.capturedLat!, s.capturedLng!),
    ];

    bool usedGoogle = false;
    List<double>? googleLegs;
    if (MapsConfig.hasKey && allPoints.length >= 2) {
      googleLegs = await GoogleDirectionsService.getLegsKm(allPoints);
      if (googleLegs != null) usedGoogle = true;
    }

    // Leg distances: index 0 = first stop (no previous = 0),
    // index i = distance from gpsStop[i-1] to gpsStop[i].
    final distances = <double>[];
    for (int i = 0; i < gpsStops.length; i++) {
      if (i == 0) {
        distances.add(0);
        continue;
      }
      if (googleLegs != null && (i - 1) < googleLegs.length) {
        distances.add(googleLegs[i - 1]);
      } else {
        final prev = allPoints[i - 1];
        final cur = allPoints[i];
        distances.add(_haversineKm(prev.lat, prev.lng, cur.lat, cur.lng));
      }
    }

    // Return leg — last stop back to end (use same last leg if available).
    double returnKm = 0;
    if (gpsStops.length >= 2 && googleLegs != null &&
        googleLegs.length >= gpsStops.length - 1) {
      returnKm = googleLegs[gpsStops.length - 2];
    }

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
