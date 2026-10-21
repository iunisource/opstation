import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database_provider.dart';
import '../../../core/supabase/supabase_pull_service.dart';
import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../../customers/data/customer_repository.dart';
import '../../salesperson/data/salesperson_repository.dart';
import '../../salesperson/models/trip.dart';

class AdminDashboardStats {
  final int activeRoutesToday;
  final int shopsToday;
  final int amountToday;
  final int teamCount;
  final int customerCount;
  final int totalRoutes;
  final int driverCount;
  /// Routes run on the selected day (shown instead of "active" for past days).
  final int routesOnDay;

  const AdminDashboardStats({
    required this.activeRoutesToday,
    required this.shopsToday,
    required this.amountToday,
    required this.teamCount,
    required this.customerCount,
    required this.totalRoutes,
    required this.driverCount,
    this.routesOnDay = 0,
  });
}

/// The day the dashboard banner shows (midnight, local). Arrows on the banner
/// move it back and forward, like the web dashboard.
final dashboardDayProvider = StateProvider<DateTime>((ref) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
});

final adminDashboardStatsProvider =
    FutureProvider<AdminDashboardStats>((ref) async {
  final customerRepo = ref.watch(customerRepositoryProvider);
  final salesRepo = ref.watch(salespersonRepositoryProvider);
  final orgId = ref.watch(orgIdProvider);
  final db = ref.watch(appDatabaseProvider);
  final selDay = ref.watch(dashboardDayProvider);

  // Server first — the same figures the web shows, scoped to the org on the
  // server, so nothing depends on what is stored on this phone.
  if (orgId != null) {
    try {
      final from = selDay.toUtc().toIso8601String();
      final to = selDay.add(const Duration(days: 1)).toUtc().toIso8601String();
      final r = await Supabase.instance.client.rpc('field_dashboard_day',
          params: {'p_org': orgId, 'p_from': from, 'p_to': to});
      if (r is Map) {
        int n(Object? v) => (v as num?)?.round() ?? 0;
        final customers = await customerRepo.all(includeInactive: false);
        final routes = await salesRepo.allRoutes();
        // Heal the phone's user list in the background (Team, Live, etc.).
        ref.read(supabasePullServiceProvider).refreshOrgUsers(orgId);
        return AdminDashboardStats(
          activeRoutesToday: n(r['active_routes']),
          routesOnDay: n(r['routes_on_day']),
          shopsToday: n(r['shops']),
          amountToday: n(r['amount']),
          teamCount: n(r['team']),
          customerCount: customers.length,
          totalRoutes: routes.length,
          driverCount: n(r['drivers']),
        );
      }
    } catch (_) {
      // Not deployed yet / offline → the older path below.
    }
  }

  // Keep the phone's user list current first — every figure below starts from
  // it, and a missing list made the whole banner read zero.
  if (orgId != null) {
    await ref.read(supabasePullServiceProvider).refreshOrgUsers(orgId);
  }
  final allUsersRaw = await db.select(db.users).get();
  final orgUsers = allUsersRaw.where((u) {
    if (!u.isActive) return false;
    if (u.role == UserRole.superAdmin.name) return false;
    if (u.role == 'retailer') return false; // retailer-app logins aren't team

    if (orgId != null && u.orgId != orgId) return false;
    return true;
  }).toList();

  final driverCount =
      orgUsers.where((u) => u.role == UserRole.driver.name).length;

  final now = selDay;
  final todayStart = DateTime(now.year, now.month, now.day);
  final tomorrowStart = todayStart.add(const Duration(days: 1));

  // Collection numbers must match the web dashboard and the leaderboard exactly.
  // The web dashboard reads Supabase LIVE; this screen historically read the
  // phone's LOCAL Drift DB, which only holds trips/visits already synced DOWN to
  // this device — so an admin's phone that hasn't pulled every rep's latest
  // collections showed a number BELOW the true total. No bucketing logic can fix
  // reading incomplete local data. So we read the same source the web does:
  // sum today's visit amounts straight from Supabase, by each visit's own
  // timestamp (Karachi day). Falls back to local Drift when offline.
  int totalAmount = 0;
  final shops = <String>{};
  int activeRoutesCount = 0;

  // This org's user IDs. `visits` has no org_id column, so RLS cannot scope it
  // by org — scoping MUST be done explicitly or every org's data leaks in.
  // orgUsers is already filtered to this org above, so its ids are the org
  // boundary for both visits and trips (both carry user_id).
  final orgUserIds = orgUsers.map((u) => u.id).toList();

  try {
    final client = Supabase.instance.client;
    final todayStartUtc = todayStart.toUtc().toIso8601String();
    final tomorrowStartUtc = tomorrowStart.toUtc().toIso8601String();

    // Today's visits for THIS org. `visits` has no org_id, so they are reached
    // through the org's trips (trips carry org_id). This replaced a filter on
    // every org user's id: with retailer logins in the users table that id
    // list grew past what a request URL can carry, the query failed, and the
    // banner fell back to the phone's local data — showing zero.
    final List<Map<String, dynamic>> visitRows = [];
    if (orgId != null) {
      final since = todayStart.subtract(const Duration(days: 2)).toUtc().toIso8601String();
      final tripRows = await client.from('trips').select('id')
          .eq('org_id', orgId)
          .or('ended_at.is.null,started_at.gte.$since');
      final tripIds = [for (final r in (tripRows as List)) '${(r as Map)['id']}'];
      for (var i = 0; i < tripIds.length; i += 40) {
        final batch = tripIds.sublist(i, i + 40 > tripIds.length ? tripIds.length : i + 40);
        final v = await client.from('visits').select('amount, customer_id')
            .inFilter('trip_id', batch)
            .gte('timestamp', todayStartUtc)
            .lt('timestamp', tomorrowStartUtc);
        for (final r in (v as List)) { visitRows.add(Map<String, dynamic>.from(r as Map)); }
      }
    } else {
      if (orgUserIds.isEmpty) throw StateError('no org users');
      for (var i = 0; i < orgUserIds.length; i += 40) {
        final batch = orgUserIds.sublist(i, i + 40 > orgUserIds.length ? orgUserIds.length : i + 40);
        final v = await client.from('visits').select('amount, customer_id')
            .inFilter('user_id', batch)
            .gte('timestamp', todayStartUtc)
            .lt('timestamp', tomorrowStartUtc);
        for (final r in (v as List)) { visitRows.add(Map<String, dynamic>.from(r as Map)); }
      }
    }
    for (final m in visitRows) {
      final amt = (m['amount'] as num?)?.round() ?? 0;
      totalAmount += amt;
      if (amt > 0) {
        final cid = m['customer_id'] as String?;
        if (cid != null) shops.add(cid);
      }
    }

    var activeQ = client.from('trips').select('id').filter('ended_at', 'is', null);
    activeQ = orgId != null ? activeQ.eq('org_id', orgId) : activeQ.inFilter('user_id', orgUserIds);
    final activeRows = await activeQ;
    activeRoutesCount = (activeRows as List).length;
  } catch (_) {
    // Offline (or Supabase unreachable): fall back to local Drift. This may lag
    // until the device syncs, but keeps the dashboard functional without a
    // network. Same per-visit-timestamp rule so the basis is consistent.
    final closedToday = await salesRepo.tripsClosedOnLocalDate(now);
    final activeTrips = <Trip>[];
    for (final u in orgUsers) {
      final t = await salesRepo.activeTripForUser(u.id);
      if (t != null) activeTrips.add(t);
    }
    for (final t in [...closedToday, ...activeTrips]) {
      for (final v in t.visits) {
        if (v.timestamp.isBefore(todayStart) ||
            !v.timestamp.isBefore(tomorrowStart)) {
          continue;
        }
        totalAmount += v.amount;
        if (v.amount > 0) shops.add(v.customerId);
      }
    }
    activeRoutesCount = activeTrips.length;
  }

  final customers = await customerRepo.all(includeInactive: false);
  final routes = await salesRepo.allRoutes();

  return AdminDashboardStats(
    activeRoutesToday: activeRoutesCount,
    shopsToday: shops.length,
    amountToday: totalAmount,
    teamCount: orgUsers.length,
    customerCount: customers.length,
    totalRoutes: routes.length,
    driverCount: driverCount,
  );
});
