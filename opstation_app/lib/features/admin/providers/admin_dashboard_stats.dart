import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  final closedToday = await salesRepo.tripsClosedOnLocalDate(now);
  final activeTrips = <Trip>[];
  for (final u in orgUsers) {
    final t = await salesRepo.activeTripForUser(u.id);
    if (t != null) activeTrips.add(t);
  }

  final shops = <String>{};
  int totalAmount = 0;
  for (final t in [...closedToday, ...activeTrips]) {
    for (final v in t.visits) {
      totalAmount += v.amount;
      if (v.amount > 0) shops.add(v.customerId);
    }
  }

  final customers = await customerRepo.all(includeInactive: false);
  final routes = await salesRepo.allRoutes();

  return AdminDashboardStats(
    activeRoutesToday: activeTrips.length,
    shopsToday: shops.length,
    amountToday: totalAmount,
    teamCount: orgUsers.length,
    customerCount: customers.length,
    totalRoutes: routes.length,
    driverCount: driverCount,
  );
});
