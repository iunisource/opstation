import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin_settings/providers/org_settings_controller.dart';
import '../../auth/models/user_role.dart';
import '../../salesperson/data/salesperson_repository.dart';
import '../../salesperson/models/customer.dart';
import '../../salesperson/models/trip.dart';
import '../../team/data/team_repository.dart';
import '../models/anomaly.dart';

/// Runs anomaly detection across a salesperson's recent trips.
///
/// Detection window = "the most recent N trips this salesperson has
/// run, across all routes" where N comes from org settings
/// (complianceLookbackTrips). Inside those N trips, for each (customer)
/// pair that appears on at least one stop snapshot, we count how many
/// trips produced the pattern. If the count reaches the threshold
/// (complianceThresholdOccurrences, default 2), the flag fires.
class ComplianceDetector {
  final Ref _ref;
  ComplianceDetector(this._ref);

  /// Runs detection for a single salesperson. Returns their full
  /// compliance snapshot including a computed score.
  Future<SalespersonCompliance> forSalesperson(
    String userId,
    String userName,
  ) async {
    final settings = await _ref.read(orgSettingsProvider.future);
    final lookback = settings.complianceLookbackTrips;
    final threshold = settings.complianceThresholdOccurrences;
    final salesRepo = _ref.read(salespersonRepositoryProvider);

    // Pull *all* trips for this user (ordered newest-first), then take
    // the most recent `lookback`. Using the repository's existing
    // paginated accessor would be cleaner, but for now we use
    // tripsInRangeForUser with a far-enough-back start and slice.
    final now = DateTime.now();
    final far = DateTime(now.year - 5, 1, 1);
    final allTrips = await salesRepo.tripsInRangeForUser(far, now, userId);
    allTrips.sort((a, b) {
      final ae = a.endedAt ?? a.startedAt;
      final be = b.endedAt ?? b.startedAt;
      return be.compareTo(ae);
    });
    final trips = allTrips.take(lookback).toList();

    return _detect(userId, userName, trips, threshold);
  }

  /// Runs detection for every salesperson in the org. Returns them
  /// sorted by lowest score first (worst compliance at the top).
  Future<List<SalespersonCompliance>> forAllSalespersons() async {
    final teamRepo = _ref.read(scopedTeamRepositoryProvider);
    final users = await teamRepo.all(includeInactive: false);
    final out = <SalespersonCompliance>[];
    for (final u in users) {
      if (u.role != UserRole.salesperson) continue;
      out.add(await forSalesperson(u.id, u.name));
    }
    out.sort((a, b) {
      // Sort by score ascending (worst first). Within same score, more
      // flags first.
      final byScore = a.scorePercent.compareTo(b.scorePercent);
      if (byScore != 0) return byScore;
      return b.totalFlagCount.compareTo(a.totalFlagCount);
    });
    return out;
  }

  SalespersonCompliance _detect(
    String userId,
    String userName,
    List<Trip> trips,
    int threshold,
  ) {
    // Per-customer counters for each anomaly type. We also need to
    // know the 'latest' Customer object for each customerId since the
    // stop snapshot may diverge across trips (a customer's name can
    // change over time).
    final skipCount = <String, int>{};
    final zeroCrCount = <String, int>{};
    final noGpsCount = <String, int>{};
    final notVisitedCount = <String, int>{};

    final customerById = <String, Customer>{};
    final lastDetail = <_Key, String>{};

    // Tracks customers the salesperson serviced at all in the window.
    // For score denominator.
    final servicedCustomerIds = <String>{};

    for (final trip in trips) {
      final snapshotById = <String, Customer>{
        for (final c in trip.stopSnapshot) c.id: c,
      };
      for (final c in trip.stopSnapshot) {
        servicedCustomerIds.add(c.id);
        customerById.putIfAbsent(c.id, () => c);
      }

      // Latest status per customer for this trip (collapses multi-visit
      // same-customer events into one outcome).
      final statusByCustomer = trip.statusByCustomer;
      // Latest concrete visit record per customer for this trip, used
      // for 'zero CR' and 'no GPS' data.
      final latestVisitByCustomer = <String, Visit>{};
      for (final v in trip.visits) {
        final prev = latestVisitByCustomer[v.customerId];
        if (prev == null || v.timestamp.isAfter(prev.timestamp)) {
          latestVisitByCustomer[v.customerId] = v;
        }
      }

      for (final cid in snapshotById.keys) {
        final status = statusByCustomer[cid] ?? VisitStatus.pending;
        final v = latestVisitByCustomer[cid];
        final dateStr = _dateOf(trip);

        switch (status) {
          case VisitStatus.skipped:
            skipCount.update(cid, (x) => x + 1, ifAbsent: () => 1);
            lastDetail[_Key(AnomalyType.skipped, cid)] =
                'Last skipped $dateStr${(v?.skipReason ?? '').isEmpty ? '' : ' · ${v!.skipReason}'}';
            break;

          case VisitStatus.pending:
            // Customer was on the route but never marked. That's
            // "not visited" for anomaly purposes.
            notVisitedCount.update(cid, (x) => x + 1, ifAbsent: () => 1);
            lastDetail[_Key(AnomalyType.notVisited, cid)] =
                'Not marked on trip $dateStr';
            break;

          case VisitStatus.noLocation:
            noGpsCount.update(cid, (x) => x + 1, ifAbsent: () => 1);
            lastDetail[_Key(AnomalyType.noGps, cid)] =
                'No GPS captured $dateStr';
            break;

          case VisitStatus.verified:
          case VisitStatus.outside:
            // On-site. Check for zero collection.
            if (v != null && v.amount == 0) {
              zeroCrCount.update(cid, (x) => x + 1, ifAbsent: () => 1);
              lastDetail[_Key(AnomalyType.zeroCollection, cid)] =
                  'Rs 0 collected on $dateStr';
            }
            break;
        }
      }
    }

    // Assemble flags per type.
    List<AnomalyFlag> build(
      Map<String, int> counts,
      AnomalyType type,
    ) {
      final flags = <AnomalyFlag>[];
      for (final entry in counts.entries) {
        if (entry.value < threshold) continue;
        final c = customerById[entry.key];
        if (c == null) continue;
        flags.add(AnomalyFlag(
          type: type,
          customer: c,
          count: entry.value,
          detail: lastDetail[_Key(type, entry.key)] ?? '',
        ));
      }
      flags.sort((a, b) => b.count.compareTo(a.count));
      return flags;
    }

    final byType = <AnomalyType, List<AnomalyFlag>>{
      AnomalyType.skipped: build(skipCount, AnomalyType.skipped),
      AnomalyType.zeroCollection:
          build(zeroCrCount, AnomalyType.zeroCollection),
      AnomalyType.noGps: build(noGpsCount, AnomalyType.noGps),
      AnomalyType.notVisited: build(notVisitedCount, AnomalyType.notVisited),
    };

    // A customer counts as "flagged" if they appear in any type's list.
    final flaggedCustomerIds = <String>{};
    for (final list in byType.values) {
      for (final f in list) {
        flaggedCustomerIds.add(f.customer.id);
      }
    }

    return SalespersonCompliance(
      userId: userId,
      userName: userName,
      customersServiced: servicedCustomerIds.length,
      customersFlagged: flaggedCustomerIds.length,
      flagsByType: byType,
    );
  }

  String _dateOf(Trip t) {
    final d = t.endedAt ?? t.startedAt;
    return '${d.day}/${d.month}';
  }
}

/// Private composite key for the lastDetail lookup.
class _Key {
  final AnomalyType type;
  final String customerId;
  const _Key(this.type, this.customerId);

  @override
  bool operator ==(Object other) =>
      other is _Key && other.type == type && other.customerId == customerId;

  @override
  int get hashCode => Object.hash(type, customerId);
}

final complianceDetectorProvider = Provider<ComplianceDetector>(
    (ref) => ComplianceDetector(ref));
