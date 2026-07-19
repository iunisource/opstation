import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/supabase/supabase_sync_service.dart';
import '../../../core/database/app_database_provider.dart';
import '../../auth/providers/auth_controller.dart';
import '../models/customer.dart';
import '../models/sales_route.dart';
import '../models/trip.dart';

/// Maps the DB tables to domain models and back.
/// Keeps the UI and controllers decoupled from Drift-generated types.
class SalespersonRepository {
  final AppDatabase _db;
  final String? _orgId;
  SupabaseSyncService? _sync;
  SalespersonRepository(this._db, {String? orgId, SupabaseSyncService? sync})
      : _orgId = orgId,
        _sync = sync;

  // ---- Seed (first-run) -------------------------------------------------

  /// Populate customers and routes if the DB is empty. Idempotent.
  ///
  /// Checks both tables independently so a partial prior seed (e.g. customers
  /// inserted but route insert failed) self-heals on next launch.
  Future<void> seedIfEmpty() async {
    // Seed disabled — app is in production use.
    // Real data is created through the admin UI.
    return;
  }

  // ---- Customers --------------------------------------------------------

  Future<Customer?> customerById(String id) async {
    final row = await (_db.select(_db.customers)..where((c) => c.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _customerFromRow(row);
  }

  Customer _customerFromRow(CustomersData r) {
    return Customer(
      id: r.id,
      code: r.code,
      shopName: r.shopName,
      contactPerson: r.contactPerson,
      phone: r.phone,
      address: r.address,
      category: r.category,
      group: r.groupName,
      latitude: r.latitude,
      longitude: r.longitude,
    );
  }

  // ---- Routes -----------------------------------------------------------

  /// All active routes (excludes soft-deleted). Admin UI uses
  /// [allRoutesIncludingInactive] when it wants to show deactivated rows
  /// with a visual indicator.
  Future<List<SalesRoute>> allRoutes() async {
    final q = _db.select(_db.salesRoutesTable)
      ..where((r) => r.isActive.equals(true))
      ..orderBy([(r) => OrderingTerm.asc(r.name)]);
    if (_orgId != null) {
      // Exact-org match only. The previous `r.orgId.isNull() |` allowance let
      // any untagged route surface in EVERY org's route list — the same
      // cross-org leak already fixed for users in TeamRepository. Untagged
      // routes now belong to no org rather than to all of them.
      q.where((r) => r.orgId.equals(_orgId!));
    }
    return _hydrateRoutes(await q.get());
  }

  Future<List<SalesRoute>> allRoutesIncludingInactive() async {
    final q = _db.select(_db.salesRoutesTable)
      ..orderBy([(r) => OrderingTerm.asc(r.name)]);
    if (_orgId != null) {
      q.where((r) => r.orgId.equals(_orgId!));
    }
    return _hydrateRoutes(await q.get());
  }

  Future<SalesRoute?> routeById(String id) async {
    final row = await (_db.select(_db.salesRoutesTable)
          ..where((r) => r.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    final hydrated = await _hydrateRoutes([row]);
    return hydrated.isEmpty ? null : hydrated.first;
  }

  /// Routes assigned to the given user via the [RouteAssignments] table.
  /// Inactive routes are filtered out so a soft-deleted route never shows
  /// up on a salesperson's home.
  Future<List<SalesRoute>> routesAssignedTo(String userId) async {
    final assignments = await (_db.select(_db.routeAssignments)
          ..where((a) => a.userId.equals(userId)))
        .get();
    if (assignments.isEmpty) return const [];
    final routeIds = assignments.map((a) => a.routeId).toSet();
    final routes = await (_db.select(_db.salesRoutesTable)
          ..where((r) => r.id.isIn(routeIds) & r.isActive.equals(true)))
        .get();
    return _hydrateRoutes(routes);
  }

  /// Create a new route with the given name, kind, and ordered list of
  /// customer IDs. Returns the hydrated SalesRoute.
  Future<SalesRoute> createRoute({
    required String name,
    required RouteKind kind,
    required List<String> customerIds,
  }) async {
    final now = DateTime.now();
    final id = 'route_${now.microsecondsSinceEpoch}';
    await _db.transaction(() async {
      await _db.into(_db.salesRoutesTable).insert(
            SalesRoutesTableCompanion.insert(
              id: id,
              name: name.trim(),
              kind: kind == RouteKind.oneTime ? 'oneTime' : 'recurring',
              isActive: const Value(true),
              createdAt: Value(now),
              updatedAt: Value(now),
              orgId: Value(_orgId),
            ),
          );
      if (customerIds.isNotEmpty) {
        await _db.batch((b) {
          for (int i = 0; i < customerIds.length; i++) {
            b.insert(
              _db.routeStops,
              RouteStopsCompanion.insert(
                routeId: id,
                customerId: customerIds[i],
                position: i,
              ),
            );
          }
        });
      }
    });
    final created = await routeById(id);
    try {
      final row = await (_db.select(_db.salesRoutesTable)..where((r) => r.id.equals(id))).getSingleOrNull();
      if (row != null) await _sync?.pushRoute(row);
    } catch (_) {}
    return created!;
  }

  /// Updates a route's name, kind, and stops. Stops are rewritten wholesale
  /// from [customerIds] (positions are derived from list order).
  Future<SalesRoute> updateRoute({
    required String id,
    required String name,
    required RouteKind kind,
    required List<String> customerIds,
  }) async {
    final now = DateTime.now();
    await _db.transaction(() async {
      await (_db.update(_db.salesRoutesTable)
            ..where((r) => r.id.equals(id)))
          .write(SalesRoutesTableCompanion(
        name: Value(name.trim()),
        kind: Value(kind == RouteKind.oneTime ? 'oneTime' : 'recurring'),
        updatedAt: Value(now),
      ));
      // Replace stops.
      await (_db.delete(_db.routeStops)
            ..where((s) => s.routeId.equals(id)))
          .go();
      if (customerIds.isNotEmpty) {
        await _db.batch((b) {
          for (int i = 0; i < customerIds.length; i++) {
            b.insert(
              _db.routeStops,
              RouteStopsCompanion.insert(
                routeId: id,
                customerId: customerIds[i],
                position: i,
              ),
            );
          }
        });
      }
    });
    final updated = await routeById(id);
    try {
      final row = await (_db.select(_db.salesRoutesTable)..where((r) => r.id.equals(id))).getSingleOrNull();
      if (row != null) await _sync?.pushRoute(row);
    } catch (_) {}
    return updated!;
  }

  /// Soft-delete (deactivate) a route. Preserves trip history; hides from
  /// salesperson home and assignment editors.
  Future<void> setRouteActive({required String id, required bool active}) async {
    final now = DateTime.now();
    await (_db.update(_db.salesRoutesTable)
          ..where((r) => r.id.equals(id)))
        .write(SalesRoutesTableCompanion(
      isActive: Value(active),
      updatedAt: Value(now),
    ));
  }

  Future<List<SalesRoute>> _hydrateRoutes(List<SalesRoutesData> routes) async {
    final customersById = {
      for (final c in await _db.select(_db.customers).get()) c.id: c,
    };
    final stopRows = await (_db.select(_db.routeStops)
          ..orderBy([(t) => OrderingTerm.asc(t.position)]))
        .get();

    final result = <SalesRoute>[];
    for (final r in routes) {
      final stops = stopRows.where((s) => s.routeId == r.id).toList()
        ..sort((a, b) => a.position.compareTo(b.position));
      result.add(SalesRoute(
        id: r.id,
        name: r.name,
        kind: r.kind == 'oneTime' ? RouteKind.oneTime : RouteKind.recurring,
        isActive: r.isActive,
        stops: [
          for (final s in stops)
            if (customersById[s.customerId] != null)
              _customerFromRow(customersById[s.customerId]!),
        ],
      ));
    }
    return result;
  }

  /// List of user IDs assigned to a given route.
  Future<List<String>> usersAssignedTo(String routeId) async {
    final rows = await (_db.select(_db.routeAssignments)
          ..where((a) => a.routeId.equals(routeId)))
        .get();
    return rows.map((a) => a.userId).toList();
  }

  /// Sets the exact set of routes assigned to a user. Adds/removes as
  /// needed so the final state matches [routeIds].
  Future<void> setAssignmentsForUser({
    required String userId,
    required Set<String> routeIds,
    required String assignedBy,
  }) async {
    final now = DateTime.now();
    Set<String> toAdd = {};
    Set<String> toRemove = {};
    await _db.transaction(() async {
      final existing = await (_db.select(_db.routeAssignments)
            ..where((a) => a.userId.equals(userId)))
          .get();
      final existingIds = existing.map((e) => e.routeId).toSet();

      toAdd = routeIds.difference(existingIds);
      toRemove = existingIds.difference(routeIds);

      if (toRemove.isNotEmpty) {
        await (_db.delete(_db.routeAssignments)
              ..where((a) =>
                  a.userId.equals(userId) & a.routeId.isIn(toRemove)))
            .go();
      }
      for (final rid in toAdd) {
        await _db.into(_db.routeAssignments).insertOnConflictUpdate(
              RouteAssignmentsCompanion.insert(
                userId: userId,
                routeId: rid,
                assignedAt: now,
                assignedBy: Value(assignedBy),
              ),
            );
      }
    });
    // Best-effort cloud sync. Local writes already won; cloud catches up.
    try {
      for (final routeId in toRemove) {
        await _sync?.deleteRouteAssignment(userId: userId, routeId: routeId);
      }
      for (final routeId in toAdd) {
        final row = await (_db.select(_db.routeAssignments)
              ..where((a) =>
                  a.userId.equals(userId) & a.routeId.equals(routeId)))
            .getSingleOrNull();
        if (row != null) await _sync?.pushRouteAssignment(row);
      }
    } catch (e, st) {
      print('Route assignment sync failed: $e\n$st');
    }
  }

  // ---- Trips ------------------------------------------------------------

  /// Returns the currently open trip for [userId] (if any). There is only
  /// ever at most one open trip per user.
  Future<Trip?> activeTripForUser(String userId) async {
    final row = await (_db.select(_db.trips)
          ..where((t) => t.endedAt.isNull() & t.userId.equals(userId))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return null;
    return _tripFromRow(row);
  }

  /// Legacy: any open trip (any user). Kept for admin monitoring but should
  /// NOT be used by salesperson-home flows.
  Future<Trip?> activeTrip() async {
    final row = await (_db.select(_db.trips)
          ..where((t) => t.endedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return null;
    return _tripFromRow(row);
  }

  Future<List<Trip>> tripsClosedOnLocalDate(DateTime day) async {
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final q = _db.select(_db.trips)
      ..where((t) =>
          t.endedAt.isBiggerOrEqualValue(dayStart) &
          t.endedAt.isSmallerThanValue(dayEnd))
      ..orderBy([(t) => OrderingTerm.asc(t.endedAt)]);
    if (_orgId != null) {
      q.where((t) => t.orgId.equals(_orgId!));
    }
    return [for (final r in await q.get()) await _tripFromRow(r)];
  }

  Future<List<Trip>> tripsClosedOnLocalDateForUser(
      DateTime day, String userId) async {
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final q = _db.select(_db.trips)
      ..where((t) =>
          t.endedAt.isBiggerOrEqualValue(dayStart) &
          t.endedAt.isSmallerThanValue(dayEnd) &
          t.userId.equals(userId))
      ..orderBy([(t) => OrderingTerm.asc(t.endedAt)]);
    if (_orgId != null) {
      q.where((t) => t.orgId.equals(_orgId!));
    }
    return [for (final r in await q.get()) await _tripFromRow(r)];
  }

  Future<List<Trip>> tripsInRangeForUser(
      DateTime start, DateTime endInclusive, String userId) async {
    final rangeStart = DateTime(start.year, start.month, start.day);
    final rangeEnd = DateTime(endInclusive.year, endInclusive.month,
            endInclusive.day)
        .add(const Duration(days: 1));
    // Bucket by the day the trip was RUN (startedAt), not when it was
    // administratively closed (endedAt). A trip begun before midnight but
    // closed the next morning — by the salesperson leaving it open, or by
    // the cutoff scheduler — otherwise dumped its entire collection into the
    // wrong day. That is why yesterday's collections were surfacing under the
    // leaderboard's "Today". Still require a closed trip (endedAt not null):
    // the active trip is added separately by callers, so relaxing that guard
    // would double-count it.
    final q = _db.select(_db.trips)
      ..where((t) =>
          t.endedAt.isNotNull() &
          t.startedAt.isBiggerOrEqualValue(rangeStart) &
          t.startedAt.isSmallerThanValue(rangeEnd) &
          t.userId.equals(userId))
      ..orderBy([(t) => OrderingTerm.asc(t.startedAt)]);
    if (_orgId != null) {
      q.where((t) => t.orgId.equals(_orgId!));
    }
    return [for (final r in await q.get()) await _tripFromRow(r)];
  }

  /// Route IDs of one-time routes that [userId] has already completed at
  /// any point. Derived from the trips table — a one-time route is
  /// exhausted for this user if they have any completed trip on it.
  ///
  /// This replaces the old app_config 'exhausted_onetime_routes' key which
  /// was (a) global across users and (b) wiped on day rollover.
  Future<Set<String>> exhaustedOneTimeRoutesForUser(String userId) async {
    final rows = await (_db.select(_db.trips)
          ..where((t) =>
              t.userId.equals(userId) &
              t.routeKind.equals('oneTime') &
              t.endedAt.isNotNull()))
        .get();
    return rows.map((t) => t.routeId).toSet();
  }

  /// Inserts a brand new trip plus its trip_stops locally, then pushes
  /// both to Supabase immediately. Pushing the stops immediately prevents
  /// the "skeleton trip" bug (trip row in cloud with no stops attached)
  /// that we hit before — without immediate push, stops only synced via
  /// the periodic pushAll cycle, which sometimes never ran.
  Future<Trip> createTrip(Trip trip) async {
    await _db.batch((b) {
      b.insert(_db.trips, _tripCompanion(trip));
      b.insertAll(_db.tripStops, [
        for (int i = 0; i < trip.stopSnapshot.length; i++)
          TripStopsCompanion.insert(
            tripId: trip.id,
            customerId: trip.stopSnapshot[i].id,
            position: i,
          ),
      ]);
    });
    // Best-effort cloud push. Local insert is the source of truth — if
    // network is down here the periodic sync will catch up later.
    try {
      final tripRow = await (_db.select(_db.trips)
            ..where((t) => t.id.equals(trip.id)))
          .getSingleOrNull();
      if (tripRow != null) await _sync?.pushTrip(tripRow);
      final stopRows = await (_db.select(_db.tripStops)
            ..where((s) => s.tripId.equals(trip.id)))
          .get();
      for (final s in stopRows) {
        await _sync?.pushTripStop(s);
      }
    } catch (_) {}
    return trip;
  }

  /// Persists a trip update locally, then pushes the row to Supabase.
  /// Critical for the End Trip flow: without the push, the cloud keeps
  /// the trip marked "in progress" forever, and a future re-login on
  /// the same device pulls the open trip back down — which is exactly
  /// the bug we hit with the stuck "Test Route".
  Future<void> updateTrip(Trip trip) async {
    await _db.update(_db.trips).replace(_tripCompanion(trip));
    try {
      final row = await (_db.select(_db.trips)
            ..where((t) => t.id.equals(trip.id)))
          .getSingleOrNull();
      if (row != null) await _sync?.pushTrip(row);
    } catch (_) {}
  }

  TripsCompanion _tripCompanion(Trip t) {
    return TripsCompanion.insert(
      id: t.id,
      routeId: t.routeId,
      routeName: t.routeName,
      routeKind: t.routeKind.name,
      startedAt: t.startedAt,
      endedAt: Value(t.endedAt),
      closeReason: Value(t.closeReason?.name),
      startLat: Value(t.startLat),
      startLng: Value(t.startLng),
      endLat: Value(t.endLat),
      endLng: Value(t.endLng),
      userId: Value(t.userId),
      userName: Value(t.userName),
      userRole: Value(t.userRole),
      orgId: Value(_orgId),
    );
  }

  Future<Trip> _tripFromRow(TripsData r) async {
    // Stops snapshot — join via trip_stops
    final stopRows = await (_db.select(_db.tripStops)
          ..where((s) => s.tripId.equals(r.id))
          ..orderBy([(s) => OrderingTerm.asc(s.position)]))
        .get();
    final customerIds = stopRows.map((s) => s.customerId).toList();
    final customers = customerIds.isEmpty
        ? <CustomersData>[]
        : await (_db.select(_db.customers)
              ..where((c) => c.id.isIn(customerIds)))
            .get();
    final byId = {for (final c in customers) c.id: _customerFromRow(c)};
    final ordered = [
      for (final s in stopRows)
        if (byId[s.customerId] != null) byId[s.customerId]!,
    ];

    // Visits
    final visitRows = await (_db.select(_db.visits)
          ..where((v) => v.tripId.equals(r.id))
          ..orderBy([(v) => OrderingTerm.asc(v.timestamp)]))
        .get();
    final visits = [for (final v in visitRows) _visitFromRow(v)];

    return Trip(
      id: r.id,
      routeId: r.routeId,
      routeName: r.routeName,
      routeKind:
          r.routeKind == 'oneTime' ? RouteKind.oneTime : RouteKind.recurring,
      stopSnapshot: ordered,
      startedAt: r.startedAt,
      endedAt: r.endedAt,
      closeReason: r.closeReason == null
          ? null
          : (r.closeReason == 'cutoff'
              ? TripCloseReason.cutoff
              : TripCloseReason.userEnded),
      visits: visits,
      startLat: r.startLat,
      startLng: r.startLng,
      endLat: r.endLat,
      endLng: r.endLng,
      userId: r.userId,
      userName: r.userName,
      userRole: r.userRole,
    );
  }

  // ---- Visits -----------------------------------------------------------

  Future<void> updateVisitPhotos(String visitId, List<String> paths) async {
    await (_db.update(_db.visits)..where((v) => v.id.equals(visitId)))
        .write(VisitsCompanion(photoPathsJson: Value(jsonEncode(paths))));
    // Push the updated visit row so admin photo gallery sees the URLs
    // promptly. Local update wins; cloud is best-effort.
    try {
      final row = await (_db.select(_db.visits)
            ..where((v) => v.id.equals(visitId)))
          .getSingleOrNull();
      if (row != null) await _sync?.pushVisit(row);
    } catch (_) {}
  }

  /// Inserts a visit locally and pushes immediately. The SyncController
  /// also has a 30-second retry loop for any visits that fail to push
  /// here, so this is belt-and-braces.
  Future<void> insertVisit(Visit v) async {
    await _db.into(_db.visits).insert(
          VisitsCompanion.insert(
            id: v.id,
            tripId: _currentTripIdForVisit(v),
            customerId: v.customerId,
            status: v.status.name,
            timestamp: v.timestamp,
            capturedLat: Value(v.capturedLat),
            capturedLng: Value(v.capturedLng),
            accuracyMeters: Value(v.accuracyMeters),
            distanceMeters: Value(v.distanceMeters),
            amount: Value(v.amount),
            receiptNumber: Value(v.receiptNumber),
            notes: Value(v.notes),
            skipReason: Value(v.skipReason),
            photoPathsJson: Value(jsonEncode(v.photoPaths)),
            userId: Value(v.userId),
            userName: Value(v.userName),
            userRole: Value(v.userRole),
          ),
        );
    try {
      final row = await (_db.select(_db.visits)
            ..where((v2) => v2.id.equals(v.id)))
          .getSingleOrNull();
      if (row != null) {
        await _sync?.pushVisit(row);
        // Mark synced locally so SyncController.flushPending doesn't try
        // to re-push it later (it filters on syncStatus == 'pending').
        await (_db.update(_db.visits)..where((v3) => v3.id.equals(v.id)))
            .write(const VisitsCompanion(syncStatus: Value('synced')));
      }
    } catch (_) {
      // Push failed — leave syncStatus as default 'pending' so the
      // periodic flushPending will retry.
    }
  }

  /// The Visit model doesn't carry a tripId, but every insert happens inside
  /// an active trip — the controller supplies it separately.
  String? _pendingTripId;
  void setCurrentTripContext(String tripId) => _pendingTripId = tripId;
  String _currentTripIdForVisit(Visit v) {
    if (_pendingTripId == null) {
      throw StateError('No current trip context set for visit insert.');
    }
    return _pendingTripId!;
  }

  Visit _visitFromRow(VisitsData r) {
    return Visit(
      id: r.id,
      customerId: r.customerId,
      status: VisitStatus.values.firstWhere((s) => s.name == r.status),
      timestamp: r.timestamp,
      capturedLat: r.capturedLat,
      capturedLng: r.capturedLng,
      accuracyMeters: r.accuracyMeters,
      distanceMeters: r.distanceMeters,
      amount: r.amount,
      receiptNumber: r.receiptNumber,
      notes: r.notes,
      skipReason: r.skipReason,
      photoPaths: _decodePhotos(r.photoPathsJson),
      userId: r.userId,
      userName: r.userName,
      userRole: r.userRole,
    );
  }

  List<String> _decodePhotos(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) {
        return [for (final x in decoded) x.toString()];
      }
    } catch (_) {}
    return const [];
  }

  // ---- Config -----------------------------------------------------------

  Future<Set<String>> exhaustedOneTimeRouteIds() async {
    final raw = await _db.getConfig('exhausted_onetime_routes') ?? '[]';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return {for (final x in decoded) x.toString()};
      }
    } catch (_) {}
    return {};
  }

  Future<void> setExhaustedOneTimeRouteIds(Set<String> ids) async {
    await _db.setConfig('exhausted_onetime_routes', jsonEncode(ids.toList()));
  }

  Future<DateTime?> dayStamp() async {
    final raw = await _db.getConfig('day_stamp');
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> setDayStamp(DateTime day) async {
    await _db.setConfig('day_stamp', day.toIso8601String());
  }
}

final salespersonRepositoryProvider =
    Provider<SalespersonRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final orgId = ref.watch(orgIdProvider);
  final sync = ref.watch(supabaseSyncServiceProvider);
  return SalespersonRepository(db, orgId: orgId, sync: sync);
});