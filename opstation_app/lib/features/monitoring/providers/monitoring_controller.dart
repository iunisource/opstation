import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/models/user_role.dart';
import '../../salesperson/data/salesperson_repository.dart';
import '../../salesperson/models/trip.dart';
import '../../team/data/team_repository.dart';
import '../../team/models/team_user.dart';

/// Summary per salesperson for today's live view.
class LiveSalespersonSummary {
  final TeamUser user;

  /// Currently-active trip, or null if they're not out.
  final Trip? active;

  /// Trips this user closed today.
  final List<Trip> completedToday;

  const LiveSalespersonSummary({
    required this.user,
    required this.active,
    required this.completedToday,
  });

  bool get isOnRoute => active != null;

  int get todayVerifiedVisits {
    int n = 0;
    if (active != null) n += active!.verifiedCount;
    for (final t in completedToday) {
      n += t.verifiedCount;
    }
    return n;
  }

  int get todayCollected {
    int n = 0;
    if (active != null) n += active!.totalCollected;
    for (final t in completedToday) {
      n += t.totalCollected;
    }
    return n;
  }

  /// Last visit timestamp across active + completed today, or null if none.
  DateTime? get lastActivity {
    DateTime? latest;
    void consider(Trip t) {
      for (final v in t.visits) {
        if (latest == null || v.timestamp.isAfter(latest!)) {
          latest = v.timestamp;
        }
      }
      if (t.endedAt != null &&
          (latest == null || t.endedAt!.isAfter(latest!))) {
        latest = t.endedAt;
      }
    }

    if (active != null) consider(active!);
    for (final t in completedToday) {
      consider(t);
    }
    return latest;
  }
}

/// Leaderboard period selector.
enum LeaderboardPeriod { today, week, month }

/// Single-row performance metrics for leaderboard.
///
/// Display contract for admin views:
/// - "X verified" chip uses [verifiedVisits] (geofence-confirmed)
/// - "Y unverified" chip uses [unverifiedVisits] (outside + noLocation)
/// - "Rs Z" uses [collected] (sum of all visit amounts)
/// - Score % uses [visitScore] = verifiedVisits / totalStops
class LeaderboardEntry {
  final TeamUser user;

  /// Unique customers across all trips in the period (the denominator).
  final int totalStops;

  /// Unique customers with at least one non-skipped visit. Kept for
  /// reference/sorting; not displayed in admin chips after the May 2026
  /// refactor — admins now see verified vs unverified separately.
  final int visited;

  /// Count of GPS-verified visits (status == verified).
  final int verifiedVisits;

  /// Count of visits that happened but couldn't be GPS-validated:
  /// outside-geofence + no-location-available.
  final int unverifiedVisits;

  /// Sum of visit amounts in Rs.
  final int collected;

  const LeaderboardEntry({
    required this.user,
    required this.totalStops,
    required this.visited,
    required this.verifiedVisits,
    required this.unverifiedVisits,
    required this.collected,
  });

  /// Strict quality score: percent of route stops that were geofence-
  /// verified. A salesperson who visited every customer but had bad GPS
  /// scores 0% here — that's intentional. Salesperson-facing UIs should
  /// use Trip.coveragePercent instead, which is the permissive measure.
  double get visitScore {
    if (totalStops == 0) return 0;
    return (verifiedVisits / totalStops) * 100;
  }
}

/// Watches active + today's trips across the org.
final liveMonitoringProvider =
    FutureProvider.autoDispose<List<LiveSalespersonSummary>>((ref) async {
  final teamRepo = ref.watch(teamRepositoryProvider);
  final salesRepo = ref.watch(salespersonRepositoryProvider);

  final users = (await teamRepo.all(includeInactive: false))
      .where((u) => u.role == UserRole.salesperson)
      .toList();

  final today = DateTime.now();
  final result = <LiveSalespersonSummary>[];
  for (final u in users) {
    final active = await salesRepo.activeTripForUser(u.id);
    final completed =
        await salesRepo.tripsClosedOnLocalDateForUser(today, u.id);
    result.add(LiveSalespersonSummary(
      user: u,
      active: active,
      completedToday: completed,
    ));
  }

  // Sort: on-route first, then by most recent activity, then by name.
  result.sort((a, b) {
    if (a.isOnRoute != b.isOnRoute) {
      return a.isOnRoute ? -1 : 1;
    }
    final la = a.lastActivity;
    final lb = b.lastActivity;
    if (la != null && lb != null) return lb.compareTo(la);
    if (la != null) return -1;
    if (lb != null) return 1;
    return a.user.name.compareTo(b.user.name);
  });

  return result;
});

/// Leaderboard for the given period, computed from trip history.
final leaderboardProvider = FutureProvider.autoDispose
    .family<List<LeaderboardEntry>, LeaderboardPeriod>((ref, period) async {
  final teamRepo = ref.watch(teamRepositoryProvider);
  final salesRepo = ref.watch(salespersonRepositoryProvider);

  final users = (await teamRepo.all(includeInactive: false))
      .where((u) => u.role == UserRole.salesperson)
      .toList();

  final now = DateTime.now();
  late DateTime rangeStart;
  switch (period) {
    case LeaderboardPeriod.today:
      rangeStart = DateTime(now.year, now.month, now.day);
      break;
    case LeaderboardPeriod.week:
      // Calendar week starting Monday → today (inclusive).
      // weekday: Mon=1 ... Sun=7, so subtract (weekday - 1) days.
      final daysSinceMonday = now.weekday - 1;
      rangeStart = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: daysSinceMonday));
      break;
    case LeaderboardPeriod.month:
      rangeStart = DateTime(now.year, now.month, 1);
      break;
  }

  final result = <LeaderboardEntry>[];
  for (final u in users) {
    final trips =
        await salesRepo.tripsInRangeForUser(rangeStart, now, u.id);
    // Also include currently-active trip — its visits count for today.
    final active = await salesRepo.activeTripForUser(u.id);
    final allTrips = [...trips, if (active != null) active];

    final uniqueStops = <String>{};
    final visitedSet = <String>{};
    int verified = 0;
    int unverified = 0;
    int collected = 0;

    for (final t in allTrips) {
      for (final c in t.stopSnapshot) {
        uniqueStops.add(c.id);
      }
      for (final v in t.visits) {
        if (v.status == VisitStatus.verified) {
          visitedSet.add(v.customerId);
          verified++;
        } else if (v.status == VisitStatus.outside ||
            v.status == VisitStatus.noLocation) {
          visitedSet.add(v.customerId);
          unverified++;
        }
        // Skipped and pending visits don't count toward visited or
        // either count, but their `amount` (if any) still counts toward
        // collected — preserves the prior behavior.
        //
        // Collection is bucketed by the visit's OWN timestamp within the
        // period, matching the web + admin dashboards (canonical rule: sum of
        // visit amounts whose timestamp falls in [rangeStart, now], Karachi
        // day). Without this filter an active trip that began before the
        // period start dragged its earlier-day collections into the total,
        // which is why the leaderboard disagreed with the dashboards. No
        // today-collection is lost: any visit timestamped in-period belongs to
        // a trip that either started in-period or is still active — both are in
        // allTrips.
        if (!v.timestamp.isBefore(rangeStart) && !v.timestamp.isAfter(now)) {
          collected += v.amount;
        }
      }
    }

    result.add(LeaderboardEntry(
      user: u,
      totalStops: uniqueStops.length,
      visited: visitedSet.length,
      verifiedVisits: verified,
      unverifiedVisits: unverified,
      collected: collected,
    ));
  }

  // Sort by visit score desc, then by verified count desc, then by
  // collected desc — so a verified-tied row goes to whoever collected more.
  result.sort((a, b) {
    final cmp = b.visitScore.compareTo(a.visitScore);
    if (cmp != 0) return cmp;
    final v = b.verifiedVisits.compareTo(a.verifiedVisits);
    if (v != 0) return v;
    return b.collected.compareTo(a.collected);
  });

  return result;
});