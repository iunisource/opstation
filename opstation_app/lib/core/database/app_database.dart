import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

// ---- Tables --------------------------------------------------------------

@DataClassName('CustomersData')
class Customers extends Table {
  TextColumn get id => text()();
  TextColumn get code => text()();
  TextColumn get shopName => text()();
  TextColumn get contactPerson => text()();
  TextColumn get phone => text()();
  TextColumn get address => text()();
  TextColumn get category => text().nullable()();
  TextColumn get groupName => text().nullable()();
  RealColumn get latitude => real().nullable()();
  RealColumn get longitude => real().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get updatedAt => dateTime().nullable()();
  TextColumn get ntnGst => text().nullable()();
  TextColumn get orgId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SalesRoutesData')
class SalesRoutesTable extends Table {
  @override
  String get tableName => 'sales_routes';

  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get kind => text()(); // 'oneTime' | 'recurring'
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime().nullable()();
  TextColumn get orgId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Join table: which customers are on which route, in what order.
@DataClassName('RouteStopsData')
class RouteStops extends Table {
  TextColumn get routeId => text().references(SalesRoutesTable, #id)();
  TextColumn get customerId => text().references(Customers, #id)();
  IntColumn get position => integer()();

  @override
  Set<Column> get primaryKey => {routeId, customerId};
}

@DataClassName('TripsData')
class Trips extends Table {
  TextColumn get id => text()();
  TextColumn get routeId => text()();
  TextColumn get routeName => text()();
  TextColumn get routeKind => text()(); // 'oneTime' | 'recurring'
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  TextColumn get closeReason => text().nullable()(); // 'userEnded' | 'cutoff'
  RealColumn get startLat => real().nullable()();
  RealColumn get startLng => real().nullable()();
  RealColumn get endLat => real().nullable()();
  RealColumn get endLng => real().nullable()();

  // Who ran this trip. Denormalized snapshot — survives even if the user
  // record is later deleted. Empty string for pre-v4 rows.
  TextColumn get userId => text().withDefault(const Constant(''))();
  TextColumn get userName => text().withDefault(const Constant(''))();
  TextColumn get userRole => text().withDefault(const Constant(''))();
  TextColumn get orgId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Snapshot of the stop list at trip start. Protects historical trips
/// from later edits to the underlying route.
@DataClassName('TripStopsData')
class TripStops extends Table {
  TextColumn get tripId => text().references(Trips, #id)();
  TextColumn get customerId => text().references(Customers, #id)();
  IntColumn get position => integer()();

  @override
  Set<Column> get primaryKey => {tripId, customerId};
}

@DataClassName('VisitsData')
class Visits extends Table {
  TextColumn get id => text()();
  TextColumn get tripId => text().references(Trips, #id)();
  TextColumn get customerId => text().references(Customers, #id)();
  TextColumn get status => text()(); // verified|outside|noLocation|skipped|pending
  DateTimeColumn get timestamp => dateTime()();
  RealColumn get capturedLat => real().nullable()();
  RealColumn get capturedLng => real().nullable()();
  RealColumn get accuracyMeters => real().nullable()();
  RealColumn get distanceMeters => real().nullable()();
  IntColumn get amount => integer().withDefault(const Constant(0))();
  TextColumn get receiptNumber => text().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get skipReason => text().nullable()();

  /// JSON-encoded list of photo paths (mock values in Slice 3a).
  TextColumn get photoPathsJson => text().withDefault(const Constant('[]'))();

  /// Sync state (used by Slice 3b; present now to avoid schema migrations later).
  /// 'pending' (not yet synced) | 'synced' | 'rejected'
  TextColumn get syncStatus =>
      text().withDefault(const Constant('pending'))();

  // Who recorded this visit. Denormalized — matches the trip's user at
  // the moment of recording. Empty string for pre-v4 rows.
  TextColumn get userId => text().withDefault(const Constant(''))();
  TextColumn get userName => text().withDefault(const Constant(''))();
  TextColumn get userRole => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Key-value app configuration.
@DataClassName('AppConfigData')
class AppConfig extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Audit log for customer (and later: route/team) edits.
///
/// `entityType` + `entityId` identify the changed record.
/// `diffJson` is a map of `field -> {old, new}`. Flexible enough to cover
/// future entities without schema churn.
@DataClassName('AuditLogData')
class AuditLogs extends Table {
  TextColumn get id => text()();
  TextColumn get entityType => text()(); // 'customer' | 'route' | 'user'
  TextColumn get entityId => text()();
  TextColumn get action => text()(); // 'create' | 'update' | 'delete' | 'setLocation'
  TextColumn get actorId => text()();
  TextColumn get actorName => text()();
  TextColumn get actorRole => text()();
  DateTimeColumn get timestamp => dateTime()();
  TextColumn get diffJson => text().withDefault(const Constant('{}'))();
  TextColumn get summary => text().withDefault(const Constant(''))();
  TextColumn get orgId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Authenticated users. Password is stored as a SHA-256 hash with a salt.
/// This is local-device auth only — a real backend will replace this in a
/// future slice.
@DataClassName('UsersData')
class Users extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get email => text()(); // unique by convention
  TextColumn get phone => text().withDefault(const Constant(''))();
  TextColumn get role => text()(); // matches UserRole.name
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  /// Hex-encoded SHA-256(salt + password).
  TextColumn get passwordHash => text().withDefault(const Constant(''))();
  TextColumn get passwordSalt => text().withDefault(const Constant(''))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// True if the user was created via a password reset and hasn't chosen
  /// their own password yet. UI can prompt them to change it.
  BoolColumn get passwordTemporary =>
      boolean().withDefault(const Constant(false))();

  /// The organization this user belongs to. Nullable for users created
  /// before multi-tenancy was introduced (they implicitly belong to the
  /// default/primary org) and for the super admin, who is app-level and
  /// does not belong to any single org.
  TextColumn get orgId => text().nullable()();
  TextColumn get fcmToken => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Organization = tenant. A super admin creates these and assigns a
/// master admin to each. All app users (except super admin) belong to
/// exactly one org.
///
/// NOTE: as of schema v12 the rest of the tables (customers, routes,
/// trips, deliveries, etc.) are NOT yet scoped by org_id — tenant
/// isolation will be enforced server-side when real sync lands. This
/// table and the users.org_id column establish the control plane so
/// the super-admin UX is ready to go.
@DataClassName('OrgsData')
class Orgs extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// The user (role=masterAdmin) responsible for this org. Nullable
  /// during the brief window between creating an org and assigning an
  /// admin, but in the happy path this is set at creation time.
  TextColumn get masterAdminId => text().nullable()();

  /// When false, users whose [orgId] matches this org cannot log in.
  /// Super admins are unaffected (no orgId).
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Many-to-many: which users (salespersons) are assigned which routes.
///
/// Assignment is additive — a route can have multiple salespersons, a
/// salesperson can have multiple routes. The salesperson's home screen
/// shows only routes they're assigned to.
@DataClassName('RouteAssignmentsData')
class RouteAssignments extends Table {
  TextColumn get userId => text()();
  TextColumn get routeId => text()();
  DateTimeColumn get assignedAt => dateTime()();
  TextColumn get assignedBy => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {userId, routeId};
}

/// Pending and historical photo/file uploads to cloud storage.
///
/// The app writes a row here whenever a photo is captured; a background
/// worker picks queued rows and uploads them to Supabase, updating the
/// status as it goes. Rows stay around after success so admins can see
/// history and retry failures.
///
/// Statuses: 'queued' | 'uploading' | 'uploaded' | 'failed'
/// entityType: 'visit' | 'delivery' | 'customer' | 'other'
@DataClassName('UploadQueueData')
class UploadQueue extends Table {
  TextColumn get id => text()();

  /// Absolute path on device at the time of queueing. The worker reads
  /// from this path; if the file is gone by then we fail the row.
  TextColumn get localPath => text()();

  /// Target object path inside the storage bucket. Convention:
  /// `{orgId}/{entityType}/{entityId}/{filename}`. App-side generated.
  TextColumn get remotePath => text()();

  TextColumn get bucket => text()();
  TextColumn get status =>
      text().withDefault(const Constant('queued'))();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();

  /// Loose FK for "what does this upload belong to" — used by UI later
  /// to show photos against a visit/delivery without a join table.
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// A dispatch request handed to a driver: "go deliver these items to
/// these customers." Created by a dispatch manager / admin; executed
/// by a driver in slice 6b.
///
/// Status lifecycle:
///   draft       -> still being built; not visible to driver
///   assigned    -> visible to driver, not started yet
///   in_progress -> driver has started executing
///   completed   -> all stops settled (delivered or failed)
///   cancelled   -> dispatcher killed it before completion
@DataClassName('DeliveriesData')
class Deliveries extends Table {
  TextColumn get id => text()();

  /// Who the delivery is assigned to. Null while the delivery is still
  /// a draft without a driver picked.
  TextColumn get driverId => text().nullable()();
  TextColumn get driverName => text().nullable()();
  TextColumn get driverRole => text().nullable()();

  /// Who created the dispatch (admin / master-admin / dispatch-manager).
  TextColumn get createdBy => text()();
  TextColumn get createdByName => text().withDefault(const Constant(''))();
  TextColumn get createdByRole => text().withDefault(const Constant(''))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get startedAt => dateTime().nullable()();
  DateTimeColumn get completedAt => dateTime().nullable()();

  TextColumn get status =>
      text().withDefault(const Constant('draft'))();
  TextColumn get notes => text().nullable()();
  TextColumn get orgId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// An individual delivery drop: customer + item description + amount +
/// payment type + outcome (once executed).
///
/// Status lifecycle:
///   pending   -> not yet attempted
///   delivered -> driver confirmed delivery
///   failed    -> driver couldn't deliver (reason required)
@DataClassName('DeliveryStopsData')
class DeliveryStops extends Table {
  TextColumn get id => text()();
  TextColumn get deliveryId => text()();

  /// Snapshot fields so a delivery report stays meaningful even if
  /// the customer record is later edited.
  TextColumn get customerId => text()();
  TextColumn get customerCode => text().withDefault(const Constant(''))();
  TextColumn get customerName => text().withDefault(const Constant(''))();

  IntColumn get sequence => integer()();
  TextColumn get itemDescription => text().withDefault(const Constant(''))();

  /// Amount to be settled at this stop. Zero is valid (e.g. a free-of-
  /// charge drop). Uses int rupees to match the rest of the app's money.
  IntColumn get amount => integer().withDefault(const Constant(0))();

  /// 'cash' (driver collects physical money) or 'credit' (customer is
  /// on account, amount is logged as owed, nothing collected at drop).
  TextColumn get paymentType => text().withDefault(const Constant('cash'))();

  TextColumn get status =>
      text().withDefault(const Constant('pending'))();
  DateTimeColumn get deliveredAt => dateTime().nullable()();
  TextColumn get failureReason => text().nullable()();

  /// Actual cash the driver collected at the stop. Defaults to the
  /// dispatched [amount] when the driver marks delivered, but the
  /// driver can override if the customer short-paid. Null until a
  /// driver settles the stop; always null for credit stops.
  IntColumn get cashReceived => integer().nullable()();

  /// Captured once the driver marks this stop done (6b). Nullable until
  /// then.
  RealColumn get capturedLat => real().nullable()();
  RealColumn get capturedLng => real().nullable()();

  /// Meters from the customer's saved location at the time of capture,
  /// computed the same way we compute visit distance.
  IntColumn get distanceMeters => integer().nullable()();

  /// Geofence verification status, computed at mark-time against the
  /// org-wide [geofenceRadiusMeters] setting. Mirrors the salesperson
  /// visit-verification flow exactly — same customer locations, same
  /// radius, same three outcomes:
  ///   - 'pending'      : stop hasn't been marked yet
  ///   - 'verified'     : captured within the geofence
  ///   - 'outside'      : captured outside the geofence (driver can
  ///                      still mark delivered; this is a SOFT flag)
  ///   - 'no_location'  : no GPS fix available, or customer has no
  ///                      saved location
  /// Never blocks the driver — used for admin reporting and compliance
  /// pattern detection only.
  TextColumn get verification =>
      text().withDefault(const Constant('pending'))();

  /// Sync state for offline-marked stops. Local-only (not pushed to server).
  /// Mirrors visits.syncStatus.
  ///   'synced'  : on server (default for pulled rows)
  ///   'pending' : marked locally, not yet pushed
  TextColumn get syncStatus =>
      text().withDefault(const Constant('synced'))();

  /// Free-text instructions for the driver, set by accountant or
  /// dispatch. Nullable.
  TextColumn get driverNote => text().nullable()();

  /// Sales-order or invoice reference number. Nullable.
  TextColumn get soInvoiceNumber => text().nullable()();

  /// Proof-of-delivery photos captured by the driver, stored as JSON
  /// array of absolute local file paths. Mirrors the pattern used by
  /// the salesperson visits table (photoPathsJson). The actual files
  /// live under the app's documents directory; uploads to Supabase
  /// are handled by the UploadWorker via the upload_queue table, so
  /// this column holds local paths even after upload completes.
  TextColumn get photoPathsJson =>
      text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {id};
}

// ---- Database ------------------------------------------------------------

@DriftDatabase(tables: [
  Customers,
  SalesRoutesTable,
  RouteStops,
  Trips,
  TripStops,
  Visits,
  AppConfig,
  AuditLogs,
  Users,
  RouteAssignments,
  UploadQueue,
  Deliveries,
  DeliveryStops,
  Orgs, CompetitorCategories, Products, CompetitorSpottings, PlacementAudits])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  @override
  int get schemaVersion => 18;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 17) {
            await m.addColumn(deliveryStops, deliveryStops.syncStatus);
          }
        if (from < 18) {
          await m.createTable(competitorCategories);
          await m.createTable(products);
          await m.createTable(competitorSpottings);
          await m.createTable(placementAudits);
        }
      if (from < 16) {
        await m.addColumn(deliveryStops, deliveryStops.driverNote);
        await m.addColumn(deliveryStops, deliveryStops.soInvoiceNumber);
      }
      if (from < 15) {
        await m.addColumn(users, users.fcmToken);
      }
          if (from < 2) {
            await m.addColumn(customers, customers.isActive);
            await m.addColumn(customers, customers.updatedAt);
            await m.createTable(auditLogs);
          }
          if (from < 3) {
            await m.addColumn(customers, customers.ntnGst);
          }
          if (from < 4) {
            await m.addColumn(trips, trips.userId);
            await m.addColumn(trips, trips.userName);
            await m.addColumn(trips, trips.userRole);
            await m.addColumn(visits, visits.userId);
            await m.addColumn(visits, visits.userName);
            await m.addColumn(visits, visits.userRole);
          }
          if (from < 5) {
            await m.createTable(users);
          }
          if (from < 6) {
            await m.createTable(routeAssignments);
            final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            await customStatement(
              "INSERT OR IGNORE INTO route_assignments (user_id, route_id, assigned_at, assigned_by) "
              "SELECT 'u_sales1', id, ?, 'system_migration' FROM sales_routes",
              [nowSec],
            );
          }
          if (from < 7) {
            await m.addColumn(salesRoutesTable, salesRoutesTable.isActive);
            await m.addColumn(salesRoutesTable, salesRoutesTable.createdAt);
            await m.addColumn(salesRoutesTable, salesRoutesTable.updatedAt);
          }
          if (from < 8) {
            await m.createTable(uploadQueue);
          }
          if (from < 9) {
            await m.createTable(deliveries);
            await m.createTable(deliveryStops);
          }
          if (from < 10) {
            await m.addColumn(deliveryStops, deliveryStops.cashReceived);
          }
          if (from < 11) {
            await m.addColumn(deliveryStops, deliveryStops.verification);
          }
          if (from < 12) {
            // Multi-tenancy control plane. Create the orgs table, add
            // org_id to users, and seed a default org for all existing
            // non-super-admin users so nothing breaks in downstream
            // queries that expect a valid org pointer.
            await m.createTable(orgs);
            await m.addColumn(users, users.orgId);
            final now = DateTime.now();
            final nowSec = now.millisecondsSinceEpoch ~/ 1000;
            await customStatement(
              "INSERT OR IGNORE INTO orgs "
              "(id, name, master_admin_id, is_active, created_at, updated_at) "
              "VALUES ('org_default', 'Default organization', "
              "(SELECT id FROM users WHERE role = 'masterAdmin' LIMIT 1), "
              "1, ?, ?)",
              [nowSec, nowSec],
            );
            await customStatement(
              "UPDATE users SET org_id = 'org_default' "
              "WHERE org_id IS NULL AND role != 'superAdmin'",
            );
          }
          if (from < 13) {
            // Proof-of-delivery photos per stop. Additive column,
            // defaults to an empty JSON array.
            await m.addColumn(
                deliveryStops, deliveryStops.photoPathsJson);
          }
          if (from < 14) {
            await m.addColumn(customers, customers.orgId);
            await m.addColumn(salesRoutesTable, salesRoutesTable.orgId);
            await m.addColumn(trips, trips.orgId);
            await m.addColumn(deliveries, deliveries.orgId);
            await m.addColumn(auditLogs, auditLogs.orgId);
            final d = 'org_default';
            await customStatement(
                "UPDATE customers SET org_id='$d' WHERE org_id IS NULL");
            await customStatement(
                "UPDATE sales_routes SET org_id='$d' WHERE org_id IS NULL");
            await customStatement(
                "UPDATE trips SET org_id='$d' WHERE org_id IS NULL");
            await customStatement(
                "UPDATE deliveries SET org_id='$d' WHERE org_id IS NULL");
            await customStatement(
                "UPDATE audit_logs SET org_id='$d' WHERE org_id IS NULL");
          }
        },
      );

  // ---- App config helpers ----

  Future<String?> getConfig(String key) async {
    final row = await (select(appConfig)..where((c) => c.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setConfig(String key, String value) async {
    await into(appConfig).insertOnConflictUpdate(
      AppConfigCompanion.insert(key: key, value: value),
    );
  }

  Future<void> deleteConfig(String key) async {
    await (delete(appConfig)..where((c) => c.key.equals(key))).go();
  }
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'opstation.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}

@DataClassName('CompetitorCategoryRow')
class CompetitorCategories extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text().named('org_id')();
  TextColumn get name => text()();
  IntColumn get position => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().named('is_active').withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();
  @override Set<Column> get primaryKey => {id};
}

@DataClassName('ProductRow')
class Products extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text().named('org_id')();
  TextColumn get name => text()();
  TextColumn get skuCode => text().named('sku_code').nullable()();
  IntColumn get position => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().named('is_active').withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();
  @override Set<Column> get primaryKey => {id};
  @override String get tableName => 'intelligence_products';
}

@DataClassName('CompetitorSpottingRow')
class CompetitorSpottings extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text().named('org_id')();
  TextColumn get customerId => text().named('customer_id')();
  TextColumn get categoryId => text().named('category_id')();
  TextColumn get brandName => text().named('brand_name')();
  IntColumn get price => integer().nullable()();
  TextColumn get specs => text().nullable()();
  TextColumn get surveyedByUserId => text().named('surveyed_by_user_id').nullable()();
  DateTimeColumn get surveyedAt => dateTime().named('surveyed_at')();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  TextColumn get syncStatus => text().named('sync_status').withDefault(const Constant('synced'))();
  @override Set<Column> get primaryKey => {id};
}

@DataClassName('PlacementAuditRow')
class PlacementAudits extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text().named('org_id')();
  TextColumn get customerId => text().named('customer_id')();
  TextColumn get productId => text().named('product_id')();
  BoolColumn get isPresent => boolean().named('is_present')();
  TextColumn get surveyedByUserId => text().named('surveyed_by_user_id').nullable()();
  DateTimeColumn get surveyedAt => dateTime().named('surveyed_at')();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  TextColumn get syncStatus => text().named('sync_status').withDefault(const Constant('synced'))();
  @override Set<Column> get primaryKey => {id};
}

