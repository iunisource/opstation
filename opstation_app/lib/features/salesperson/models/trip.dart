import 'customer.dart';
import 'sales_route.dart';

/// Outcome of visiting a customer during a trip.
enum VisitStatus {
  /// GPS inside geofence — green check.
  verified,

  /// GPS outside geofence — amber warning, distance shown.
  outside,

  /// Customer has no stored location at all.
  noLocation,

  /// User explicitly skipped this stop with a reason.
  skipped,

  /// Not yet visited.
  pending,
}

extension VisitStatusX on VisitStatus {
  String get label {
    switch (this) {
      case VisitStatus.verified:
        return 'Verified';
      case VisitStatus.outside:
        return 'Outside';
      case VisitStatus.noLocation:
        return 'No location';
      case VisitStatus.skipped:
        return 'Skipped';
      case VisitStatus.pending:
        return 'Pending';
    }
  }
}

/// One visit record against one customer inside one trip.
class Visit {
  final String id;
  final String customerId;
  final VisitStatus status;
  final DateTime timestamp;

  /// GPS of the visit mark (null when [VisitStatus.noLocation]).
  final double? capturedLat;
  final double? capturedLng;

  /// GPS accuracy in metres (e.g. ±15).
  final double? accuracyMeters;

  /// Distance from the customer's stored location, in metres.
  /// Null for [VisitStatus.noLocation].
  final double? distanceMeters;

  /// Collected amount in org currency (Rs).
  final int amount;

  /// Receipt / CR number; required when [amount] > 0.
  final String? receiptNumber;

  /// Free-text notes or skip reason.
  final String? notes;

  /// Optional photo paths (mock for now — paths not actually stored to disk).
  final List<String> photoPaths;

  /// Only populated when [status] == [VisitStatus.skipped].
  final String? skipReason;

  /// Who recorded the visit (denormalized from trip/actor).
  final String userId;
  final String userName;
  final String userRole;

  const Visit({
    required this.id,
    required this.customerId,
    required this.status,
    required this.timestamp,
    this.capturedLat,
    this.capturedLng,
    this.accuracyMeters,
    this.distanceMeters,
    this.amount = 0,
    this.receiptNumber,
    this.notes,
    this.photoPaths = const [],
    this.skipReason,
    this.userId = '',
    this.userName = '',
    this.userRole = '',
  });

  /// Whether a revisit is allowed after this visit.
  /// Rule: revisit only if amount was zero (see requirements).
  bool get allowsRevisit => amount == 0 && status != VisitStatus.skipped;
}

/// A trip is one execution of a route by a salesperson.
///
/// Invariants:
///   - Snapshots the route's stop list at start time (edits to the route
///     later don't rewrite history).
///   - Holds the chronological list of visits performed this trip.
///   - Closes with a reason (user-ended or cut-off).
enum TripCloseReason { userEnded, cutoff }

class Trip {
  final String id;
  final String routeId;
  final String routeName;
  final RouteKind routeKind;
  final List<Customer> stopSnapshot;
  final DateTime startedAt;
  final DateTime? endedAt;
  final TripCloseReason? closeReason;
  final List<Visit> visits;

  /// Captured when the trip is started.
  final double? startLat;
  final double? startLng;

  /// Captured when the trip is completed (the "return to end location" leg).
  final double? endLat;
  final double? endLng;

  /// Who ran the trip (denormalized from actor at trip-start time).
  final String userId;
  final String userName;
  final String userRole;

  const Trip({
    required this.id,
    required this.routeId,
    required this.routeName,
    required this.routeKind,
    required this.stopSnapshot,
    required this.startedAt,
    this.endedAt,
    this.closeReason,
    this.visits = const [],
    this.startLat,
    this.startLng,
    this.endLat,
    this.endLng,
    this.userId = '',
    this.userName = '',
    this.userRole = '',
  });

  bool get isOpen => endedAt == null;
  bool get isClosed => !isOpen;

  int get totalStops => stopSnapshot.length;

  /// For each customer on the route, the *final* status for this trip
  /// (the last non-skipped visit wins; if only skip(s) exist → skipped;
  /// if no visits → pending). Revisits collapse to one entry per customer.
  Map<String, VisitStatus> get statusByCustomer {
    final result = <String, VisitStatus>{};
    for (final c in stopSnapshot) {
      result[c.id] = VisitStatus.pending;
    }
    for (final v in visits) {
      if (!result.containsKey(v.customerId)) continue;
      // A real visit always overwrites a prior skip/pending. A later skip
      // never demotes a real visit.
      final current = result[v.customerId]!;
      if (v.status == VisitStatus.skipped &&
          current != VisitStatus.pending &&
          current != VisitStatus.skipped) {
        continue;
      }
      result[v.customerId] = v.status;
    }
    return result;
  }

  int _countWhere(bool Function(VisitStatus) test) =>
      statusByCustomer.values.where(test).length;

  int get verifiedCount => _countWhere((s) => s == VisitStatus.verified);
  int get outsideCount => _countWhere((s) => s == VisitStatus.outside);
  int get skippedCount => _countWhere((s) => s == VisitStatus.skipped);
  int get noLocationCount => _countWhere((s) => s == VisitStatus.noLocation);

  /// Visits that happened but couldn't be GPS-validated.
  /// Sum of `outside` (GPS outside geofence) + `noLocation` (customer
  /// had no stored coords or device GPS was off). Used in admin views
  /// alongside `verifiedCount` to give a full picture of field activity.
  int get unverifiedCount => outsideCount + noLocationCount;

  /// Pending = customers on the route that still accept a visit.
  /// A customer is NOT pending if they've been skipped or had a visit
  /// with amount > 0 (revisit no longer allowed).
  int get pendingCount {
    int n = 0;
    for (final c in stopSnapshot) {
      final latest = _latestForCustomer(c.id);
      if (latest == null) {
        n++;
      } else if (latest.status != VisitStatus.skipped && latest.allowsRevisit) {
        n++;
      }
    }
    return n;
  }

  Visit? _latestForCustomer(String customerId) {
    Visit? latest;
    for (final v in visits) {
      if (v.customerId == customerId) latest = v;
    }
    return latest;
  }

  /// Visited = unique customers with at least one real (non-skipped) visit.
  /// Includes verified + outside + noLocation. Used in salesperson-facing
  /// "you visited X/N customers" displays.
  ///
  /// For admin/quality scoring use [verifiedCount] instead — that metric
  /// strictly counts geofence-validated visits.
  int get visitedCount =>
      _countWhere((s) => s != VisitStatus.pending && s != VisitStatus.skipped);

  /// Strict completion percent: how many stops were geofence-verified.
  /// Used for admin-facing visit-quality scoring (leaderboard, monitoring).
  /// For salesperson-facing "did you visit your customers" display, use
  /// [coveragePercent] — it counts any real visit (verified + unverified).
  double get completionPercent =>
      totalStops == 0 ? 0 : (verifiedCount / totalStops) * 100;

  /// Permissive coverage percent: how many stops had any real visit
  /// (verified, outside, or noLocation). Used in salesperson-facing UI
  /// where the message is "you reached X% of your customers."
  double get coveragePercent =>
      totalStops == 0 ? 0 : (visitedCount / totalStops) * 100;

  int get totalCollected => visits.fold(0, (sum, v) => sum + v.amount);

  Trip copyWith({
    DateTime? endedAt,
    TripCloseReason? closeReason,
    List<Visit>? visits,
    double? endLat,
    double? endLng,
  }) {
    return Trip(
      id: id,
      routeId: routeId,
      routeName: routeName,
      routeKind: routeKind,
      stopSnapshot: stopSnapshot,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      closeReason: closeReason ?? this.closeReason,
      visits: visits ?? this.visits,
      startLat: startLat,
      startLng: startLng,
      endLat: endLat ?? this.endLat,
      endLng: endLng ?? this.endLng,
      userId: userId,
      userName: userName,
      userRole: userRole,
    );
  }
}