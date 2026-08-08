import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/app_database.dart';

/// Real Supabase sync service — replaces MockSyncServer.
/// Handles push (local → Supabase) and pull (Supabase → local) per entity.
///
/// Timezone policy: all DateTimes are converted to UTC before serializing.
/// `.toUtc().toIso8601String()` produces a string with a trailing `Z` so
/// Postgres parses it unambiguously as UTC.
class SupabaseSyncService {
  final SupabaseClient _client;
  SupabaseSyncService(this._client);

  bool get isAuthenticated => _client.auth.currentSession != null;

  // Helper — UTC-safe ISO string for push.
  static String? _iso(DateTime? d) => d?.toUtc().toIso8601String();

  // ---- PUSH methods (local → Supabase) ----------------------------------

  Future<void> pushOrg(OrgsData o) async {
    await _client.from('orgs').upsert({
      'id': o.id,
      'name': o.name,
      'master_admin_id': o.masterAdminId,
      'is_active': o.isActive,
      'created_at': _iso(o.createdAt),
      'updated_at': _iso(o.updatedAt),
    });
  }

  /// Push a user to Supabase.
  ///
  /// [includeActive] controls whether `is_active` is written. The bulk sync
  /// loop (pushAll) MUST pass false: activation/deactivation is a web-admin
  /// action, and the server is authoritative for it. Previously every phone
  /// re-uploaded its cached `is_active` for every user on each full sync, so
  /// a device holding a stale `is_active = true` for an admin-deactivated
  /// account silently resurrected it. Omitting the column from an upsert
  /// leaves the server value untouched on UPDATE, and lets the DB default
  /// apply on INSERT. New-user creation (team_repository) keeps the default
  /// includeActive: true so a freshly-created member is pushed as active.
  Future<void> pushUser(UsersData u, {bool includeActive = true}) async {
    final Map<String, dynamic> data = {
      'id': u.id,
      'name': u.name,
      'email': u.email,
      'phone': u.phone,
      'role': u.role,
      'password_hash': u.passwordHash,
      'password_salt': u.passwordSalt,
      'created_at': _iso(u.createdAt),
      'updated_at': _iso(u.updatedAt),
      'password_temporary': u.passwordTemporary,
      'org_id': u.orgId,
    };
    if (includeActive) {
      data['is_active'] = u.isActive;
    }
    await _client.from('users').upsert(data);
  }

  Future<void> pushCustomer(CustomersData c) async {
    await _client.from('customers').upsert({
      'id': c.id,
      'code': c.code,
      'shop_name': c.shopName,
      'contact_person': c.contactPerson,
      'phone': c.phone,
      'address': c.address,
      'category': c.category,
      'group_name': c.groupName,
      'latitude': c.latitude,
      'longitude': c.longitude,
      'is_active': c.isActive,
      'updated_at': _iso(c.updatedAt),
      'ntn_gst': c.ntnGst,
      'org_id': c.orgId,
    });
  }

  Future<void> pushRoute(SalesRoutesData r) async {
    await _client.from('sales_routes').upsert({
      'id': r.id,
      'name': r.name,
      'kind': r.kind,
      'is_active': r.isActive,
      'created_at': _iso(r.createdAt),
      'updated_at': _iso(r.updatedAt),
      'org_id': r.orgId,
    });
  }

  Future<void> pushRouteStop(RouteStopsData s) async {
    await _client.from('route_stops').upsert({
      'route_id': s.routeId,
      'customer_id': s.customerId,
      'position': s.position,
    });
  }

  Future<void> pushRouteAssignment(RouteAssignmentsData a) async {
    await _client.from('route_assignments').upsert({
      'user_id': a.userId,
      'route_id': a.routeId,
      'assigned_at': _iso(a.assignedAt),
      'assigned_by': a.assignedBy,
    });
  }

  Future<void> deleteRouteAssignment({
    required String userId,
    required String routeId,
  }) async {
    await _client
        .from('route_assignments')
        .delete()
        .eq('user_id', userId)
        .eq('route_id', routeId);
  }

  /// Fetch all route_assignments for a single user. Used by the targeted
  /// pull that powers realtime refresh and the "Retry now" button.
  Future<List<Map<String, dynamic>>> pullRouteAssignmentsByUserId(
    String userId,
  ) async {
    final res = await _client
        .from('route_assignments')
        .select()
        .eq('user_id', userId);
    return List<Map<String, dynamic>>.from(res as List);
  }

  Future<void> pushTrip(TripsData t) async {
    await _client.from('trips').upsert({
      'id': t.id,
      'route_id': t.routeId,
      'route_name': t.routeName,
      'route_kind': t.routeKind,
      'started_at': _iso(t.startedAt),
      'ended_at': _iso(t.endedAt),
      'close_reason': t.closeReason,
      'start_lat': t.startLat,
      'start_lng': t.startLng,
      'end_lat': t.endLat,
      'end_lng': t.endLng,
      'user_id': t.userId,
      'user_name': t.userName,
      'user_role': t.userRole,
      'org_id': t.orgId,
    });
  }

  Future<void> pushTripStop(TripStopsData s) async {
    await _client.from('trip_stops').upsert({
      'trip_id': s.tripId,
      'customer_id': s.customerId,
      'position': s.position,
    });
  }

  Future<void> pushVisit(VisitsData v) async {
    await _client.from('visits').upsert({
      'id': v.id,
      'trip_id': v.tripId,
      'customer_id': v.customerId,
      'status': v.status,
      'timestamp': _iso(v.timestamp),
      'captured_lat': v.capturedLat,
      'captured_lng': v.capturedLng,
      'accuracy_meters': v.accuracyMeters,
      'distance_meters': v.distanceMeters,
      'amount': v.amount,
      'receipt_number': v.receiptNumber,
      'notes': v.notes,
      'skip_reason': v.skipReason,
      'photo_paths_json': v.photoPathsJson,
      'sync_status': 'synced',
      'user_id': v.userId,
      'user_name': v.userName,
      'user_role': v.userRole,
    });
  }

  Future<void> pushDelivery(DeliveriesData d) async {
    await _client.from('deliveries').upsert({
      'id': d.id,
      'driver_id': d.driverId,
      'driver_name': d.driverName,
      'driver_role': d.driverRole,
      'created_by': d.createdBy,
      'created_by_name': d.createdByName,
      'created_by_role': d.createdByRole,
      'created_at': _iso(d.createdAt),
      'started_at': _iso(d.startedAt),
      'completed_at': _iso(d.completedAt),
      'status': d.status,
      'notes': d.notes,
      'org_id': d.orgId,
    });
  }

  Future<void> pushDeliveryStop(DeliveryStopsData s) async {
    await _client.from('delivery_stops').upsert({
      'id': s.id,
      'delivery_id': s.deliveryId,
      'customer_id': s.customerId,
      'customer_code': s.customerCode,
      'customer_name': s.customerName,
      'sequence': s.sequence,
      'item_description': s.itemDescription,
      'amount': s.amount,
      'payment_type': s.paymentType,
      'status': s.status,
      'delivered_at': _iso(s.deliveredAt),
      'failure_reason': s.failureReason,
      'cash_received': s.cashReceived,
      'captured_lat': s.capturedLat,
      'captured_lng': s.capturedLng,
      'distance_meters': s.distanceMeters,
      'verification': s.verification,
      'photo_paths_json': s.photoPathsJson,
      'do_id': s.doId,
    });
  }

  /// Push a locally-captured field order. Sends ONLY the columns the online
  /// path sends (DB defaults created_at/totals) so offline orders are
  /// indistinguishable from online ones in the web field-orders queue.
  Future<void> pushFieldOrder(FieldOrderRow o) async {
    await _client.from('field_orders').upsert({
      'id': o.id,
      'org_id': o.orgId,
      'customer_id': o.customerId,
      'salesperson_id': o.salespersonId,
      'status': o.status,
      'notes': o.notes,
    });
  }

  Future<void> pushFieldOrderItem(FieldOrderItemRow i) async {
    await _client.from('field_order_items').upsert({
      'id': i.id,
      'field_order_id': i.fieldOrderId,
      'product_id': i.productId,
      'uom_id': i.uomId,
      'quantity': i.quantity,
      'price_at_submit': i.priceAtSubmit,
    });
  }

  // ---- PULL methods (Supabase → local) ----------------------------------

  Future<List<Map<String, dynamic>>> pullOrgs() async {
    final res = await _client.from('orgs').select();
    return List<Map<String, dynamic>>.from(res);
  }

  /// Pull all data for an org from Supabase into a structured map.
  /// Called on fresh install login to populate local SQLite.
  /// Paginated customers fetch — PostgREST caps .select() at 1000 rows,
  /// so we page through until a short page signals the end.
  Future<List<Map<String, dynamic>>> _pullAllCustomers(String orgId) async {
    final out = <Map<String, dynamic>>[];
    const pageSize = 1000;
    var offset = 0;
    while (true) {
      final page = await _client
          .from('customers')
          .select()
          .eq('org_id', orgId)
          .range(offset, offset + pageSize - 1);
      out.addAll(List<Map<String, dynamic>>.from(page));
      if (page.length < pageSize) break;
      offset += pageSize;
    }
    return out;
  }

  /// Paginated catalog fetch for offline order-taking. Selects only the
  /// columns the order modal needs (search + save).
  Future<List<Map<String, dynamic>>> _pullAllProducts(String orgId) async {
    final out = <Map<String, dynamic>>[];
    const pageSize = 1000;
    var offset = 0;
    while (true) {
      final page = await _client
          .from('products')
          .select(
              'id, org_id, name, sku, selling_price, base_uom_id, product_sub_group, is_active, updated_at')
          .eq('org_id', orgId)
          .range(offset, offset + pageSize - 1);
      out.addAll(List<Map<String, dynamic>>.from(page));
      if (page.length < pageSize) break;
      offset += pageSize;
    }
    return out;
  }

  Future<OrgPullData> pullOrgData(String orgId) async {
    final results = await Future.wait([
      _client.from('orgs').select().eq('id', orgId),
      _client.from('users').select().or('org_id.eq.$orgId,role.eq.superAdmin'),
      _pullAllCustomers(orgId),
      _pullAllProducts(orgId),
      _client.from('sales_routes').select().eq('org_id', orgId),
      _client.from('route_stops').select(),
      _client.from('route_assignments').select(),
      _client.from('trips').select().or('org_id.eq.$orgId,org_id.is.null'),
      _client.from('trip_stops').select(),
      _client.from('visits').select(),
      _client.from('deliveries').select().or('org_id.eq.$orgId,org_id.is.null'),
      _client.from('delivery_stops').select(),
    ]);
    return OrgPullData(
      orgs: List<Map<String, dynamic>>.from(results[0]),
      users: List<Map<String, dynamic>>.from(results[1]),
      customers: List<Map<String, dynamic>>.from(results[2]),
      products: List<Map<String, dynamic>>.from(results[3]),
      routes: List<Map<String, dynamic>>.from(results[4]),
      routeStops: List<Map<String, dynamic>>.from(results[5]),
      routeAssignments: List<Map<String, dynamic>>.from(results[6]),
      trips: List<Map<String, dynamic>>.from(results[7]),
      tripStops: List<Map<String, dynamic>>.from(results[8]),
      visits: List<Map<String, dynamic>>.from(results[9]),
      deliveries: List<Map<String, dynamic>>.from(results[10]),
      deliveryStops: List<Map<String, dynamic>>.from(results[11]),
    );
  }

  Future<List<Map<String, dynamic>>> pullTable(
      String table, String? orgId) async {
    if (orgId == null) {
      return List<Map<String, dynamic>>.from(
          await _client.from(table).select());
    }
    try {
      return List<Map<String, dynamic>>.from(
          await _client.from(table).select().eq('org_id', orgId));
    } catch (_) {
      // Table might not have org_id (e.g. route_stops) — pull all
      return List<Map<String, dynamic>>.from(
          await _client.from(table).select());
    }
  }
}

/// Structured container for all pulled org data.
class OrgPullData {
  final List<Map<String, dynamic>> orgs;
  final List<Map<String, dynamic>> users;
  final List<Map<String, dynamic>> customers;
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> routes;
  final List<Map<String, dynamic>> routeStops;
  final List<Map<String, dynamic>> routeAssignments;
  final List<Map<String, dynamic>> trips;
  final List<Map<String, dynamic>> tripStops;
  final List<Map<String, dynamic>> visits;
  final List<Map<String, dynamic>> deliveries;
  final List<Map<String, dynamic>> deliveryStops;

  const OrgPullData({
    required this.orgs,
    required this.users,
    required this.customers,
    required this.products,
    required this.routes,
    required this.routeStops,
    required this.routeAssignments,
    required this.trips,
    required this.tripStops,
    required this.visits,
    required this.deliveries,
    required this.deliveryStops,
  });
}

final supabaseSyncServiceProvider = Provider<SupabaseSyncService>((ref) {
  return SupabaseSyncService(Supabase.instance.client);
});