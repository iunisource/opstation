import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/maps_config.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/services/google_directions_service.dart';
import '../../salesperson/models/trip.dart';
import 'nominatim_client.dart';

/// Name/code for a visited customer that isn't in the trip's route snapshot.
class ReportCustomerRef {
  final String code;
  final String name;
  const ReportCustomerRef({required this.code, required this.name});
}

/// Pre-computed data for a trip report: addresses, leg distances, totals.
class TripReportContext {
  final Trip trip;
  final String? startAddress;
  final String? endAddress;

  /// Customers that were visited but are NOT in `trip.stopSnapshot`, looked up
  /// from the local customers table. The PDF resolves names from the route
  /// snapshot, which only holds the stops planned when the trip started — so a
  /// visit outside the planned route, or a snapshot that synced incompletely
  /// onto an admin's device, rendered as a blank dash. This is the fallback.
  final Map<String, ReportCustomerRef> extraCustomers;

  /// Verified visits in timestamp order.
  final List<Visit> orderedVerifiedVisits;

  /// Road distance in km for each leg:
  ///   start→visit[0], visit[0]→visit[1], …
  /// Google Directions when available, Haversine fallback otherwise.
  final List<double> distanceKm;

  final double returnDistanceKm;
  final double totalDistanceKm;

  /// True = Google Directions provided distances. False = all Haversine.
  final bool usedGoogle;

  /// Kept for backward-compat with PDF footer note.
  bool get usedOsrm => false;

  const TripReportContext({
    required this.trip,
    required this.startAddress,
    this.extraCustomers = const {},
    required this.endAddress,
    required this.orderedVerifiedVisits,
    required this.distanceKm,
    required this.returnDistanceKm,
    required this.totalDistanceKm,
    required this.usedGoogle,
  });
}

class ReportContextBuilder {
  final Ref _ref;
  ReportContextBuilder(this._ref);

  Future<TripReportContext> build(Trip trip) async {
    final nomi = _ref.read(nominatimClientProvider);

    // 0. Resolve customers that were visited but aren't in the route snapshot.
    //    Without this the PDF prints a dash for them — which is what produced
    //    reports where most of the customer column was blank.
    final snapshotIds = trip.stopSnapshot.map((c) => c.id).toSet();
    final missingIds = <String>{
      for (final v in trip.visits)
        if (!snapshotIds.contains(v.customerId)) v.customerId,
    };
    final extras = <String, ReportCustomerRef>{};
    if (missingIds.isNotEmpty) {
      try {
        final db = _ref.read(appDatabaseProvider);
        final rows = await (db.select(db.customers)
              ..where((c) => c.id.isIn(missingIds.toList())))
            .get();
        for (final r in rows) {
          extras[r.id] = ReportCustomerRef(code: r.code, name: r.shopName);
        }
      } catch (_) {
        // Best-effort: an empty map just means we fall back to the code.
      }
    }

    // 1. Addresses — parallelised, best-effort.
    String? startAddr;
    String? endAddr;
    await Future.wait([
      if (trip.startLat != null && trip.startLng != null)
        () async {
          startAddr =
              await nomi.reverseGeocode(trip.startLat!, trip.startLng!);
        }(),
      if (trip.endLat != null && trip.endLng != null)
        () async {
          endAddr = await nomi.reverseGeocode(trip.endLat!, trip.endLng!);
        }(),
    ]);

    // 2. Ordered verified visits with GPS.
    final ordered = [
      for (final v in trip.visits)
        if (v.status == VisitStatus.verified &&
            v.capturedLat != null &&
            v.capturedLng != null)
          v,
    ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // 3. Full point sequence for Google: [start?, visit0..N, end?]
    final hasStart = trip.startLat != null && trip.startLng != null;
    final hasEnd = trip.endLat != null && trip.endLng != null;

    final allPoints = <DirectionsPoint>[
      if (hasStart) DirectionsPoint(trip.startLat!, trip.startLng!),
      for (final v in ordered) DirectionsPoint(v.capturedLat!, v.capturedLng!),
      if (hasEnd) DirectionsPoint(trip.endLat!, trip.endLng!),
    ];

    // 4. Try Google Directions (single call for all legs).
    bool usedGoogle = false;
    List<double>? googleLegs;
    if (MapsConfig.hasKey && allPoints.length >= 2) {
      googleLegs = await GoogleDirectionsService.getLegsKm(allPoints);
      if (googleLegs != null) usedGoogle = true;
    }

    // 5. Map leg distances to ordered visits.
    // allPoints[0] = start (if hasStart), then visits, then end (if hasEnd).
    // googleLegs[i] = distance from allPoints[i] to allPoints[i+1].
    final startOffset = hasStart ? 1 : 0;
    final distances = <double>[];

    for (int i = 0; i < ordered.length; i++) {
      final allIdx = startOffset + i;
      final prevIdx = allIdx - 1;
      if (prevIdx < 0) {
        distances.add(0);
        continue;
      }
      if (googleLegs != null && prevIdx < googleLegs.length) {
        distances.add(googleLegs[prevIdx]);
      } else {
        final prev = allPoints[prevIdx];
        final cur = allPoints[allIdx];
        distances.add(_haversineKm(prev.lat, prev.lng, cur.lat, cur.lng));
      }
    }

    // 6. Return leg: last visit → trip end.
    double returnKm = 0;
    if (hasEnd && allPoints.length >= 2) {
      final returnLegIdx = allPoints.length - 2;
      if (googleLegs != null && returnLegIdx < googleLegs.length) {
        returnKm = googleLegs[returnLegIdx];
      } else if (ordered.isNotEmpty) {
        final last = ordered.last;
        returnKm = _haversineKm(
            last.capturedLat!, last.capturedLng!,
            trip.endLat!, trip.endLng!);
      }
    }

    final total = distances.fold<double>(0, (s, d) => s + d) + returnKm;

    return TripReportContext(
      trip: trip,
      extraCustomers: extras,
      startAddress: startAddr,
      endAddress: endAddr,
      orderedVerifiedVisits: ordered,
      distanceKm: distances,
      returnDistanceKm: returnKm,
      totalDistanceKm: total,
      usedGoogle: usedGoogle,
    );
  }

  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const earthKm = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = (sin(dLat / 2) * sin(dLat / 2)) +
        cos(_rad(lat1)) * cos(_rad(lat2)) *
            (sin(dLng / 2) * sin(dLng / 2));
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthKm * c;
  }

  double _rad(double deg) => deg * (pi / 180.0);
}

final reportContextBuilderProvider =
    Provider<ReportContextBuilder>((ref) => ReportContextBuilder(ref));
