import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database_provider.dart';
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

  const AdminDashboardStats({
    required this.activeRoutesToday,
    required this.shopsToday,
    required this.amountToday,
    required this.teamCount,
    required this.customerCount,
    required this.totalRoutes,
    required this.driverCount,
  });
}

final adminDashboardStatsProvider =
    FutureProvider<AdminDashboardStats>((ref) async {
  final customerRepo = ref.watch(customerRepositoryProvider);
  final salesRepo = ref.watch(salespersonRepositoryProvider);
  final orgId = ref.watch(orgIdProvider);
  final db = ref.watch(appDatabaseProvider);

  final allUsersRaw = await db.select(db.users).get();
  final orgUsers = allUsersRaw.where((u) {
    if (!u.isActive) return false;
    if (u.role == UserRole.superAdmin.name) return false;
    if (orgId != null && u.orgId != orgId) return false;
    return true;
  }).toList();

  final driverCount =
      orgUsers.where((u) => u.role == UserRole.driver.name).length;

  final now = DateTime.now();
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

  try {
    final client = Supabase.instance.client;
    final todayStartUtc = todayStart.toUtc().toIso8601String();
    final tomorrowStartUtc = tomorrowStart.toUtc().toIso8601String();

    // RLS scopes these to the signed-in admin's org, same as the web dashboard.
    final visitRows = await client
        .from('visits')
        .select('amount, customer_id')
        .gte('timestamp', todayStartUtc)
        .lt('timestamp', tomorrowStartUtc);
    for (final r in (visitRows as List)) {
      final m = Map<String, dynamic>.from(r as Map);
      final amt = (m['amount'] as int?) ?? 0;
      totalAmount += amt;
      if (amt > 0) {
        final cid = m['customer_id'] as String?;
        if (cid != null) shops.add(cid);
      }
    }

    final activeRows = await client
        .from('trips')
        .select('id')
        .filter('ended_at', 'is', null);
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
