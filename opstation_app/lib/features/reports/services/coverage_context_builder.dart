import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/models/user_role.dart';
import '../../salesperson/data/salesperson_repository.dart';
import '../../salesperson/models/customer.dart';
import '../../salesperson/models/sales_route.dart';
import '../../salesperson/models/trip.dart';
import '../../team/data/team_repository.dart';
import '../../team/models/team_user.dart';

/// Per-route aggregate for a period.
class RouteCoverage {
  final SalesRoute route;

  /// Number of distinct trips run against this route in the period.
  final int tripsRun;

  /// Unique customer IDs touched with a VERIFIED visit in the period.
  final Set<String> verifiedCustomerIds;

  /// Unique customer IDs touched with an OUTSIDE-GF visit.
  final Set<String> outsideCustomerIds;

  /// Unique customer IDs that were SKIPPED at least once and never
  /// upgraded to a real visit within the period.
  final Set<String> skippedCustomerIds;

  /// Customers on the route snapshot that were never touched at all.
  final List<Customer> unvisitedCustomers;

  /// Total Rs. collected across all visits in the period.
  final int totalCollected;

  /// Salesperson IDs that ran at least one trip on this route.
  final Set<String> salespersonIds;

  const RouteCoverage({
    required this.route,
    required this.tripsRun,
    required this.verifiedCustomerIds,
    required this.outsideCustomerIds,
    required this.skippedCustomerIds,
    required this.unvisitedCustomers,
    required this.totalCollected,
    required this.salespersonIds,
  });

  int get totalStops => route.stops.length;

  double get coveragePercent {
    if (totalStops == 0) return 0;
    return (verifiedCustomerIds.length / totalStops) * 100;
  }
}

/// Per-salesperson aggregate for a period.
class SalespersonCoverage {
  final TeamUser user;
  final int tripsRun;
  final int verifiedVisits;
  final int outsideVisits;
  final int skippedVisits;
  final int totalCollected;

  /// Unique customers visited (verified).
  final int uniqueCustomersVisited;

  const SalespersonCoverage({
    required this.user,
    required this.tripsRun,
    required this.verifiedVisits,
    required this.outsideVisits,
    required this.skippedVisits,
    required this.totalCollected,
    required this.uniqueCustomersVisited,
  });
}

/// Full context for a Coverage Report.
class CoverageReportContext {
  final DateTime from;
  final DateTime to;
  final List<RouteCoverage> routeCoverages;
  final List<SalespersonCoverage> salespersonCoverages;
  final int totalTrips;
  final int totalVerifiedVisits;
  final int totalCollected;
  final int totalUniqueCustomersVisited;
  final int totalRoutesAssessed;

  const CoverageReportContext({
    required this.from,
    required this.to,
    required this.routeCoverages,
    required this.salespersonCoverages,
    required this.totalTrips,
    required this.totalVerifiedVisits,
    required this.totalCollected,
    required this.totalUniqueCustomersVisited,
    required this.totalRoutesAssessed,
  });
}

class CoverageContextBuilder {
  final Ref _ref;
  CoverageContextBuilder(this._ref);

  Future<CoverageReportContext> build({
    required DateTime from,
    required DateTime to,
    String? routeIdFilter,
    String? userIdFilter,
  }) async {
    final teamRepo = _ref.read(teamRepositoryProvider);
    final salesRepo = _ref.read(salespersonRepositoryProvider);

    final users = await teamRepo.all(includeInactive: true);
    final allRoutes = await salesRepo.allRoutesIncludingInactive();

    // Pull trips for every salesperson in range.
    final salespersons = users
        .where((u) => u.role == UserRole.salesperson)
        .where((u) => userIdFilter == null || u.id == userIdFilter)
        .toList();

    final allTrips = <Trip>[];
    for (final u in salespersons) {
      final ts = await salesRepo.tripsInRangeForUser(from, to, u.id);
      allTrips.addAll(ts);
    }

    // Group trips by route.
    final tripsByRoute = <String, List<Trip>>{};
    for (final t in allTrips) {
      tripsByRoute.putIfAbsent(t.routeId, () => []).add(t);
    }

    // Route coverages.
    final routeCoverages = <RouteCoverage>[];
    for (final r in allRoutes) {
      if (routeIdFilter != null && r.id != routeIdFilter) continue;
      final trips = tripsByRoute[r.id] ?? const <Trip>[];
      if (trips.isEmpty && routeIdFilter == null) continue;

      final verified = <String>{};
      final outside = <String>{};
      final skipped = <String>{};
      final touched = <String>{};
      int collected = 0;
      final salespeople = <String>{};

      for (final t in trips) {
        salespeople.add(t.userId);
        collected += t.totalCollected;
        final byCustomer = t.statusByCustomer;
        for (final entry in byCustomer.entries) {
          switch (entry.value) {
            case VisitStatus.verified:
              verified.add(entry.key);
              touched.add(entry.key);
              break;
            case VisitStatus.outside:
              outside.add(entry.key);
              touched.add(entry.key);
              break;
            case VisitStatus.skipped:
              skipped.add(entry.key);
              touched.add(entry.key);
              break;
            case VisitStatus.noLocation:
              touched.add(entry.key);
              break;
            case VisitStatus.pending:
              break;
          }
        }
      }

      final unvisited = [
        for (final c in r.stops)
          if (!touched.contains(c.id)) c,
      ];

      routeCoverages.add(RouteCoverage(
        route: r,
        tripsRun: trips.length,
        verifiedCustomerIds: verified,
        outsideCustomerIds: outside,
        skippedCustomerIds: skipped.difference(verified),
        unvisitedCustomers: unvisited,
        totalCollected: collected,
        salespersonIds: salespeople,
      ));
    }

    routeCoverages.sort((a, b) => b.coveragePercent.compareTo(a.coveragePercent));

    // Salesperson coverages.
    final salespersonCoverages = <SalespersonCoverage>[];
    for (final u in salespersons) {
      final theirs = allTrips.where((t) => t.userId == u.id).toList();
      if (theirs.isEmpty && userIdFilter == null) continue;
      int verified = 0;
      int outside = 0;
      int skipped = 0;
      int collected = 0;
      final uniqueVerified = <String>{};
      for (final t in theirs) {
        verified += t.verifiedCount;
        outside += t.outsideCount;
        skipped += t.skippedCount;
        collected += t.totalCollected;
        for (final v in t.visits) {
          if (v.status == VisitStatus.verified) {
            uniqueVerified.add(v.customerId);
          }
        }
      }
      salespersonCoverages.add(SalespersonCoverage(
        user: u,
        tripsRun: theirs.length,
        verifiedVisits: verified,
        outsideVisits: outside,
        skippedVisits: skipped,
        totalCollected: collected,
        uniqueCustomersVisited: uniqueVerified.length,
      ));
    }
    salespersonCoverages.sort((a, b) =>
        b.uniqueCustomersVisited.compareTo(a.uniqueCustomersVisited));

    final totalUnique = <String>{};
    for (final rc in routeCoverages) {
      totalUnique.addAll(rc.verifiedCustomerIds);
    }

    return CoverageReportContext(
      from: from,
      to: to,
      routeCoverages: routeCoverages,
      salespersonCoverages: salespersonCoverages,
      totalTrips: allTrips.length,
      totalVerifiedVisits:
          salespersonCoverages.fold(0, (s, x) => s + x.verifiedVisits),
      totalCollected:
          salespersonCoverages.fold(0, (s, x) => s + x.totalCollected),
      totalUniqueCustomersVisited: totalUnique.length,
      totalRoutesAssessed: routeCoverages.length,
    );
  }
}

final coverageContextBuilderProvider = Provider<CoverageContextBuilder>(
    (ref) => CoverageContextBuilder(ref));
