import 'package:supabase_flutter/supabase_flutter.dart';

/// The organisation's drivers. Their work is not a salesperson's route, so the Reports page and the
/// "active routes" counts and lists leave them out (the dashboard's Active Drivers tile shows them).
Future<Set<String>> loadDriverIds(String orgId) async {
  final rows = await Supabase.instance.client.from('users').select('id').eq('org_id', orgId).eq('role', 'driver');
  return {for (final r in rows) '${r['id']}'};
}

/// [rows] without the ones made by the given users (a trip's `user_id`).
List<Map<String, dynamic>> withoutUsers(Iterable<Map<String, dynamic>> rows, Set<String> userIds, {String key = 'user_id'}) =>
    userIds.isEmpty ? rows.toList() : [for (final r in rows) if (!userIds.contains('${r[key]}')) r];

/// The routes counted as active on the dashboard: the figure the server gave, less the drivers' active
/// trips (never below 0). A figure that is not known stays unknown.
int? activeRoutesWithoutDrivers(int? reported, int driverActiveTrips) =>
    reported == null ? null : (reported - driverActiveTrips < 0 ? 0 : reported - driverActiveTrips);
