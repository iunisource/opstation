import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../database/app_database_provider.dart';
import 'supabase_sync_service.dart';
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
  }

  Future<void> _pullCustomers(List<Map<String, dynamic>> rows) async {
    for (final r in rows) {
      try {
        await _db.into(_db.customers).insertOnConflictUpdate(CustomersCompanion(
          id: Value(r['id'] as String),
          code: Value(r['code'] as String),
          shopName: Value(r['shop_name'] as String),
          contactPerson: Value(r['contact_person'] as String),
          phone: Value(r['phone'] as String),
          address: Value(r['address'] as String),
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
          position: Value(r['position'] as int),
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
          routeId: Value(r['route_id'] as String),
          routeName: Value(r['route_name'] as String),
          routeKind: Value(r['route_kind'] as String),
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
          position: Value(r['position'] as int),
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
          amount: Value(r['amount'] as int? ?? 0),
          receiptNumber: Value(r['receipt_number'] as String?),
          notes: Value(r['notes'] as String?),
          skipReason: Value(r['skip_reason'] as String?),
          photoPathsJson: Value(r['photo_paths_json'] as String? ?? '[]'),
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
          amount: Value(r['amount'] as int? ?? 0),
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
        ));
      } catch (_) {}
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
      final results = await Future.wait([
        Supabase.instance.client.from('competitor_categories').select().eq('org_id', orgId),
        Supabase.instance.client.from('intelligence_products').select().eq('org_id', orgId),
        Supabase.instance.client.from('competitor_spotting').select().eq('org_id', orgId),
        Supabase.instance.client.from('placement_audit').select().eq('org_id', orgId),
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
      });
    } catch (e) {
      print('INTEL PULL ERROR (org=$orgId): $e');
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
