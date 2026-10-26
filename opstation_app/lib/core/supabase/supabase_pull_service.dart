import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../database/app_database_provider.dart';
import 'supabase_sync_service.dart';
import '../utils/customer_locations.dart';
import '../utils/receipt_books.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pulls org data from Supabase and writes it into local Drift DB.
/// Called on fresh install login so the device has all org data locally.
class SupabasePullService {
  final AppDatabase _db;
  final SupabaseSyncService _sync;

  SupabasePullService(this._db, this._sync);

  /// Pull all orgs and their full data from Supabase — used by superadmin on login.
  Future<void> pullAllOrgs() async {
    try {
      // Pull orgs first
      final orgRows = await _sync.pullTable('orgs', null);
      await _pullOrgs(orgRows);

      // Pull all users
      final users = await _sync.pullTable('users', null);
      await _pullUsers(users);

      // Pull full data for each org
      for (final org in orgRows) {
        final orgId = org['id'] as String?;
        if (orgId == null) continue;
        try {
          final data = await _sync.pullOrgData(orgId);
          await _db.transaction(() async {
            await _pullCustomers(data.customers);
            await _pullCatalogProducts(data.products);
            await _pullRoutes(data.routes);
            await _pullRouteStops(data.routeStops);
            await _pullRouteAssignments(data.routeAssignments);
            await _pullTrips(data.trips);
            await _pullTripStops(data.tripStops);
            await _pullVisits(data.visits);
            await _pullDeliveries(data.deliveries);
            await _pullDeliveryStops(data.deliveryStops);
          });
          await _pullIntelligenceTables(orgId);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Pull all data for [orgId] from Supabase and upsert into local SQLite.
  /// Safe to call repeatedly — uses insertOnConflictUpdate throughout.
  Future<void> pullOrgData(String orgId) async {
    print('PULL START: orgId=\$orgId');
    final data = await _sync.pullOrgData(orgId);
    print('PULL DATA: orgs=\${data.orgs.length} users=\${data.users.length} trips=\${data.trips.length} visits=\${data.visits.length}');
    debugPrint('PULL: orgs=\${data.orgs.length} users=\${data.users.length} customers=\${data.customers.length} routes=\${data.routes.length} trips=\${data.trips.length} visits=\${data.visits.length}');
    await _db.transaction(() async {
      await _pullOrgs(data.orgs);
      // Per-org set-replace: refresh ONLY this org's users (catches
      // server-side removals) without touching other orgs' rows. Upsert
      // alone never deletes, so removed users would linger; a wholesale
      // delete is the opposite mistake — it wipes every OTHER org off the
      // device. Scoping the delete to `orgId` keeps each org independent.
      // Guarded: a pull that returned no users must never wipe the org.
      // (data.users also carries the null-org superadmin, which this
      // org-scoped delete never matches.)
      if (data.users.isNotEmpty) {
        await (_db.delete(_db.users)..where((u) => u.orgId.equals(orgId))).go();
      }
      await _pullUsers(data.users);
      await _pullCustomers(data.customers);
      await _pullCatalogProducts(data.products);
      await _pullRoutes(data.routes);
      await _pullRouteStops(data.routeStops);
      await _pullRouteAssignments(data.routeAssignments);
      await _pullTrips(data.trips);
      await _pullTripStops(data.tripStops);
      await _pullVisits(data.visits);
      await _pullDeliveries(data.deliveries);
      await _pullDeliveryStops(data.deliveryStops);
    });
    await _pullIntelligenceTables(orgId);
  }

  /// Login-blocking essentials: writes only what the home screen needs to work
  /// offline. Pair with [pullHistory] (run in the background) for the rest.
  Future<void> pullEssentials(String orgId) async {
    final data = await _sync.pullEssentials(orgId);
    await _db.transaction(() async {
      await _pullOrgs(data.orgs);
      // Same per-org set-replace semantics as pullOrgData: refresh only this
      // org's users, and never wipe the org if the pull returned none.
      if (data.users.isNotEmpty) {
        await (_db.delete(_db.users)..where((u) => u.orgId.equals(orgId))).go();
      }
      await _pullUsers(data.users);
      await _pullCustomers(data.customers);
      await _pullCatalogProducts(data.products);
      await _pullRoutes(data.routes);
      await _pullRouteStops(data.routeStops);
      await _pullRouteAssignments(data.routeAssignments);
    });
    // Customers' extra locations (Main + e.g. Godown) — needed to verify visits.
    await CustomerLocations.refresh(_db, orgId);
    await ReceiptBooks.refresh(_db, orgId);
    // Survey categories / SKUs are small: fetch them at login too, so a
    // surveyor never waits for the slow history pull to see new ones.
    try {
      final r = await Future.wait([
        Supabase.instance.client.from('competitor_categories').select().eq('org_id', orgId),
        Supabase.instance.client.from('intelligence_products').select().eq('org_id', orgId),
      ]);
      await _db.transaction(() async {
        await _pullCompetitorCategories(_asList(r[0]));
        await _pullProducts(_asList(r[1]));
      });
    } catch (_) {}
  }

  /// Background history pull: trips, stops, visits, deliveries + Intelligence.
  /// Safe to call unawaited after login — the app is already usable from the
  /// essentials, and this just fills in past activity.
  Future<void> pullHistory(String orgId) async {
    final data = await _sync.pullHistory(orgId);
    await _db.transaction(() async {
      await _pullTrips(data.trips);
      await _pullTripStops(data.tripStops);
      await _pullVisits(data.visits);
      await _pullDeliveries(data.deliveries);
      await _pullDeliveryStops(data.deliveryStops);
    });
    await _pullIntelligenceTables(orgId);
  }

  /// Fast targeted pull — today's trips (plus their stops and visits) for one
  /// org. Team-monitoring reads local Drift, which previously only refreshed
  /// at login, so an admin's Live tab went stale through the day and showed
  /// "No activity today" while the server had plenty. Calling this before the
  /// read keeps the tab current on every refresh without paying for the full
  /// pullOrgData (customers, routes, catalog, deliveries).
  Future<void> pullTodayTripsForOrg(String orgId) async {
    try {
      final client = Supabase.instance.client;
      final now = DateTime.now();
      // Generous lower bound: a trip that began yesterday and is still open
      // is exactly the case monitoring cares about.
      final since =
          DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));

      final sinceIso = since.toUtc().toIso8601String();
      final tripRows = await client
          .from('trips')
          .select()
          .eq('org_id', orgId)
          .or('ended_at.is.null,started_at.gte.$sinceIso');
      final trips = [
        for (final r in (tripRows as List)) Map<String, dynamic>.from(r as Map)
      ];
      // Older trips saved without an org: take the ones run by this org's
      // salespersons, and file them under the org on the phone so the
      // monitoring screens (which filter by org) can see them.
      try {
        final team = await client.rpc('field_team', params: {'p_org': orgId});
        final ids = [for (final u in (team as List)) '${(u as Map)['id']}'];
        for (var i = 0; i < ids.length; i += 40) {
          final batch = ids.sublist(i, i + 40 > ids.length ? ids.length : i + 40);
          final extra = await client.from('trips').select()
              .filter('org_id', 'is', null)
              .inFilter('user_id', batch)
              .or('ended_at.is.null,started_at.gte.$sinceIso');
          for (final r in (extra as List)) {
            trips.add({...Map<String, dynamic>.from(r as Map), 'org_id': orgId});
          }
        }
      } catch (_) {}
      if (trips.isEmpty) return;

      final tripIds = trips.map((t) => t['id'] as String).toList();
      final stops = <Map<String, dynamic>>[];
      final visits = <Map<String, dynamic>>[];
      // Batched: `in.(...)` travels in the URL, so a long id list 400s.
      for (var i = 0; i < tripIds.length; i += 40) {
        final batch =
            tripIds.sublist(i, i + 40 > tripIds.length ? tripIds.length : i + 40);
        final s = await client
            .from('trip_stops')
            .select()
            .inFilter('trip_id', batch);
        for (final r in (s as List)) {
          stops.add(Map<String, dynamic>.from(r as Map));
        }
        final v =
            await client.from('visits').select().inFilter('trip_id', batch);
        for (final r in (v as List)) {
          visits.add(Map<String, dynamic>.from(r as Map));
        }
      }

      await _db.transaction(() async {
        await _pullTrips(trips);
        await _pullTripStops(stops);
        await _pullVisits(visits);
      });
    } catch (e) {
      // Best-effort: monitoring falls back to whatever is already local.
      print('pullTodayTripsForOrg failed: $e');
    }
  }

  /// Refreshes this org's users on the phone (upsert only, never deletes).
  /// The admin dashboard, live routes and leaderboard all start from the local
  /// user list — if it is missing or stale they show zeros / nothing.
  Future<void> refreshOrgUsers(String orgId) async {
    try {
      // Paged — an org with many retailer logins passes the 1000-row cap.
      final rows = <Map<String, dynamic>>[];
      for (var from = 0; ; from += 1000) {
        final page = List<Map<String, dynamic>>.from(await Supabase.instance.client
            .from('users')
            .select()
            .eq('org_id', orgId)
            .order('id')
            .range(from, from + 999) as List);
        rows.addAll(page);
        if (page.length < 1000) break;
      }
      if (rows.isEmpty) return;
      await _db.transaction(() async {
        await _pullUsers(rows);
      });
    } catch (e) {
      print('refreshOrgUsers failed: $e');
    }
  }

  /// Fast targeted pull — refreshes only one user's route_assignments,
  /// skipping the expensive trips/visits/deliveries pull. Used by the
  /// salesperson home's realtime subscription and the "Retry now" button.
  Future<void> pullRouteAssignmentsForUser(String userId) async {
    try {
      final rows = await _sync.pullRouteAssignmentsByUserId(userId);
      await _db.transaction(() async {
        // Replace this user's assignments with what's currently in cloud.
        // Wholesale replace mirrors the admin's set-semantics edit.
        await (_db.delete(_db.routeAssignments)
              ..where((a) => a.userId.equals(userId)))
            .go();
        await _pullRouteAssignments(rows);
      });
    } catch (e) {
      print('pullRouteAssignmentsForUser failed: $e');
    }
  }

  /// Targeted pull of routes + their stops for one org — used by the
  /// salesperson home's realtime subscription when an admin edits a route,
  /// and by the on-resume catch-up. Stops are replaced wholesale (the admin
  /// edit deletes + re-inserts them) and routes that no longer exist in the
  /// cloud are pruned locally so deletions propagate without a re-login.
  Future<void> pullRoutesAndStops(String orgId) async {
    try {
      final routes = await _sync.pullTable('sales_routes', orgId);
      final routeIds = [for (final r in routes) r['id'] as String];
      // Scope + paginate the stop fetch to THIS org's routes. A bare
      // `.select()` on route_stops (no org_id column) returns at most
      // PostgREST's 1000-row cap in an unstable order, so on a large org the
      // wholesale delete+replace below dropped whatever fell outside that
      // window — customers appeared to auto-add and vanish between syncs.
      final stops = await _sync.pullRouteStopsByRouteIds(routeIds);
      // Customers are otherwise downloaded only at LOGIN. When an admin adds
      // NEW customers to a route, the stops arrived here in real time but
      // their customers never did — and a stop whose customer isn't on the
      // phone is hidden, so the route showed "0 customers" until the
      // salesperson logged out and in again. Fetch any missing ones now.
      final missingCustomers = await _fetchCustomerUpdates(orgId, stops);
      await _db.transaction(() async {
        await _pullCustomers(missingCustomers);
        // Prune this org's routes that vanished from the cloud.
        final cloudIds = {for (final r in routes) r['id'] as String};
        final local = await (_db.select(_db.salesRoutesTable)
              ..where((t) => t.orgId.equals(orgId)))
            .get();
        for (final l in local) {
          if (!cloudIds.contains(l.id)) {
            await (_db.delete(_db.salesRoutesTable)
                  ..where((t) => t.id.equals(l.id)))
                .go();
          }
        }
        await _pullRoutes(routes);
        // Replace stops only for THIS org's routes (not every route on the
        // device), and only when we actually have routes to refresh — so a
        // momentarily-empty routes fetch can never wipe local membership.
        if (routeIds.isNotEmpty) {
          await (_db.delete(_db.routeStops)
                ..where((s) => s.routeId.isIn(routeIds)))
              .go();
        }
        await _pullRouteStops(stops);
      });
      await CustomerLocations.refresh(_db, orgId);
      await ReceiptBooks.refresh(_db, orgId);
    } catch (e) {
      print('pullRoutesAndStops failed: $e');
    }
  }

  /// Keeps the phone's customers current between logins:
  ///  (a) customers EDITED on the server since the newest one on the phone
  ///      (location, phone, name …) — with a 10-minute overlap so a clock
  ///      difference can never skip an edit;
  ///  (b) customers referenced by [stops] that the phone doesn't have at all.
  /// Batched so an id list never overflows the request URL.
  Future<List<Map<String, dynamic>>> _fetchCustomerUpdates(
      String orgId, List<Map<String, dynamic>> stops) async {
    final localRows = await (_db.select(_db.customers)
          ..where((c) => c.orgId.equals(orgId)))
        .get();
    final allLocalIds = {
      for (final c in await _db.select(_db.customers).get()) c.id,
    };
    final out = <Map<String, dynamic>>[];
    final got = <String>{};

    // (a) edited since the newest local copy
    DateTime? newest;
    for (final c in localRows) {
      final u = c.updatedAt;
      if (u != null && (newest == null || u.isAfter(newest))) newest = u;
    }
    if (newest != null) {
      try {
        final changed = await _sync.pullCustomersChangedSince(
            orgId, newest.subtract(const Duration(minutes: 10)));
        for (final r in changed) {
          if (got.add('${r['id']}')) out.add(r);
        }
      } catch (e) {
        print('fetch changed customers failed: $e');
      }
    }

    // (b) referenced by a stop but not on the phone
    final wanted = {
      for (final s in stops)
        if (s['customer_id'] is String) s['customer_id'] as String,
    };
    final missing =
        wanted.difference(allLocalIds).where((id) => !got.contains(id)).toList();
    if (missing.isEmpty) {
      if (out.isNotEmpty) print('Routes refresh: ${out.length} customer update(s)');
      return out;
    }
    final client = Supabase.instance.client;
    for (var i = 0; i < missing.length; i += 100) {
      final batch =
          missing.sublist(i, i + 100 > missing.length ? missing.length : i + 100);
      try {
        final rows = await client.from('customers').select().inFilter('id', batch);
        for (final r in List<Map<String, dynamic>>.from(rows)) {
          if (got.add('${r['id']}')) out.add(r);
        }
      } catch (e) {
        print('fetch missing customers failed: $e');
      }
    }
    print('Routes refresh: ${out.length} customer update(s), incl. missing ones');
    return out;
  }

  /// Pull a single user record into local DB (used for fresh install
  /// when the user has no org or is superadmin).
  Future<void> pullUserRecord(Map<String, dynamic> r) async {
    try {
      await _db.into(_db.users).insertOnConflictUpdate(UsersCompanion(
        id: Value(r['id'] as String),
        name: Value(r['name'] as String),
        email: Value(r['email'] as String),
        phone: Value(r['phone'] as String? ?? ''),
        role: Value(r['role'] as String),
        isActive: Value(r['is_active'] as bool? ?? true),
        passwordHash: Value(r['password_hash'] as String? ?? ''),
        passwordSalt: Value(r['password_salt'] as String? ?? ''),
        createdAt: Value(_parseDate(r['created_at'])),
        updatedAt: Value(_parseDateNullable(r['updated_at'])),
        passwordTemporary: Value(r['password_temporary'] as bool? ?? false),
        orgId: Value(r['org_id'] as String?),
      ));
    } catch (_) {}
  }

  Future<void> _pullOrgs(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.orgs).insertOnConflictUpdate(OrgsCompanion(
          id: Value(r['id'] as String),
          name: Value(r['name'] as String),
          masterAdminId: Value(r['master_admin_id'] as String?),
          isActive: Value(r['is_active'] as bool? ?? true),
          createdAt: Value(_parseDate(r['created_at'])),
          updatedAt: Value(_parseDateNullable(r['updated_at'])),
        ));
      } catch (_) {}
    }
  }

  Future<void> _pullUsers(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.users).insertOnConflictUpdate(UsersCompanion(
          id: Value(r['id'] as String),
          // A blank name / email used to drop the whole user (hard cast threw,
          // catch swallowed it) — and a user missing from the phone vanishes
          // from the admin dashboard, live routes and leaderboard.
          name: Value(r['name'] as String? ?? ''),
          email: Value(r['email'] as String? ?? ''),
          phone: Value(r['phone'] as String? ?? ''),
          role: Value(r['role'] as String? ?? ''),
          isActive: Value(r['is_active'] as bool? ?? true),
          passwordHash: Value(r['password_hash'] as String? ?? ''),
          passwordSalt: Value(r['password_salt'] as String? ?? ''),
          createdAt: Value(_parseDate(r['created_at'])),
          updatedAt: Value(_parseDateNullable(r['updated_at'])),
          passwordTemporary: Value(r['password_temporary'] as bool? ?? false),
          orgId: Value(r['org_id'] as String?),
        ));
      } catch (_) {}
    }
  }

  Future<void> _pullCustomers(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.customers).insertOnConflictUpdate(CustomersCompanion(
          // Blank fields can arrive as NULL. A hard `as String` threw here and
          // the catch below silently dropped the WHOLE customer — so it never
          // reached the phone and every route stop pointing to it vanished
          // ("0 customers"). Treat missing text as empty instead.
          id: Value(r['id'] as String),
          code: Value(r['code'] as String? ?? ''),
          shopName: Value(r['shop_name'] as String? ?? ''),
          contactPerson: Value(r['contact_person'] as String? ?? ''),
          phone: Value(r['phone'] as String? ?? ''),
          address: Value(r['address'] as String? ?? ''),
          category: Value(r['category'] as String?),
          groupName: Value(r['group_name'] as String?),
          latitude: Value((r['latitude'] as num?)?.toDouble()),
          longitude: Value((r['longitude'] as num?)?.toDouble()),
          isActive: Value(r['is_active'] as bool? ?? true),
          updatedAt: Value(_parseDateNullable(r['updated_at'])),
          ntnGst: Value(r['ntn_gst'] as String?),
          orgId: Value(r['org_id'] as String?),
          // Server is canonical for customers. Without this, pulled rows
          // default to sync_status='pending' and queue up for pointless
          // push-back — caused the thousands-of-failed-POSTs storm.
        ));
      } catch (_) {}
    }
  }

  /// Cache the sellable ERP catalog for offline order-taking. Server is
  /// canonical, so rows land as 'synced' (never queued for push-back).
  Future<void> _pullCatalogProducts(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.catalogProducts).insertOnConflictUpdate(
              CatalogProductsCompanion(
                id: Value(r['id'] as String),
                orgId: Value(r['org_id'] as String? ?? ''),
                name: Value(r['name'] as String? ?? ''),
                sku: Value(r['sku'] as String?),
                sellingPrice:
                    Value((r['selling_price'] as num?)?.toDouble() ?? 0),
                baseUomId: Value(r['base_uom_id'] as String?),
                productSubGroup: Value(r['product_sub_group'] as String?),
                isActive: Value(r['is_active'] as bool? ?? true),
                updatedAt: Value(_parseDateNullable(r['updated_at'])),
                syncStatus: const Value('synced'),
              ),
            );
      } catch (_) {}
    }
  }

  Future<void> _pullRoutes(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.salesRoutesTable).insertOnConflictUpdate(
            SalesRoutesTableCompanion(
          id: Value(r['id'] as String),
          name: Value(r['name'] as String),
          kind: Value(r['kind'] as String),
          isActive: Value(r['is_active'] as bool? ?? true),
          createdAt: Value(_parseDateNullable(r['created_at'])),
          updatedAt: Value(_parseDateNullable(r['updated_at'])),
          orgId: Value(r['org_id'] as String?),
        ));
      } catch (_) {}
    }
  }

  Future<void> _pullRouteStops(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.routeStops).insertOnConflictUpdate(
            RouteStopsCompanion(
          routeId: Value(r['route_id'] as String),
          customerId: Value(r['customer_id'] as String),
          position: Value((r['position'] as num?)?.toInt() ?? 0),
        ));
      } catch (_) {}
    }
  }

  Future<void> _pullRouteAssignments(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.routeAssignments).insertOnConflictUpdate(
            RouteAssignmentsCompanion(
          userId: Value(r['user_id'] as String),
          routeId: Value(r['route_id'] as String),
          assignedAt: Value(_parseDate(r['assigned_at'])),
          assignedBy: Value(r['assigned_by'] as String? ?? ''),
        ));
      } catch (_) {}
    }
  }

  Future<void> _pullTrips(List<Map<String, dynamic>> rows) async {
    print('INSERTING \${rows.length} trips');
    for (final r in rows) {
      try {
        await _db.into(_db.trips).insertOnConflictUpdate(TripsCompanion(
          id: Value(r['id'] as String),
          // Blank route fields (e.g. free routes) used to drop the whole trip.
          routeId: Value(r['route_id'] as String? ?? ''),
          routeName: Value(r['route_name'] as String? ?? ''),
          routeKind: Value(r['route_kind'] as String? ?? 'free'),
          startedAt: Value(_parseDate(r['started_at'])),
          endedAt: Value(_parseDateNullable(r['ended_at'])),
          closeReason: Value(r['close_reason'] as String?),
          startLat: Value((r['start_lat'] as num?)?.toDouble()),
          startLng: Value((r['start_lng'] as num?)?.toDouble()),
          endLat: Value((r['end_lat'] as num?)?.toDouble()),
          endLng: Value((r['end_lng'] as num?)?.toDouble()),
          userId: Value(r['user_id'] as String? ?? ''),
          userName: Value(r['user_name'] as String? ?? ''),
          userRole: Value(r['user_role'] as String? ?? ''),
          orgId: Value(r['org_id'] as String?),
          // Server is canonical for pulled trips. Without this, they
          // default to sync_status='pending' and silently fail re-push
          // with PK conflicts (same pattern as the customers storm).
        ));
      } catch (_) {}
    }
  }

  Future<void> _pullTripStops(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.tripStops).insertOnConflictUpdate(
            TripStopsCompanion(
          tripId: Value(r['trip_id'] as String),
          customerId: Value(r['customer_id'] as String),
          position: Value((r['position'] as num?)?.toInt() ?? 0),
        ));
      } catch (_) {}
    }
  }

  Future<void> _pullVisits(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.visits).insertOnConflictUpdate(VisitsCompanion(
          id: Value(r['id'] as String),
          tripId: Value(r['trip_id'] as String),
          customerId: Value(r['customer_id'] as String),
          status: Value(r['status'] as String),
          timestamp: Value(_parseDate(r['timestamp'])),
          capturedLat: Value((r['captured_lat'] as num?)?.toDouble()),
          capturedLng: Value((r['captured_lng'] as num?)?.toDouble()),
          accuracyMeters: Value((r['accuracy_meters'] as num?)?.toDouble()),
          distanceMeters: Value((r['distance_meters'] as num?)?.toDouble()),
          amount: Value((r['amount'] as num?)?.round() ?? 0),
          receiptNumber: Value(r['receipt_number'] as String?),
          notes: Value(r['notes'] as String?),
          skipReason: Value(r['skip_reason'] as String?),
          photoPathsJson: Value(r['photo_paths_json'] is String
              ? r['photo_paths_json'] as String
              : (r['photo_paths_json'] == null ? '[]' : jsonEncode(r['photo_paths_json']))),
          syncStatus: const Value('synced'),
          userId: Value(r['user_id'] as String? ?? ''),
          userName: Value(r['user_name'] as String? ?? ''),
          userRole: Value(r['user_role'] as String? ?? ''),
        ));
      } catch (_) {}
    }
  }

  Future<void> _pullDeliveries(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.deliveries).insertOnConflictUpdate(
            DeliveriesCompanion(
          id: Value(r['id'] as String),
          driverId: Value(r['driver_id'] as String?),
          driverName: Value(r['driver_name'] as String?),
          driverRole: Value(r['driver_role'] as String?),
          createdBy: Value(r['created_by'] as String),
          createdByName: Value(r['created_by_name'] as String? ?? ''),
          createdByRole: Value(r['created_by_role'] as String? ?? ''),
          createdAt: Value(_parseDate(r['created_at'])),
          startedAt: Value(_parseDateNullable(r['started_at'])),
          completedAt: Value(_parseDateNullable(r['completed_at'])),
          status: Value(r['status'] as String? ?? 'draft'),
          notes: Value(r['notes'] as String?),
          orgId: Value(r['org_id'] as String?),
          jobType: Value(r['job_type'] as String? ?? 'delivery'),
        ));
      } catch (_) {}
    }
  }

  Future<void> _pullDeliveryStops(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.deliveryStops).insertOnConflictUpdate(
            DeliveryStopsCompanion(
          id: Value(r['id'] as String),
          deliveryId: Value(r['delivery_id'] as String),
          customerId: Value(r['customer_id'] as String),
          customerCode: Value(r['customer_code'] as String? ?? ''),
          customerName: Value(r['customer_name'] as String? ?? ''),
          sequence: Value(r['sequence'] as int),
          itemDescription: Value(r['item_description'] as String? ?? ''),
          amount: Value((r['amount'] as num?)?.round() ?? 0),
          paymentType: Value(r['payment_type'] as String? ?? 'cash'),
          status: Value(r['status'] as String? ?? 'pending'),
          deliveredAt: Value(_parseDateNullable(r['delivered_at'])),
          failureReason: Value(r['failure_reason'] as String?),
          cashReceived: Value(r['cash_received'] as int?),
          capturedLat: Value((r['captured_lat'] as num?)?.toDouble()),
          capturedLng: Value((r['captured_lng'] as num?)?.toDouble()),
          distanceMeters: Value(r['distance_meters'] as int?),
          verification: Value(r['verification'] as String? ?? 'pending'),
          photoPathsJson: Value(r['photo_paths_json'] as String? ?? '[]'),
          driverNote: Value(r['driver_note'] as String?),
          soInvoiceNumber: Value(r['so_invoice_number'] as String?),
          targetLat: Value((r['target_lat'] as num?)?.toDouble()),
          targetLng: Value((r['target_lng'] as num?)?.toDouble()),
          stopType: Value(r['stop_type'] as String? ?? 'delivery'),
        ));
      } catch (_) {}
    }
  }

  /// Quick refresh of what the surveyor screens need — competitor categories,
  /// survey SKUs and the org's customers (name / main group / group). Small and
  /// fast, so the survey screens call it every time they open (and on
  /// pull-to-refresh) instead of waiting for the slow background history pull.
  /// Categories / SKUs removed on the server are removed here too.
  /// Returns false when the device could not reach the server.
  Future<bool> refreshSurveyReference(String orgId) async {
    try {
      final client = Supabase.instance.client;
      Future<List<Map<String, dynamic>>> paged(String table, String cols) async {
        final out = <Map<String, dynamic>>[];
        for (int f = 0;; f += 1000) {
          final page = _asList(await client.from(table).select(cols).eq('org_id', orgId).range(f, f + 999));
          out.addAll(page);
          if (page.length < 1000 || f > 100000) break;
        }
        return out;
      }
      final res = await Future.wait([
        paged('competitor_categories', '*'),
        paged('intelligence_products', '*'),
        paged('customers', '*'),
      ]);
      final cats = res[0], prods = res[1], custs = res[2];
      // Never overwrite a customer edited on this phone and not yet uploaded.
      final pending = {
        for (final c in await (_db.select(_db.customers)..where((c) => c.syncStatus.equals('pending'))).get()) c.id
      };
      await _db.transaction(() async {
        await _pullCompetitorCategories(cats);
        await _pullProducts(prods);
        final catIds = {for (final c in cats) c['id'] as String};
        final prodIds = {for (final p in prods) p['id'] as String};
        await (_db.delete(_db.competitorCategories)
              ..where((c) => c.orgId.equals(orgId) & c.id.isNotIn(catIds.toList())))
            .go();
        await (_db.delete(_db.products)
              ..where((p) => p.orgId.equals(orgId) & p.id.isNotIn(prodIds.toList())))
            .go();
        await _pullCustomers(custs.where((c) => !pending.contains(c['id'])).toList());
      });
      return true;
    } catch (e) {
      print('SURVEY REFERENCE REFRESH ERROR (org=$orgId): $e');
      return false;
    }
  }

  /// Pulls the four Intelligence tables for [orgId]:
  ///   - competitor_categories (reference data)
  ///   - products (reference data)
  ///   - competitor_spotting (history)
  ///   - placement_audit (history)
  /// Each fetch runs in parallel, then writes into local Drift in one
  /// transaction. Errors swallowed at the top level so a missing or
  /// RLS-blocked table doesn't break the main org pull.
  Future<void> _pullIntelligenceTables(String orgId) async {
    try {
      final results = await Future.wait<dynamic>([
        Supabase.instance.client.from('competitor_categories').select().eq('org_id', orgId),
        Supabase.instance.client.from('intelligence_products').select().eq('org_id', orgId),
        _fetchAllPages('competitor_spotting', orgId),
        _fetchAllPages('placement_audit', orgId),
      ]);
      final cats = _asList(results[0]);
      final prods = _asList(results[1]);
      final spots = _asList(results[2]);
      final audits = _asList(results[3]);
      print('INTEL PULL: cats=${cats.length} products=${prods.length} spotting=${spots.length} audit=${audits.length}');
      await _db.transaction(() async {
        await _pullCompetitorCategories(cats);
        await _pullProducts(prods);
        await _pullCompetitorSpottings(spots);
        await _pullPlacementAudits(audits);
        // Surveys removed on the web: drop the phone's synced copies that
        // the server no longer has (unsent ones are kept).
        await _dropRemovedAudits(orgId, {for (final a in audits) '${a['id']}'});
        await _dropRemovedSpottings(orgId, {for (final a in spots) '${a['id']}'});
      });
    } catch (e) {
      print('INTEL PULL ERROR (org=$orgId): $e');
    }
  }

  /// Every row of an org's table, read in pages (one read stops at 1,000).
  Future<List<Map<String, dynamic>>> _fetchAllPages(String table, String orgId) async {
    final out = <Map<String, dynamic>>[];
    for (var from = 0; ; from += 1000) {
      final page = await Supabase.instance.client
          .from(table)
          .select()
          .eq('org_id', orgId)
          .order('id')
          .range(from, from + 999);
      out.addAll(_asList(page));
      if ((page as List).length < 1000) break;
    }
    return out;
  }

  /// Delete this org's already-synced local survey rows whose id the server
  /// no longer has (removed on the web). Unsent rows are never touched.
  Future<void> _dropRemovedAudits(String orgId, Set<String> keep) async {
    final rows = await (_db.select(_db.placementAudits)
          ..where((t) => t.orgId.equals(orgId) & t.syncStatus.equals('synced')))
        .get();
    final gone = [for (final r in rows) if (!keep.contains(r.id)) r.id];
    for (var i = 0; i < gone.length; i += 500) {
      final chunk = gone.sublist(i, i + 500 > gone.length ? gone.length : i + 500);
      await (_db.delete(_db.placementAudits)..where((t) => t.id.isIn(chunk))).go();
    }
  }

  Future<void> _dropRemovedSpottings(String orgId, Set<String> keep) async {
    final rows = await (_db.select(_db.competitorSpottings)
          ..where((t) => t.orgId.equals(orgId) & t.syncStatus.equals('synced')))
        .get();
    final gone = [for (final r in rows) if (!keep.contains(r.id)) r.id];
    for (var i = 0; i < gone.length; i += 500) {
      final chunk = gone.sublist(i, i + 500 > gone.length ? gone.length : i + 500);
      await (_db.delete(_db.competitorSpottings)..where((t) => t.id.isIn(chunk))).go();
    }
  }

  List<Map<String, dynamic>> _asList(dynamic raw) =>
      (raw as List).map((e) => e as Map<String, dynamic>).toList();

  Future<void> _pullCompetitorCategories(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.competitorCategories).insertOnConflictUpdate(
            CompetitorCategoriesCompanion(
          id: Value(r['id'] as String),
          orgId: Value(r['org_id'] as String),
          name: Value(r['name'] as String),
          position: Value(r['position'] as int? ?? 0),
          isActive: Value(r['is_active'] as bool? ?? true),
          createdAt: Value(_parseDate(r['created_at'])),
          updatedAt: Value(_parseDate(r['updated_at'])),
        ));
      } catch (_) {}
    }
  }

  Future<void> _pullProducts(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.products).insertOnConflictUpdate(
            ProductsCompanion(
          id: Value(r['id'] as String),
          orgId: Value(r['org_id'] as String),
          name: Value(r['name'] as String),
          skuCode: Value(r['sku_code'] as String?),
          position: Value(r['position'] as int? ?? 0),
          isActive: Value(r['is_active'] as bool? ?? true),
          createdAt: Value(_parseDate(r['created_at'])),
          updatedAt: Value(_parseDate(r['updated_at'])),
        ));
      } catch (_) {}
    }
  }

  Future<void> _pullCompetitorSpottings(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.competitorSpottings).insertOnConflictUpdate(
            CompetitorSpottingsCompanion(
          id: Value(r['id'] as String),
          orgId: Value(r['org_id'] as String),
          customerId: Value(r['customer_id'] as String),
          categoryId: Value(r['category_id'] as String),
          brandName: Value(r['brand_name'] as String),
          price: Value(r['price'] as int?),
          specs: Value(r['specs'] as String?),
          surveyedByUserId: Value(r['surveyed_by_user_id'] as String?),
          surveyedAt: Value(_parseDate(r['surveyed_at'])),
          createdAt: Value(_parseDate(r['created_at'])),
          syncStatus: const Value('synced'),
        ));
      } catch (_) {}
    }
  }

  Future<void> _pullPlacementAudits(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.placementAudits).insertOnConflictUpdate(
            PlacementAuditsCompanion(
          id: Value(r['id'] as String),
          orgId: Value(r['org_id'] as String),
          customerId: Value(r['customer_id'] as String),
          productId: Value(r['product_id'] as String),
          isPresent: Value(r['is_present'] as bool),
          surveyedByUserId: Value(r['surveyed_by_user_id'] as String?),
          surveyedAt: Value(_parseDate(r['surveyed_at'])),
          createdAt: Value(_parseDate(r['created_at'])),
          syncStatus: const Value('synced'),
        ));
      } catch (_) {}
    }
  }

  DateTime _parseDate(dynamic val) {
  if (val == null) return DateTime.now();
  if (val is String) {
    final parsed = DateTime.tryParse(val);
    // .tryParse on a UTC-marked string returns a UTC DateTime.
    // Convert to local so it matches DateTime.now() used elsewhere.
    return parsed?.toLocal() ?? DateTime.now();
  }
  return DateTime.now();
}

DateTime? _parseDateNullable(dynamic val) {
  if (val == null) return null;
  if (val is String) return DateTime.tryParse(val)?.toLocal();
  return null;
}
}

final supabasePullServiceProvider = Provider<SupabasePullService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final sync = ref.watch(supabaseSyncServiceProvider);
  return SupabasePullService(db, sync);
});
