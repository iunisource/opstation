import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/supabase/supabase_sync_service.dart';
import '../../../core/database/app_database_provider.dart';
import '../../auth/models/user_role.dart';
import '../../team/data/team_repository.dart';
import '../models/org.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/auth/password_hasher.dart';

/// Org CRUD for the super-admin control plane.
///
/// Scope of this repository:
///   - Orgs themselves (create / rename / enable / disable / list)
///   - Master-admin assignment (the single master admin per org)
///
/// Out of scope (deferred until real sync lands):
///   - Org-scoped queries on customers, routes, trips, deliveries —
///     those stay global in the local DB. Tenant isolation is a
///     server-side responsibility we'll enforce when the backend is
///     real.
class OrgRepository {
  final AppDatabase _db;
  final TeamRepository _team;
  final SupabaseSyncService _sync;

  OrgRepository(this._db, this._team, this._sync);

  // ---- Reads ----------------------------------------------------------

  Future<List<Org>> all() async {
    final rows = await (_db.select(_db.orgs)
          ..orderBy([(o) => OrderingTerm.asc(o.name)]))
        .get();
    return rows.map(Org.fromRow).toList();
  }

  Future<Org?> byId(String id) async {
    final row = await (_db.select(_db.orgs)..where((o) => o.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : Org.fromRow(row);
  }

  // ---- Writes ---------------------------------------------------------

  /// Creates a new org AND its master admin in one transaction.
  ///
  /// Throws if:
  ///   - the org name is blank
  ///   - a user with the given master-admin email already exists
  ///
  /// The master admin is created with [masterAdminPassword] (stored
  /// hashed) and `passwordTemporary = true` so the UI prompts them to
  /// change it on first login. They're permanently linked to this org
  /// via [UsersData.orgId].
  Future<Org> create({
    required String name,
    required String masterAdminName,
    required String masterAdminEmail,
    required String masterAdminPhone,
    required String masterAdminPassword,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Organization name cannot be blank.');
    }
    if (masterAdminPassword.length < 6) {
      throw StateError('Password must be at least 6 characters.');
    }

    // Hash password client-side so the same hash lands in both the
    // server's public.users row and this device's local Drift row.
    // Local hash keeps offline same-device login working.
    final salt = PasswordHasher.newSalt();
    final hash = PasswordHasher.hash(masterAdminPassword, salt);

    // Edge Function is the only thing with service_role privilege to
    // write auth.users. It atomically creates auth.users + public.orgs
    // + public.users (with rollback on partial failure).
    late Map<String, dynamic> result;
    try {
      final resp = await Supabase.instance.client.functions.invoke(
        'create-org-admin',
        body: {
          'orgName': trimmed,
          'maxUsers': null,
          'expiresAt': null,
          'maName': masterAdminName.trim(),
          'maEmail': masterAdminEmail.toLowerCase().trim(),
          'maPassword': masterAdminPassword,
          'maPasswordHash': hash,
          'maPasswordSalt': salt,
        },
      );
      result = (resp.data as Map?)?.cast<String, dynamic>() ?? {};
    } on FunctionException catch (e) {
      String code = '';
      String detail = '';
      final body = e.details;
      if (body is Map) {
        if (body['error'] is String) code = body['error'] as String;
        if (body['detail'] is String) detail = body['detail'] as String;
      }
      String message;
      switch (code) {
        case 'email_exists_public':
          message =
              'A user with email ${masterAdminEmail.trim()} already exists.';
          break;
        case 'forbidden':
          message = 'You do not have permission to create organizations.';
          break;
        case 'weak_password':
          message = 'Password must be at least 6 characters.';
          break;
        case 'auth_create_failed':
          message = 'Could not create auth user: $detail';
          break;
        case 'insert_failed_rolled_back':
          message = 'Database error, rolled back: $detail';
          break;
        default:
          message = code.isEmpty
              ? 'Failed to create organization (status ${e.status}).'
              : '$code: $detail';
      }
      throw StateError(message);
    }

    final orgId = result['orgId'] as String? ?? '';
    final userId = result['userId'] as String? ?? '';
    if (orgId.isEmpty || userId.isEmpty) {
      throw StateError('Server response missing orgId or userId.');
    }

    // Mirror into local Drift with server-assigned IDs so the
    // super-admin home list refreshes instantly and same-device
    // offline login works for the new master admin.
    final now = DateTime.now();
    await _db.into(_db.orgs).insert(
      OrgsCompanion.insert(
        id: orgId,
        name: trimmed,
        createdAt: now,
        masterAdminId: Value(userId),
        isActive: const Value(true),
      ),
    );
    await _db.into(_db.users).insert(
      UsersCompanion.insert(
        id: userId,
        name: masterAdminName.trim(),
        email: masterAdminEmail.toLowerCase().trim(),
        phone: Value(masterAdminPhone.trim()),
        role: UserRole.masterAdmin.name,
        createdAt: now,
        isActive: const Value(true),
        passwordHash: Value(hash),
        passwordSalt: Value(salt),
        passwordTemporary: const Value(false),
        orgId: Value(orgId),
      ),
    );

    return (await byId(orgId))!;
  }

  /// Renames an org. Does not touch the master admin.
  Future<void> rename({required String id, required String newName}) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Organization name cannot be blank.');
    }
    await (_db.update(_db.orgs)..where((o) => o.id.equals(id))).write(
      OrgsCompanion(
        name: Value(trimmed),
        updatedAt: Value(DateTime.now()),
      ),
    );
    try {
      final row = await (_db.select(_db.orgs)..where((o) => o.id.equals(id))).getSingleOrNull();
      if (row != null) await _sync.pushOrg(row);
    } catch (_) {}
  }

  /// Flips the active flag. Deactivating blocks login for all users
  /// whose [orgId] matches (login gate enforced in AuthController).
  /// Data is preserved; re-enabling fully restores the org.
  Future<void> setActive({required String id, required bool active}) async {
    await (_db.update(_db.orgs)..where((o) => o.id.equals(id))).write(
      OrgsCompanion(
        isActive: Value(active),
        updatedAt: Value(DateTime.now()),
      ),
    );
    try {
      final row = await (_db.select(_db.orgs)..where((o) => o.id.equals(id))).getSingleOrNull();
      if (row != null) await _sync.pushOrg(row);
    } catch (_) {}
  }

  /// Total users belonging to an org (any role, active or not). Used
  /// for the "N users" footer on org cards.
  Future<int> userCount(String orgId) async {
    final rows = await (_db.selectOnly(_db.users)
          ..addColumns([_db.users.id])
          ..where(_db.users.orgId.equals(orgId)))
        .get();
    return rows.length;
  }
}

final orgRepositoryProvider = Provider<OrgRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final team = ref.watch(teamRepositoryProvider);
  final sync = ref.watch(supabaseSyncServiceProvider);
  return OrgRepository(db, team, sync);
});
